const std = @import("std");
const rl = @import("raylib");
const embedded_assets = @import("embedded_assets");

// === Linux input headers ===
const jsy = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const ev = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("linux/input.h");
});

const JS_EVENT_AXIS: u8 = 0x02;
const JS_EVENT_BUTTON: u8 = 0x01;
const JS_EVENT_INIT: u8 = 0x80;

const JsEvent = extern struct {
    time: u32,
    value: i16,
    type: u8,
    number: u8,
};

const Wheel = struct {
    fd: c_int = -1,
    axes: [8]f32 = .{0} ** 8,
    buttons: [32]bool = .{false} ** 32,
    available: bool = false,

    fn init() Wheel {
        const fd = jsy.open("/dev/input/js0", jsy.O_RDONLY | jsy.O_NONBLOCK);
        return .{ .fd = fd, .available = fd >= 0 };
    }

    fn deinit(self: *Wheel) void {
        if (self.available) _ = jsy.close(self.fd);
    }

    fn poll(self: *Wheel) void {
        if (!self.available) return;
        var event: JsEvent = undefined;
        const sz: usize = @sizeOf(JsEvent);
        while (true) {
            const n = jsy.read(self.fd, &event, sz);
            if (n != sz) break;
            if (event.type & JS_EVENT_AXIS != 0) {
                if (event.number < 8) self.axes[event.number] = @as(f32, @floatFromInt(event.value)) / 32767.0;
            } else if (event.type & JS_EVENT_BUTTON != 0) {
                if (event.number < 32) self.buttons[event.number] = event.value != 0;
            }
        }
    }

    fn steering(self: Wheel) f32 {
        return self.axes[0];
    }

    fn throttle(self: Wheel) f32 {
        return std.math.clamp((1.0 - self.axes[1]) * 0.5, 0.0, 1.0);
    }

    fn brake(self: Wheel) f32 {
        return std.math.clamp((1.0 - self.axes[2]) * 0.5, 0.0, 1.0);
    }
};

var g_wheel: Wheel = .{};

// === Force feedback via evdev (Logitech DFP: CONSTANT + AUTOCENTER + GAIN) ===
const EVIOCSFF: c_ulong = 0x40304580;
const EVIOCRMFF: c_ulong = 0x40044581;
const FF_CONSTANT: u16 = 0x52;
const FF_GAIN: u16 = 0x60;
const FF_AUTOCENTER: u16 = 0x61;
const EV_FF: u16 = 0x15;

const ForceFeedback = struct {
    fd: c_int = -1,
    available: bool = false,
    effect: ev.struct_ff_effect = std.mem.zeroes(ev.struct_ff_effect),
    collision_force: f32 = 0,

    fn init() ForceFeedback {
        var self = ForceFeedback{};

        // Scan for evdev device with FF support (EV_FF = bit 21)
        var i: c_int = 0;
        while (i < 32) : (i += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{i}) catch continue;
            const fd = jsy.open(path.ptr, jsy.O_RDWR);
            if (fd < 0) continue;

            var evbits: [4]u8 = .{0} ** 4;
            const EVIOCGBIT0: c_ulong = 0x80044520; // EVIOCGBIT(0, 4)
            _ = ev.ioctl(fd, EVIOCGBIT0, &evbits);
            if (evbits[2] & (@as(u8, 1) << 5) != 0) { // bit 21 = byte 2 bit 5
                self.fd = fd;
                self.available = true;
                break;
            }
            _ = jsy.close(fd);
        }
        if (!self.available) return self;

        // Set master gain to max
        self.writeFF(FF_GAIN, 0xFFFF);

        // Set autocenter spring (moderate)
        self.writeFF(FF_AUTOCENTER, 0x5000);

        // Upload a continuous constant effect for road vibration + collision
        self.effect.type = FF_CONSTANT;
        self.effect.id = -1;
        self.effect.replay.length = 0; // infinite
        self.effect.u.constant.level = 0;
        _ = ev.ioctl(self.fd, EVIOCSFF, &self.effect);
        self.writeFF(EV_FF, 1); // play

        return self;
    }

    fn deinit(self: *ForceFeedback) void {
        if (!self.available) return;
        self.writeFF(EV_FF, 0); // stop constant
        if (self.effect.id >= 0) _ = ev.ioctl(self.fd, EVIOCRMFF, self.effect.id);
        self.writeFF(FF_AUTOCENTER, 0); // disable spring
        _ = jsy.close(self.fd);
    }

    fn writeFF(self: ForceFeedback, code: u16, value: i32) void {
        var ie: ev.struct_input_event = std.mem.zeroes(ev.struct_input_event);
        ie.type = EV_FF;
        ie.code = if (self.effect.id >= 0 and code == EV_FF) @intCast(self.effect.id) else code;
        ie.value = value;
        _ = jsy.write(self.fd, &ie, @sizeOf(ev.struct_input_event));
    }

    fn update(self: *ForceFeedback, speed: f32, time: f32, collided: bool) void {
        if (!self.available) return;

        var level: f32 = 0;

        // Road surface vibration — proportional to speed
        const sf = std.math.clamp(@abs(speed) / 50.0, 0.0, 1.0);
        if (sf > 0.05) {
            const rumble = @sin(time * 65.0) * sf * 3000.0;
            const hash_noise: f32 = @sin(time * 999.7) * 5.0;
            level += rumble + hash_noise * sf * 300.0;
        }

        // Collision impact — strong decaying pulse
        if (collided) self.collision_force = 28000.0;
        self.collision_force *= 0.80;
        if (self.collision_force > 1.0) level += self.collision_force;

        // Upload updated constant
        self.effect.u.constant.level = @intFromFloat(std.math.clamp(level, -32767.0, 32767.0));
        _ = ev.ioctl(self.fd, EVIOCSFF, &self.effect);
    }
};

var g_ff: ForceFeedback = .{};

// === Config ===
const screen_width = 1280;
const screen_height = 720;
const road_y: f32 = 6.0;
const road_half_width: f32 = 6.0;
const spline_spacing: f32 = 3.0;
const collision_spacing: f32 = 12.0;
const building_cull_dist: f32 = 65.0;
const lamp_interval: f32 = 50.0;
const civic_top_speed: f32 = 56.0;
const civic_reverse_speed: f32 = 12.0;
const tau: f32 = std.math.pi * 2.0;

// === Shaders ===
const flat_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\out vec4 fragColor;
    \\out vec3 fragPosition;
    \\void main() {
    \\    fragColor = vertexColor;
    \\    fragPosition = vertexPosition;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const flat_fs =
    \\#version 330
    \\in vec4 fragColor;
    \\in vec3 fragPosition;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 surface = fragColor * colDiffuse;
    \\    float distanceFog = smoothstep(48.0, 235.0, distance(viewPosition.xz, fragPosition.xz));
    \\    float lowHaze = (1.0 - smoothstep(5.0, 42.0, fragPosition.y)) * distanceFog;
    \\    vec3 haze = mix(vec3(0.035, 0.043, 0.039), vec3(0.105, 0.086, 0.058), lowHaze * 0.65);
    \\    surface.rgb = mix(surface.rgb, haze, distanceFog * 0.72);
    \\    finalColor = surface;
    \\}
;

const ground_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec2 vertexTexCoord;
    \\uniform mat4 mvp;
    \\out vec2 fragTexCoord;
    \\out vec3 fragPosition;
    \\void main() {
    \\    fragTexCoord = vertexTexCoord;
    \\    fragPosition = vertexPosition;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const ground_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec3 fragPosition;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec3 tile = texture(texture0, fragTexCoord * 192.0).rgb;
    \\    vec3 ground = tile * vec3(0.43, 0.40, 0.36);
    \\    float haze = smoothstep(115.0, 540.0, distance(viewPosition.xz, fragPosition.xz));
    \\    ground = mix(ground, vec3(0.095, 0.070, 0.042), haze * 0.88);
    \\    finalColor = vec4(ground, 1.0) * colDiffuse;
    \\}
;

const road_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec2 vertexTexCoord;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\out vec2 fragTexCoord;
    \\out vec4 fragColor;
    \\out vec3 fragPosition;
    \\void main() {
    \\    fragTexCoord = vertexTexCoord;
    \\    fragColor = vertexColor;
    \\    fragPosition = vertexPosition;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const road_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\in vec3 fragPosition;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 surface = fragColor * colDiffuse;
    \\    if (fragTexCoord.x >= 0.0) {
    \\        vec3 tarmac = texture(texture0, fragTexCoord).rgb;
    \\        surface.rgb = surface.rgb * 0.68 + tarmac * 0.32;
    \\    }
    \\    float distanceFog = smoothstep(48.0, 235.0, distance(viewPosition.xz, fragPosition.xz));
    \\    vec3 haze = vec3(0.105, 0.086, 0.058);
    \\    surface.rgb = mix(surface.rgb, haze, distanceFog * 0.72);
    \\    finalColor = surface;
    \\}
;

const barrier_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\in vec3 fragPosition;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 surface = texture(texture0, fragTexCoord) * fragColor * colDiffuse;
    \\    float distanceFog = smoothstep(48.0, 235.0, distance(viewPosition.xz, fragPosition.xz));
    \\    surface.rgb = mix(surface.rgb, vec3(0.105, 0.086, 0.058), distanceFog * 0.72);
    \\    finalColor = surface;
    \\}
;

const facade_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\in vec3 fragPosition;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec3 facade = texture(texture0, fragTexCoord).rgb;
    \\    vec3 ambient = fragColor.rgb * 1.35 + vec3(0.11, 0.10, 0.085);
    \\    vec3 surface = facade * ambient;
    \\    float windowLight = smoothstep(0.56, 0.90, dot(facade, vec3(0.2126, 0.7152, 0.0722)));
    \\    surface += windowLight * facade * vec3(0.16, 0.10, 0.045);
    \\    float distanceFog = smoothstep(48.0, 235.0, distance(viewPosition.xz, fragPosition.xz));
    \\    surface = mix(surface, vec3(0.075, 0.071, 0.057), distanceFog * 0.70);
    \\    finalColor = vec4(surface, 1.0) * colDiffuse;
    \\}
;

const roof_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\in vec3 fragPosition;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 viewPosition;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec3 roofDetail = texture(texture0, fragTexCoord).rgb;
    \\    vec3 surface = roofDetail * (fragColor.rgb * 1.25 + vec3(0.19, 0.18, 0.16));
    \\    float distanceFog = smoothstep(48.0, 235.0, distance(viewPosition.xz, fragPosition.xz));
    \\    surface = mix(surface, vec3(0.075, 0.071, 0.057), distanceFog * 0.70);
    \\    finalColor = vec4(surface, 1.0) * colDiffuse;
    \\}
;

const car_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec3 vertexNormal;
    \\in vec2 vertexTexCoord;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\uniform float lightBoost;
    \\out vec2 fragTexCoord;
    \\out vec4 fragColor;
    \\void main() {
    \\    float top = max(vertexNormal.y, 0.0);
    \\    float side = max(dot(normalize(vertexNormal), normalize(vec3(-0.45, 0.35, 0.82))), 0.0);
    \\    vec3 sodium = vec3(1.0, 0.67, 0.36);
    \\    vec3 lighting = vec3(0.15, 0.17, 0.15) + sodium * (top * 0.34 + side * 0.20);
    \\    lighting = min(lighting * lightBoost, vec3(1.25));
    \\    fragTexCoord = vertexTexCoord;
    \\    fragColor = vec4(lighting, 1.0) * vertexColor;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const car_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\out vec4 finalColor;
    \\void main() {
    \\    finalColor = texture(texture0, fragTexCoord) * fragColor * colDiffuse;
    \\}
;

const post_fs =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 source = texture(texture0, fragTexCoord) * fragColor * colDiffuse;
    \\    vec3 linearColor = pow(max(source.rgb, vec3(0.0)), vec3(2.2));
    \\    float luminance = dot(linearColor, vec3(0.2126, 0.7152, 0.0722));
    \\    float shadow = 1.0 - smoothstep(0.025, 0.28, luminance);
    \\    float highlight = smoothstep(0.30, 0.82, luminance);
    \\    linearColor += shadow * vec3(-0.003, 0.006, 0.004);
    \\    linearColor += highlight * vec3(0.014, 0.004, -0.006);
    \\    linearColor = mix(vec3(luminance), linearColor, 0.88);
    \\    linearColor = max((linearColor * 0.98 - 0.012) * 1.07, vec3(0.0));
    \\    vec3 graded = pow(clamp(linearColor, 0.0, 1.0), vec3(1.0 / 2.2));
    \\    graded = clamp((graded - 0.5) * 1.035 + 0.5, 0.0, 1.0);
    \\    vec2 edge = fragTexCoord * (1.0 - fragTexCoord);
    \\    float vignette = smoothstep(0.0, 0.19, edge.x * edge.y * 5.0);
    \\    finalColor = vec4(graded * mix(0.82, 1.0, vignette), source.a);
    \\}
;

// === Math ===
const Vec2 = struct { x: f32, z: f32 };

fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .z = a.z + b.z };
}

fn scale(v: Vec2, s: f32) Vec2 {
    return .{ .x = v.x * s, .z = v.z * s };
}

fn dot(a: Vec2, b: Vec2) f32 {
    return a.x * b.x + a.z * b.z;
}

fn vecLength(v: Vec2) f32 {
    return @sqrt(dot(v, v));
}

fn v3(v: Vec2, y: f32) rl.Vector3 {
    return .{ .x = v.x, .y = y, .z = v.z };
}

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn mixColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const c = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * c),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * c),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * c),
        .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * c),
    };
}

fn localPoint(center: Vec2, yaw: f32, right: f32, fwd: f32) Vec2 {
    return .{
        .x = center.x + @cos(yaw) * right + @sin(yaw) * fwd,
        .z = center.z - @sin(yaw) * right + @cos(yaw) * fwd,
    };
}

fn drivingFov(speed: f32) f32 {
    const speed_ratio = std.math.clamp(@abs(speed) / civic_top_speed, 0.0, 1.0);
    return 68.0 + std.math.pow(f32, speed_ratio, 1.35) * 11.0;
}

// === Spline ===
const SplinePt = struct {
    pos: Vec2,
    tangent: Vec2,
    normal: Vec2,
    dist: f32,
};

const LampData = struct {
    pos: Vec2,
    normal: Vec2,
    cool: bool,
};

const BuildingData = struct {
    pts: []Vec2,
    height: f32,
};

// === World globals ===
var g_spline: []SplinePt = undefined;
var g_collision: []SplinePt = undefined;
var g_buildings: []BuildingData = undefined;
var g_lamps: []LampData = undefined;
var g_length: f32 = 0;
var g_route_closed = true;
var g_arena: std.heap.ArenaAllocator = undefined;

// === Mesh globals ===
var g_flat_shader: rl.Shader = undefined;
var g_road_mesh: rl.Mesh = undefined;
var g_road_mat: rl.Material = undefined;
var g_barrier_mesh: rl.Mesh = undefined;
var g_barrier_mat: rl.Material = undefined;
var g_facade_meshes: [2]rl.Mesh = undefined;
var g_facade_mats: [2]rl.Material = undefined;
var g_roof_mesh: rl.Mesh = undefined;
var g_roof_mat: rl.Material = undefined;
var g_view_position_loc: i32 = -1;
var g_scene_target: rl.RenderTexture2D = undefined;
var g_post_shader: rl.Shader = undefined;
var g_ground_mesh: rl.Mesh = undefined;
var g_ground_mat: rl.Material = undefined;
var g_ground_texture: rl.Texture2D = undefined;
var g_ground_shader: rl.Shader = undefined;
var g_ground_view_position_loc: i32 = -1;
var g_tarmac_texture: rl.Texture2D = undefined;
var g_road_shader: rl.Shader = undefined;
var g_road_view_position_loc: i32 = -1;
var g_barrier_texture: rl.Texture2D = undefined;
var g_barrier_shader: rl.Shader = undefined;
var g_barrier_view_position_loc: i32 = -1;
var g_facade_textures: [2]rl.Texture2D = undefined;
var g_facade_shader: rl.Shader = undefined;
var g_facade_view_position_loc: i32 = -1;
var g_roof_texture: rl.Texture2D = undefined;
var g_roof_shader: rl.Shader = undefined;
var g_roof_view_position_loc: i32 = -1;

fn beginFrame() void {
    rl.beginDrawing();
    g_scene_target.begin();
}

fn endFrame() void {
    g_scene_target.end();
    rl.clearBackground(color(3, 5, 5, 255));
    g_post_shader.activate();
    rl.drawTexturePro(
        g_scene_target.texture,
        .{ .x = 0, .y = 0, .width = @floatFromInt(g_scene_target.texture.width), .height = -@as(f32, @floatFromInt(g_scene_target.texture.height)) },
        .{ .x = 0, .y = 0, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) },
        .{ .x = 0, .y = 0 },
        0,
        color(255, 255, 255, 255),
    );
    g_post_shader.deactivate();
    rl.endDrawing();
}

// === JSON helpers ===
fn jf(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        .number_string => |s| @floatCast(std.fmt.parseFloat(f64, s) catch 0.0),
        else => 0.0,
    };
}

// === World loading ===
fn loadWorld(json_bytes: []const u8) !void {
    g_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const a = g_arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json_bytes, .{});
    const root = parsed.object;

    // --- Route points ---
    const route_obj = root.get("route").?.object;
    const route_arr = route_obj.get("points").?.array;
    g_route_closed = if (route_obj.get("is_closed")) |value| value.bool else true;
    var route_pts = try a.alloc(Vec2, route_arr.items.len);
    for (route_arr.items, 0..) |pt, i| {
        const pos = pt.object.get("position").?.array;
        route_pts[i] = .{ .x = jf(pos.items[0]), .z = jf(pos.items[2]) };
    }

    g_spline = try buildSpline(a, route_pts, spline_spacing, g_route_closed);
    const spline_last = g_spline[g_spline.len - 1];
    g_length = spline_last.dist;
    if (g_route_closed) g_length += vecLength(.{ .x = g_spline[0].pos.x - spline_last.pos.x, .z = g_spline[0].pos.z - spline_last.pos.z });
    g_collision = try buildSpline(a, route_pts, collision_spacing, g_route_closed);

    // --- Buildings (culled by distance to collision spline) ---
    const bld_arr = root.get("buildings").?.array;
    var bld_list: std.ArrayList(BuildingData) = .empty;
    for (bld_arr.items) |bld| {
        const obj = bld.object;
        const measured_height = if (obj.get("height_m")) |h| jf(h) else 0.0;
        const fallback_height = if (obj.get("fallback_height_m")) |h| jf(h) else 12.0;
        const height = if (measured_height > 0.0) measured_height else if (fallback_height > 0.0) fallback_height else 12.0;

        const fps_val = obj.get("footprints") orelse continue;
        const fps = fps_val.array;
        if (fps.items.len == 0) continue;
        const ring = fps.items[0].array;
        if (ring.items.len < 3) continue;

        var pts = try a.alloc(Vec2, ring.items.len);
        var cx: f32 = 0;
        var cz: f32 = 0;
        for (ring.items, 0..) |coord, j| {
            const c = coord.array;
            pts[j] = .{ .x = jf(c.items[0]), .z = jf(c.items[2]) };
            cx += pts[j].x;
            cz += pts[j].z;
        }
        cx /= @floatFromInt(pts.len);
        cz /= @floatFromInt(pts.len);

        if (distToSpline(g_collision, .{ .x = cx, .z = cz }) > building_cull_dist) continue;
        try bld_list.append(a, .{ .pts = pts, .height = height });
    }
    g_buildings = try bld_list.toOwnedSlice(a);

    // --- Lamp positions along spline ---
    var lamp_list: std.ArrayList(LampData) = .empty;
    var d: f32 = 0;
    while (d < g_length) : (d += lamp_interval) {
        const sp = sampleSpline(g_spline, d);
        const idx = lamp_list.items.len;
        try lamp_list.append(a, .{
            .pos = add(sp.pos, scale(sp.normal, road_half_width)),
            .normal = sp.normal,
            .cool = idx % 5 == 2,
        });
    }
    g_lamps = try lamp_list.toOwnedSlice(a);
}

fn buildSpline(a: std.mem.Allocator, route: []const Vec2, spacing: f32, closed: bool) ![]SplinePt {
    var list: std.ArrayList(SplinePt) = .empty;
    const n = route.len;
    const segment_count = if (closed) n else n - 1;

    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const p0 = route[i];
        const p1 = route[(i + 1) % n];
        const seg_len = vecLength(.{ .x = p1.x - p0.x, .z = p1.z - p0.z });
        const steps: usize = @max(1, @as(usize, @intFromFloat(seg_len / spacing)));

        var s: usize = 0;
        while (s < steps) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            try list.append(a, .{
                .pos = .{ .x = p0.x + (p1.x - p0.x) * t, .z = p0.z + (p1.z - p0.z) * t },
                .tangent = .{ .x = 0, .z = 0 },
                .normal = .{ .x = 0, .z = 0 },
                .dist = 0,
            });
        }
    }
    if (!closed) {
        const last = route[n - 1];
        try list.append(a, .{ .pos = last, .tangent = .{ .x = 0, .z = 0 }, .normal = .{ .x = 0, .z = 0 }, .dist = 0 });
    }

    const sp = try list.toOwnedSlice(a);
    const m = sp.len;
    var cumdist: f32 = 0;
    for (0..m) |idx| {
        const prev = sp[if (!closed and idx == 0) 0 else (idx + m - 1) % m];
        const next = sp[if (!closed and idx + 1 == m) m - 1 else (idx + 1) % m];
        const tx = next.pos.x - prev.pos.x;
        const tz = next.pos.z - prev.pos.z;
        const inv = 1.0 / @sqrt(tx * tx + tz * tz);
        sp[idx].tangent = .{ .x = tx * inv, .z = tz * inv };
        sp[idx].normal = .{ .x = sp[idx].tangent.z, .z = -sp[idx].tangent.x };
        sp[idx].dist = cumdist;
        if (idx + 1 < m) {
            const fwd = sp[idx + 1];
            cumdist += vecLength(.{ .x = fwd.pos.x - sp[idx].pos.x, .z = fwd.pos.z - sp[idx].pos.z });
        }
    }
    return sp;
}

fn distToSpline(spline: []const SplinePt, p: Vec2) f32 {
    var best: f32 = std.math.inf(f32);
    for (spline) |sp| {
        const dx = p.x - sp.pos.x;
        const dz = p.z - sp.pos.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < best) best = d2;
    }
    return @sqrt(best);
}

fn sampleSpline(spline: []const SplinePt, distance: f32) SplinePt {
    const d = if (g_route_closed) @mod(distance, g_length) else std.math.clamp(distance, 0.0, g_length);
    var lo: usize = 0;
    var hi: usize = spline.len - 1;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (spline[mid].dist < d) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return spline[0];
    if (d >= spline[spline.len - 1].dist) {
        if (!g_route_closed) return spline[spline.len - 1];
        const sp0 = spline[spline.len - 1];
        const sp1 = spline[0];
        const seg = g_length - sp0.dist;
        const t = if (seg > 0.001) (d - sp0.dist) / seg else 0.0;
        return .{
            .pos = .{ .x = sp0.pos.x + (sp1.pos.x - sp0.pos.x) * t, .z = sp0.pos.z + (sp1.pos.z - sp0.pos.z) * t },
            .tangent = sp0.tangent,
            .normal = sp0.normal,
            .dist = d,
        };
    }
    const sp0 = spline[lo - 1];
    const sp1 = spline[lo];
    const seg = sp1.dist - sp0.dist;
    const t = if (seg > 0.001) (d - sp0.dist) / seg else 0.0;
    return SplinePt{
        .pos = .{ .x = sp0.pos.x + (sp1.pos.x - sp0.pos.x) * t, .z = sp0.pos.z + (sp1.pos.z - sp0.pos.z) * t },
        .tangent = sp0.tangent,
        .normal = sp0.normal,
        .dist = d,
    };
}

const NearestTrack = struct { center: Vec2, tangent: Vec2, normal: Vec2, dist: f32 };

fn nearestTrack(position: Vec2) NearestTrack {
    var result = NearestTrack{ .center = g_collision[0].pos, .tangent = g_collision[0].tangent, .normal = g_collision[0].normal, .dist = g_collision[0].dist };
    var best_d2: f32 = std.math.inf(f32);
    for (g_collision) |sp| {
        const dx = position.x - sp.pos.x;
        const dz = position.z - sp.pos.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < best_d2) {
            best_d2 = d2;
            result = .{ .center = sp.pos, .tangent = sp.tangent, .normal = sp.normal, .dist = sp.dist };
        }
    }
    return result;
}

// === Mesh builder ===
const MeshBuilder = struct {
    alloc: std.mem.Allocator,
    pos: std.ArrayList(f32),
    uv: std.ArrayList(f32),
    col: std.ArrayList(u8),

    fn init(c: std.mem.Allocator) MeshBuilder {
        return .{ .alloc = c, .pos = .empty, .uv = .empty, .col = .empty };
    }

    fn deinit(self: *MeshBuilder) void {
        self.pos.deinit(self.alloc);
        self.uv.deinit(self.alloc);
        self.col.deinit(self.alloc);
    }

    fn vert(self: *MeshBuilder, x: f32, y: f32, z: f32, c: rl.Color) !void {
        try self.vertUv(x, y, z, -1.0, -1.0, c);
    }

    fn vertUv(self: *MeshBuilder, x: f32, y: f32, z: f32, u: f32, v: f32, c: rl.Color) !void {
        try self.pos.appendSlice(self.alloc, &.{ x, y, z });
        try self.uv.appendSlice(self.alloc, &.{ u, v });
        try self.col.appendSlice(self.alloc, &.{ c.r, c.g, c.b, c.a });
    }

    fn tri(self: *MeshBuilder, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32, cx: f32, cy: f32, cz: f32, ca: rl.Color, cb: rl.Color, cc: rl.Color) !void {
        try self.vert(ax, ay, az, ca);
        try self.vert(bx, by, bz, cb);
        try self.vert(cx, cy, cz, cc);
    }

    fn triUv(self: *MeshBuilder, ax: f32, ay: f32, az: f32, au: f32, av: f32, bx: f32, by: f32, bz: f32, bu: f32, bv: f32, cx: f32, cy: f32, cz: f32, cu: f32, cv: f32, ca: rl.Color, cb: rl.Color, cc: rl.Color) !void {
        try self.vertUv(ax, ay, az, au, av, ca);
        try self.vertUv(bx, by, bz, bu, bv, cb);
        try self.vertUv(cx, cy, cz, cu, cv, cc);
    }

    fn build(self: *MeshBuilder, shader: rl.Shader) !struct { mesh: rl.Mesh, mat: rl.Material } {
        const pos_owned = try self.pos.toOwnedSlice(self.alloc);
        const uv_owned = try self.uv.toOwnedSlice(self.alloc);
        const col_owned = try self.col.toOwnedSlice(self.alloc);

        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertexCount = @intCast(pos_owned.len / 3);
        mesh.triangleCount = @intCast(pos_owned.len / 9);
        mesh.vertices = pos_owned.ptr;
        mesh.texcoords = uv_owned.ptr;
        mesh.colors = col_owned.ptr;
        rl.uploadMesh(&mesh, false);

        var mat = try rl.loadMaterialDefault();
        mat.shader = shader;
        return .{ .mesh = mesh, .mat = mat };
    }
};

// === Road mesh baking ===
fn bakeRoadMesh() !void {
    var mb = MeshBuilder.init(std.heap.c_allocator);
    defer mb.deinit();
    const n = g_spline.len;

    const segment_count = if (g_route_closed) n else n - 1;
    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const sp0 = g_spline[i];
        const sp1 = g_spline[(i + 1) % n];
        const p0 = sp0.pos;
        const p1 = sp1.pos;
        const n0 = sp0.normal;
        const n1 = sp1.normal;

        const in0 = add(p0, scale(n0, -road_half_width));
        const in1 = add(p1, scale(n1, -road_half_width));
        const out0 = add(p0, scale(n0, road_half_width));
        const out1 = add(p1, scale(n1, road_half_width));

        // Blend broad sodium pools along the asphalt instead of stepping between flat segments.
        const lamp_period = lamp_interval / spline_spacing;
        const phase0 = @mod(@as(f32, @floatFromInt(i)), lamp_period) / lamp_period;
        const phase1 = @mod(@as(f32, @floatFromInt(i + 1)), lamp_period) / lamp_period;
        const lit0 = std.math.pow(f32, @max(0.0, @cos(phase0 * tau)), 3.0);
        const lit1 = std.math.pow(f32, @max(0.0, @cos(phase1 * tau)), 3.0);
        const asphalt0 = mixColor(color(24, 25, 22, 255), color(61, 48, 31, 255), lit0 * 0.58);
        const asphalt1 = mixColor(color(24, 25, 22, 255), color(61, 48, 31, 255), lit1 * 0.58);

        const texture_u0 = sp0.dist / 56.0;
        const texture_u1 = texture_u0 + vecLength(.{ .x = p1.x - p0.x, .z = p1.z - p0.z }) / 56.0;
        try mb.triUv(in0.x, road_y, in0.z, texture_u0, 0.34, in1.x, road_y, in1.z, texture_u1, 0.34, out1.x, road_y, out1.z, texture_u1, 0.66, asphalt0, asphalt1, asphalt1);
        try mb.triUv(in0.x, road_y, in0.z, texture_u0, 0.34, out1.x, road_y, out1.z, texture_u1, 0.66, out0.x, road_y, out0.z, texture_u0, 0.66, asphalt0, asphalt1, asphalt0);
    }

    const built = try mb.build(g_road_shader);
    g_road_mesh = built.mesh;
    g_road_mat = built.mat;
    g_road_mat.maps[0].texture = g_tarmac_texture;
}

fn barrierQuad(mb: *MeshBuilder, a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, d: rl.Vector3, tex_u0: f32, tex_u1: f32, tint: rl.Color) !void {
    try mb.triUv(a.x, a.y, a.z, tex_u0, 1.0, b.x, b.y, b.z, tex_u1, 1.0, c.x, c.y, c.z, tex_u1, 0.0, tint, tint, tint);
    try mb.triUv(a.x, a.y, a.z, tex_u0, 1.0, c.x, c.y, c.z, tex_u1, 0.0, d.x, d.y, d.z, tex_u0, 0.0, tint, tint, tint);
    try mb.triUv(a.x, a.y, a.z, tex_u0, 1.0, c.x, c.y, c.z, tex_u1, 0.0, b.x, b.y, b.z, tex_u1, 1.0, tint, tint, tint);
    try mb.triUv(a.x, a.y, a.z, tex_u0, 1.0, d.x, d.y, d.z, tex_u0, 0.0, c.x, c.y, c.z, tex_u1, 0.0, tint, tint, tint);
}

fn bakeBarrierMesh() !void {
    var mb = MeshBuilder.init(std.heap.c_allocator);
    defer mb.deinit();
    const n = g_spline.len;
    const segment_count = if (g_route_closed) n else n - 1;
    const look: usize = 6;
    const barrier_height: f32 = 1.55;
    const barrier_thickness: f32 = 0.55;
    const tint = color(205, 194, 174, 255);

    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const prev_i = if (i >= look) i - look else if (g_route_closed) n + i - look else 0;
        const next_i = if (i + look < n) i + look else if (g_route_closed) (i + look) % n else n - 1;
        const prev_tangent = g_spline[prev_i].tangent;
        const next_tangent = g_spline[next_i].tangent;
        const curvature = @abs(prev_tangent.x * next_tangent.z - prev_tangent.z * next_tangent.x);
        if (curvature < 0.055) continue;

        const sp0 = g_spline[i];
        const sp1 = g_spline[(i + 1) % n];
        const segment_length = vecLength(.{ .x = sp1.pos.x - sp0.pos.x, .z = sp1.pos.z - sp0.pos.z });
        const tex_u0 = sp0.dist / 7.5;
        const tex_u1 = tex_u0 + segment_length / 7.5;

        for ([_]f32{ -1.0, 1.0 }) |side| {
            const inner0 = add(sp0.pos, scale(sp0.normal, side * road_half_width));
            const inner1 = add(sp1.pos, scale(sp1.normal, side * road_half_width));
            const outer0 = add(sp0.pos, scale(sp0.normal, side * (road_half_width + barrier_thickness)));
            const outer1 = add(sp1.pos, scale(sp1.normal, side * (road_half_width + barrier_thickness)));
            const inner0_bottom = v3(inner0, road_y);
            const inner1_bottom = v3(inner1, road_y);
            const outer0_bottom = v3(outer0, road_y);
            const outer1_bottom = v3(outer1, road_y);
            const inner0_top = v3(inner0, road_y + barrier_height);
            const inner1_top = v3(inner1, road_y + barrier_height);
            const outer0_top = v3(outer0, road_y + barrier_height);
            const outer1_top = v3(outer1, road_y + barrier_height);

            try barrierQuad(&mb, inner0_bottom, inner1_bottom, inner1_top, inner0_top, tex_u0, tex_u1, tint);
            try barrierQuad(&mb, outer1_bottom, outer0_bottom, outer0_top, outer1_top, tex_u0, tex_u1, tint);
            try barrierQuad(&mb, inner0_top, inner1_top, outer1_top, outer0_top, tex_u0, tex_u1, tint);
        }
    }

    const built = try mb.build(g_barrier_shader);
    g_barrier_mesh = built.mesh;
    g_barrier_mat = built.mat;
    g_barrier_mat.maps[0].texture = g_barrier_texture;
}

// === Building mesh baking ===
fn bakeBuildingMesh() !void {
    var wall_builders = [2]MeshBuilder{ MeshBuilder.init(std.heap.c_allocator), MeshBuilder.init(std.heap.c_allocator) };
    defer for (&wall_builders) |*builder| builder.deinit();
    var roof_builder = MeshBuilder.init(std.heap.c_allocator);
    defer roof_builder.deinit();

    var b: usize = 0;
    while (b < g_buildings.len) : (b += 1) {
        const bld = g_buildings[b];
        const pts = bld.pts;
        const h = bld.height;
        if (pts.len < 3) continue;

        // Deterministic hash for building color variation
        const hsh: u32 = @intCast(b);
        const facade = switch (hsh % 4) {
            0 => color(43, 51, 49, 255),
            1 => color(54, 50, 42, 255),
            2 => color(59, 43, 38, 255),
            else => color(42, 53, 55, 255),
        };
        const wall_dark = mixColor(facade, color(15, 19, 19, 255), 0.35);
        const wall_top = mixColor(facade, color(152, 100, 55, 255), 0.18);

        // Vertical faces use one of two facade families; roofs remain untextured.
        const facade_index = hsh % wall_builders.len;
        const facade_aspect: f32 = if (facade_index == 0) 1.5 else 1.0;
        const wall_builder = &wall_builders[facade_index];
        var j: usize = 0;
        while (j < pts.len) : (j += 1) {
            const pa = pts[j];
            const pb = pts[(j + 1) % pts.len];
            const side_length = vecLength(.{ .x = pb.x - pa.x, .z = pb.z - pa.z });
            const repeat_u = @max(1.0, side_length / @max(h * facade_aspect, 1.0));
            try wall_builder.triUv(pa.x, 0, pa.z, 0, 1, pb.x, 0, pb.z, repeat_u, 1, pb.x, h, pb.z, repeat_u, 0, wall_dark, wall_dark, wall_top);
            try wall_builder.triUv(pa.x, 0, pa.z, 0, 1, pb.x, h, pb.z, repeat_u, 0, pa.x, h, pa.z, 0, 0, wall_dark, wall_top, wall_top);
        }

        // Roof (simple fan from centroid)
        var cx: f32 = 0;
        var cz: f32 = 0;
        for (pts) |p| {
            cx += p.x;
            cz += p.z;
        }
        cx /= @floatFromInt(pts.len);
        cz /= @floatFromInt(pts.len);
        const roof = mixColor(facade, color(13, 17, 17, 255), 0.48);
        j = 0;
        while (j < pts.len) : (j += 1) {
            const pa = pts[j];
            const pb = pts[(j + 1) % pts.len];
            const texture_scale: f32 = 1.0 / 36.0;
            try roof_builder.triUv(cx, h, cz, cx * texture_scale, cz * texture_scale, pa.x, h, pa.z, pa.x * texture_scale, pa.z * texture_scale, pb.x, h, pb.z, pb.x * texture_scale, pb.z * texture_scale, roof, roof, roof);
        }
    }

    for (&wall_builders, 0..) |*builder, index| {
        const built = try builder.build(g_facade_shader);
        g_facade_meshes[index] = built.mesh;
        g_facade_mats[index] = built.mat;
        g_facade_mats[index].maps[0].texture = g_facade_textures[index];
    }
    const roof_built = try roof_builder.build(g_roof_shader);
    g_roof_mesh = roof_built.mesh;
    g_roof_mat = roof_built.mat;
    g_roof_mat.maps[0].texture = g_roof_texture;
}

// === Car physics ===
const Car = struct {
    position: Vec2 = .{ .x = 0, .z = 0 },
    velocity: Vec2 = .{ .x = 0, .z = 0 },
    yaw: f32 = 0,
    yaw_rate: f32 = 0,
    speed: f32 = 0,
    steer_visual: f32 = 0,
    drift_amount: f32 = 0,
    collided: bool = false,

    fn reset(self: *Car) void {
        const start = g_spline[0];
        self.position = start.pos;
        self.velocity = .{ .x = 0, .z = 0 };
        self.yaw = std.math.atan2(start.tangent.x, start.tangent.z);
        self.yaw_rate = 0;
        self.speed = 0;
        self.steer_visual = 0;
        self.drift_amount = 0;
    }

    fn update(self: *Car, dt: f32) void {
        // Keyboard input
        const kb_throttle: f32 = if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) 1.0 else 0.0;
        const kb_brake: f32 = if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) 1.0 else 0.0;
        var kb_steer: f32 = 0.0;
        if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) kb_steer += 1.0;
        if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) kb_steer -= 1.0;
        const kb_handbrake = rl.isKeyDown(.space);

        // Combine with wheel input (overrides keyboard when active)
        var throttle = kb_throttle;
        var brake = kb_brake;
        var steer = kb_steer;
        var handbrake = kb_handbrake;

        if (g_wheel.available) {
            const raw_steer = g_wheel.steering();
            if (@abs(raw_steer) > 0.02) {
                // Non-linear curve: more responsive near center, full lock at edges
                const abs_s = @abs(raw_steer);
                const sign: f32 = if (raw_steer > 0) 1.0 else -1.0;
                steer = -sign * std.math.pow(f32, abs_s, 0.65) * 1.3;
            }

            const wheel_throttle = g_wheel.throttle();
            const wheel_brake = g_wheel.brake();
            if (wheel_throttle > 0.04) throttle = wheel_throttle;
            if (wheel_brake > 0.04) brake = wheel_brake;

            // Button 0 = handbrake, Button 2 = reset
            if (g_wheel.buttons[0]) handbrake = true;
        }

        var forward = Vec2{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        var right = Vec2{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        var long_speed = dot(self.velocity, forward);
        var lat_speed = dot(self.velocity, right);

        if (throttle > 0.0) {
            const speed_ratio = std.math.clamp(@abs(long_speed) / civic_top_speed, 0.0, 1.0);
            const power_falloff = 1.0 - std.math.pow(f32, speed_ratio, 2.2);
            self.velocity = add(self.velocity, scale(forward, 4.0 * power_falloff * dt));
        }
        if (brake > 0.0) {
            const force: f32 = if (long_speed > 1.0) -11.5 else if (long_speed > -civic_reverse_speed) -4.0 else 0.0;
            self.velocity = add(self.velocity, scale(forward, force * dt));
        }

        const speed_factor = std.math.clamp(@abs(long_speed) / 14.0, 0.0, 1.0);
        const rev: f32 = if (long_speed < -0.5) -1.0 else 1.0;
        const steer_rate: f32 = if (handbrake) 1.72 else 1.18;
        const target_yaw_rate = steer * steer_rate * speed_factor * rev;
        const yaw_resp: f32 = if (handbrake) 7.5 else 5.0;
        self.yaw_rate += (target_yaw_rate - self.yaw_rate) * std.math.clamp(yaw_resp * dt, 0.0, 1.0);
        if (handbrake and @abs(long_speed) > 18.0) self.yaw_rate += steer * 1.25 * dt * rev;
        if (@abs(steer) < 0.05) self.yaw_rate *= std.math.clamp(1.0 - 3.2 * dt, 0.0, 1.0);
        self.yaw += self.yaw_rate * dt;

        forward = .{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        right = .{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        long_speed = dot(self.velocity, forward);
        lat_speed = dot(self.velocity, right);
        var grip: f32 = if (handbrake) 0.72 else 6.8;
        if (!handbrake and throttle > 0.0 and @abs(lat_speed) > 4.5 and @abs(long_speed) > 24.0) grip = 2.7;
        self.velocity = add(self.velocity, scale(right, -lat_speed * std.math.clamp(grip * dt, 0.0, 1.0)));

        const drag: f32 = if (handbrake) 0.52 else 0.0035;
        self.velocity = scale(self.velocity, std.math.clamp(1.0 - drag * dt, 0.0, 1.0));
        const vl = vecLength(self.velocity);
        if (vl > civic_top_speed) self.velocity = scale(self.velocity, civic_top_speed / vl);

        self.position = add(self.position, scale(self.velocity, dt));
        self.speed = dot(self.velocity, forward);
        const drift_t = std.math.clamp(@abs(dot(self.velocity, right)) / 15.0, 0.0, 1.0) * speed_factor;
        self.drift_amount += (drift_t - self.drift_amount) * std.math.clamp(dt * 7.0, 0.0, 1.0);
        self.steer_visual += (steer - self.steer_visual) * std.math.clamp(dt * 9.0, 0.0, 1.0);

        const nearest = nearestTrack(self.position);
        const lateral = dot(.{ .x = self.position.x - nearest.center.x, .z = self.position.z - nearest.center.z }, nearest.normal);
        const limit = road_half_width - 1.1;
        self.collided = false;
        if (@abs(lateral) > limit) {
            const excess = lateral - std.math.clamp(lateral, -limit, limit);
            self.position.x -= nearest.normal.x * excess;
            self.position.z -= nearest.normal.z * excess;
            const ns = dot(self.velocity, nearest.normal);
            if (ns * lateral > 0.0) self.velocity = add(self.velocity, scale(nearest.normal, -ns * 1.25));
            self.velocity = scale(self.velocity, 0.76);
            self.collided = true;
            self.speed = dot(self.velocity, forward);
        }
        if (!g_route_closed) {
            const endpoint_margin: f32 = 2.2;
            const along = dot(.{ .x = self.position.x - nearest.center.x, .z = self.position.z - nearest.center.z }, nearest.tangent);
            const route_distance = nearest.dist + along;
            const beyond_start = nearest.dist < collision_spacing and route_distance < endpoint_margin;
            const beyond_end = nearest.dist > g_length - collision_spacing and route_distance > g_length - endpoint_margin;
            if (beyond_start or beyond_end) {
                const correction = if (beyond_start) endpoint_margin - route_distance else g_length - endpoint_margin - route_distance;
                self.position = add(self.position, scale(nearest.tangent, correction));
                const endpoint_speed = dot(self.velocity, nearest.tangent);
                if ((beyond_start and endpoint_speed < 0.0) or (beyond_end and endpoint_speed > 0.0)) {
                    self.velocity = add(self.velocity, scale(nearest.tangent, -endpoint_speed * 1.25));
                    self.velocity = scale(self.velocity, 0.76);
                }
                self.collided = true;
                self.speed = dot(self.velocity, forward);
            }
        }
    }
};

// === Camera ===
const CameraRig = struct {
    anchor: Vec2 = .{ .x = 0, .z = 0 },
    yaw: f32 = 0,

    fn reset(self: *CameraRig, car: Car) void {
        self.anchor = car.position;
        self.yaw = car.yaw;
    }

    fn update(self: *CameraRig, car: Car, dt: f32) rl.Camera3D {
        const offset = Vec2{ .x = car.position.x - self.anchor.x, .z = car.position.z - self.anchor.z };
        const ol = vecLength(offset);
        const dead_zone: f32 = 0.72;
        if (ol > dead_zone) {
            const desired = add(car.position, scale(offset, -dead_zone / ol));
            self.anchor = add(self.anchor, scale(.{ .x = desired.x - self.anchor.x, .z = desired.z - self.anchor.z }, std.math.clamp(dt * 11.0, 0.0, 1.0)));
        }

        const yaw_delta = @mod(car.yaw - self.yaw + std.math.pi, tau) - std.math.pi;
        self.yaw += yaw_delta * std.math.clamp(dt * 8.5, 0.0, 1.0);
        const cf = Vec2{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        const cam_dist = 10.5 - std.math.clamp(@abs(car.speed) * 0.018, 0.0, 1.5);
        return .{
            .position = .{
                .x = self.anchor.x - cf.x * cam_dist,
                .y = road_y + 5.2,
                .z = self.anchor.z - cf.z * cam_dist,
            },
            .target = .{
                .x = self.anchor.x + cf.x * 5.5,
                .y = road_y + 1.15,
                .z = self.anchor.z + cf.z * 5.5,
            },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = drivingFov(car.speed),
            .projection = .perspective,
        };
    }
};

// === Player model ===
const PlayerModel = struct {
    model: rl.Model,
    shader: rl.Shader,
    bounds: rl.BoundingBox,
    scale: f32,
    light_boost_loc: i32,

    fn init() !PlayerModel {
        var model = try rl.loadModel("assets/cars/civic-raylib.glb");
        errdefer model.unload();
        const shader = try rl.loadShaderFromMemory(car_vs, car_fs);
        errdefer shader.unload();
        var i: usize = 0;
        while (i < @as(usize, @intCast(model.materialCount))) : (i += 1) model.materials[i].shader = shader;
        const light_boost_loc = rl.getShaderLocation(shader, "lightBoost");
        var light_boost: f32 = 1.0;
        rl.setShaderValue(shader, light_boost_loc, &light_boost, .float);

        const bounds = rl.getModelBoundingBox(model);
        const model_length = @max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z);
        return .{ .model = model, .shader = shader, .bounds = bounds, .scale = 4.35 / model_length, .light_boost_loc = light_boost_loc };
    }

    fn unload(self: PlayerModel) void {
        self.model.unload();
        self.shader.unload();
    }

    fn draw(self: PlayerModel, position: Vec2, yaw: f32) void {
        const angle = yaw + std.math.pi * 0.5;
        const cx = (self.bounds.min.x + self.bounds.max.x) * 0.5;
        const cz = (self.bounds.min.z + self.bounds.max.z) * 0.5;
        const rx = cx * @cos(angle) + cz * @sin(angle);
        const rz = -cx * @sin(angle) + cz * @cos(angle);
        self.model.drawEx(
            .{
                .x = position.x - rx * self.scale,
                .y = road_y + 0.14 - self.bounds.min.y * self.scale,
                .z = position.z - rz * self.scale,
            },
            .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            angle * 180.0 / std.math.pi,
            .{ .x = self.scale, .y = self.scale, .z = self.scale },
            color(255, 255, 255, 255),
        );
    }

    fn setLightBoost(self: PlayerModel, boost: f32) void {
        var value = boost;
        rl.setShaderValue(self.shader, self.light_boost_loc, &value, .float);
    }
};

// === Drawing ===
fn drawHeadlightWash(position: Vec2, yaw: f32) void {
    const nl = localPoint(position, yaw, -0.72, 2.0);
    const nr = localPoint(position, yaw, 0.72, 2.0);
    const fl = localPoint(position, yaw, -3.6, 14.5);
    const fr = localPoint(position, yaw, 3.6, 14.5);
    const near = color(255, 226, 177, 35);
    const far = color(255, 183, 94, 0);
    rl.gl.rlBegin(rl.gl.rl_triangles);
    rl.gl.rlColor4ub(near.r, near.g, near.b, near.a);
    rl.gl.rlVertex3f(nl.x, road_y + 0.06, nl.z);
    rl.gl.rlColor4ub(far.r, far.g, far.b, far.a);
    rl.gl.rlVertex3f(fl.x, road_y + 0.06, fl.z);
    rl.gl.rlVertex3f(fr.x, road_y + 0.06, fr.z);
    rl.gl.rlColor4ub(near.r, near.g, near.b, near.a);
    rl.gl.rlVertex3f(nl.x, road_y + 0.06, nl.z);
    rl.gl.rlColor4ub(far.r, far.g, far.b, far.a);
    rl.gl.rlVertex3f(fr.x, road_y + 0.06, fr.z);
    rl.gl.rlColor4ub(near.r, near.g, near.b, near.a);
    rl.gl.rlVertex3f(nr.x, road_y + 0.06, nr.z);
    rl.gl.rlEnd();
}

fn drawSkybox() void {
    const width = rl.getScreenWidth();
    const height = rl.getScreenHeight();
    const upper_band = @divTrunc(height, 3);
    const horizon = @divTrunc(height, 2);

    rl.clearBackground(color(1, 2, 3, 255));
    rl.drawRectangleGradientV(0, 0, width, upper_band, color(1, 2, 3, 255), color(4, 9, 10, 255));
    rl.drawRectangleGradientV(0, upper_band, width, horizon - upper_band, color(4, 9, 10, 255), color(58, 39, 22, 255));

    // A broad, low glow suggests city light below the horizon without visible sky detail.
    rl.drawCircleGradient(
        .{ .x = @as(f32, @floatFromInt(width)) * 0.52, .y = @as(f32, @floatFromInt(horizon)) + 110.0 },
        @as(f32, @floatFromInt(width)) * 0.42,
        color(113, 62, 26, 35),
        color(28, 27, 20, 0),
    );
}

fn boxOriented(center: Vec2, y: f32, w: f32, h: f32, l: f32, yaw: f32, tint: rl.Color) void {
    const bl = localPoint(center, yaw, -w * 0.5, -l * 0.5);
    const br = localPoint(center, yaw, w * 0.5, -l * 0.5);
    const fl = localPoint(center, yaw, -w * 0.5, l * 0.5);
    const fr = localPoint(center, yaw, w * 0.5, l * 0.5);
    const y0 = y;
    const y1 = y + h;
    const dark = mixColor(tint, color(6, 5, 4, 255), 0.55);
    const side = mixColor(tint, color(23, 20, 17, 255), 0.34);
    const top = mixColor(tint, color(181, 132, 76, 255), 0.18);
    const face = struct {
        fn q(a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, d: rl.Vector3, col: rl.Color) void {
            rl.gl.rlBegin(rl.gl.rl_triangles);
            rl.gl.rlColor4ub(col.r, col.g, col.b, col.a);
            rl.gl.rlVertex3f(a.x, a.y, a.z);
            rl.gl.rlVertex3f(c.x, c.y, c.z);
            rl.gl.rlVertex3f(b.x, b.y, b.z);
            rl.gl.rlVertex3f(a.x, a.y, a.z);
            rl.gl.rlVertex3f(d.x, d.y, d.z);
            rl.gl.rlVertex3f(c.x, c.y, c.z);
            rl.gl.rlEnd();
        }
    };
    const bl0 = v3(bl, y0);
    const br0 = v3(br, y0);
    const fl0 = v3(fl, y0);
    const fr0 = v3(fr, y0);
    const bl1 = v3(bl, y1);
    const br1 = v3(br, y1);
    const fl1 = v3(fl, y1);
    const fr1 = v3(fr, y1);
    face.q(bl0, br0, br1, bl1, dark);
    face.q(fr0, fl0, fl1, fr1, tint);
    face.q(fl0, bl0, bl1, fl1, side);
    face.q(br0, fr0, fr1, br1, side);
    face.q(bl1, br1, fr1, fl1, top);
}

fn drawCar(position: Vec2, yaw: f32, paint: rl.Color) void {
    drawHeadlightWash(position, yaw);
    boxOriented(position, road_y + 0.18, 2.0, 0.62, 4.25, yaw, paint);
    const cabin = localPoint(position, yaw, 0, -0.15);
    boxOriented(cabin, road_y + 0.78, 1.62, 0.48, 2.05, yaw, mixColor(paint, color(18, 24, 25, 255), 0.72));
    const nose = localPoint(position, yaw, 0, 2.1);
    for ([_]f32{ -0.62, 0.62 }) |side| {
        const lamp = localPoint(nose, yaw, side, 0);
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.13, color(255, 249, 222, 255));
    }
    const tail = localPoint(position, yaw, 0, -2.1);
    for ([_]f32{ -0.68, 0.68 }) |side| {
        const lamp = localPoint(tail, yaw, side, 0);
        rl.drawSphere(v3(lamp, road_y + 0.5), 0.12, color(255, 61, 38, 255));
    }
}

fn drawPlayerCar(pm: PlayerModel, position: Vec2, yaw: f32) void {
    drawHeadlightWash(position, yaw);
    pm.setLightBoost(1.0);
    pm.draw(position, yaw);
    const nose = localPoint(position, yaw, 0, 2.16);
    for ([_]f32{ -0.62, 0.62 }) |side| {
        const lamp = localPoint(nose, yaw, side, 0);
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.2, color(255, 227, 177, 105));
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.11, color(255, 249, 222, 255));
    }
    const tail = localPoint(position, yaw, 0, -2.16);
    for ([_]f32{ -0.68, 0.68 }) |side| {
        const lamp = localPoint(tail, yaw, side, 0);
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.22, color(255, 24, 19, 90));
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.11, color(255, 61, 38, 255));
    }
}

fn drawLampCone(apex: rl.Vector3, cool: bool) void {
    const top_color = if (cool) color(122, 236, 216, 38) else color(255, 171, 91, 46);
    const middle_color = if (cool) color(93, 215, 201, 16) else color(241, 132, 62, 20);
    const edge_color = if (cool) color(80, 191, 179, 0) else color(220, 104, 40, 0);
    const slices: usize = 20;
    const middle_y = apex.y + (road_y - apex.y) * 0.52;

    rl.beginBlendMode(.alpha);
    rl.gl.rlDisableDepthMask();
    rl.gl.rlDisableBackfaceCulling();
    rl.gl.rlBegin(rl.gl.rl_triangles);
    for (0..slices) |slice| {
        const a0 = tau * @as(f32, @floatFromInt(slice)) / @as(f32, @floatFromInt(slices));
        const a1 = tau * @as(f32, @floatFromInt(slice + 1)) / @as(f32, @floatFromInt(slices));
        const middle0 = rl.Vector3{ .x = apex.x + @cos(a0) * 1.8, .y = middle_y, .z = apex.z + @sin(a0) * 2.55 };
        const middle1 = rl.Vector3{ .x = apex.x + @cos(a1) * 1.8, .y = middle_y, .z = apex.z + @sin(a1) * 2.55 };
        const base0 = rl.Vector3{ .x = apex.x + @cos(a0) * 3.8, .y = road_y + 0.08, .z = apex.z + @sin(a0) * 5.4 };
        const base1 = rl.Vector3{ .x = apex.x + @cos(a1) * 3.8, .y = road_y + 0.08, .z = apex.z + @sin(a1) * 5.4 };
        rl.gl.rlColor4ub(top_color.r, top_color.g, top_color.b, top_color.a);
        rl.gl.rlVertex3f(apex.x, apex.y, apex.z);
        rl.gl.rlColor4ub(middle_color.r, middle_color.g, middle_color.b, middle_color.a);
        rl.gl.rlVertex3f(middle0.x, middle0.y, middle0.z);
        rl.gl.rlVertex3f(middle1.x, middle1.y, middle1.z);
        rl.gl.rlVertex3f(middle0.x, middle0.y, middle0.z);
        rl.gl.rlColor4ub(edge_color.r, edge_color.g, edge_color.b, edge_color.a);
        rl.gl.rlVertex3f(base0.x, base0.y, base0.z);
        rl.gl.rlVertex3f(base1.x, base1.y, base1.z);
        rl.gl.rlColor4ub(middle_color.r, middle_color.g, middle_color.b, middle_color.a);
        rl.gl.rlVertex3f(middle0.x, middle0.y, middle0.z);
        rl.gl.rlColor4ub(edge_color.r, edge_color.g, edge_color.b, edge_color.a);
        rl.gl.rlVertex3f(base1.x, base1.y, base1.z);
        rl.gl.rlColor4ub(middle_color.r, middle_color.g, middle_color.b, middle_color.a);
        rl.gl.rlVertex3f(middle1.x, middle1.y, middle1.z);
    }
    rl.gl.rlEnd();
    rl.gl.rlEnableBackfaceCulling();
    rl.gl.rlEnableDepthMask();
    rl.endBlendMode();
}

fn drawLamps(car_pos: Vec2) void {
    const cull_sq = 180.0 * 180.0;
    for (g_lamps) |lamp| {
        const dx = lamp.pos.x - car_pos.x;
        const dz = lamp.pos.z - car_pos.z;
        if (dx * dx + dz * dz > cull_sq) continue;

        const base = v3(lamp.pos, road_y);
        const top = v3(lamp.pos, road_y + 5.0);
        const lamp_pos = add(lamp.pos, scale(lamp.normal, -2.8));
        const lamp3 = v3(lamp_pos, road_y + 4.85);
        drawLampCone(lamp3, lamp.cool);
        rl.drawCylinderEx(base, top, 0.09, 0.06, 6, color(73, 67, 59, 255));
        rl.drawCylinderEx(top, lamp3, 0.06, 0.045, 6, color(91, 79, 65, 255));
        const core = if (lamp.cool) color(211, 255, 235, 255) else color(255, 225, 165, 255);
        rl.drawSphere(lamp3, 0.11, core);
    }
}

fn drawTraffic(elapsed: f32) void {
    const paints = [_]rl.Color{
        color(199, 195, 181, 255), color(27, 42, 90, 255),  color(119, 35, 29, 255),
        color(34, 34, 31, 255),    color(137, 94, 42, 255), color(40, 67, 58, 255),
    };
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const travel = fi * (g_length / 12.0) + elapsed * (8.0 + fi * 0.5);
        const phase = if (g_route_closed) @mod(travel, g_length) else @mod(travel, g_length * 2.0);
        const reverse = !g_route_closed and phase > g_length;
        const d = if (reverse) g_length * 2.0 - phase else phase;
        const sp = sampleSpline(g_spline, d);
        const lane: f32 = if (i % 2 == 0) -2.5 else 2.5;
        const pos = add(sp.pos, scale(sp.normal, lane));
        const reverse_yaw: f32 = if (reverse) std.math.pi else 0.0;
        const yaw = std.math.atan2(sp.tangent.x, sp.tangent.z) + reverse_yaw;
        drawCar(pos, yaw, paints[i % paints.len]);
    }
}

fn drawHud(car: Car) void {
    const width = rl.getScreenWidth();
    const height = rl.getScreenHeight();
    const sx = width - 82;
    const sy = height - 94;

    rl.drawRectangleGradientV(0, 0, width, 88, color(5, 8, 8, 185), color(5, 8, 8, 0));
    rl.drawText("ASA MADE", 28, 22, 24, color(226, 224, 207, 255));
    rl.drawText("HANSHIN LOOP // OSAKA", 29, 50, 12, color(117, 196, 181, 255));
    rl.drawFPS(width - 92, 18);

    rl.drawCircleGradient(.{ .x = @floatFromInt(sx), .y = @floatFromInt(sy) }, 76, color(8, 12, 12, 205), color(8, 12, 12, 30));
    rl.drawCircleLines(sx, sy, 59, color(102, 111, 101, 190));
    const kmh: i32 = @intFromFloat(@abs(car.speed) * 3.6);
    var speed_buf: [16]u8 = undefined;
    const speed_text = std.fmt.bufPrintZ(&speed_buf, "{d:0>3}", .{kmh}) catch "---";
    rl.drawText(speed_text, sx - 39, sy - 24, 38, color(239, 245, 241, 255));
    rl.drawText("KM/H", sx - 18, sy + 18, 13, color(117, 196, 181, 255));
    rl.drawText(if (car.speed < -0.5) "R" else "5", sx + 20, sy + 25, 22, color(231, 70, 48, 255));
    if (car.drift_amount > 0.18) {
        rl.drawText("DRIFT", sx - 25, sy - 58, 16, color(231, 70, 48, 255));
    }

    rl.drawRectangle(27, height - 57, 205, 5, color(29, 40, 51, 230));
    const bw: i32 = @intFromFloat(205.0 * std.math.clamp(@abs(car.speed) / civic_top_speed, 0.0, 1.0));
    rl.drawRectangle(27, height - 57, bw, 5, color(205, 126, 48, 255));
    rl.drawText("SPEED BREAKER", 27, height - 45, 12, color(155, 174, 181, 255));
    rl.drawText("WASD/WHEEL DRIVE  SPACE HANDBRAKE  R RESET", 27, height - 21, 11, color(122, 139, 148, 255));

    if (g_wheel.available) {
        rl.drawText("DFP CONNECTED", width - 120, height - 21, 11, color(31, 190, 217, 255));
    }

    drawMinimap(car);
}

fn drawDebugWheel() void {
    const w = rl.getScreenWidth();
    const h = rl.getScreenHeight();
    const panel_w = 280;
    const panel_x = w - panel_w - 8;
    const y0: i32 = 8;

    rl.drawRectangle(panel_x, y0, panel_w, h - 16, color(6, 8, 14, 220));
    rl.drawRectangleLines(panel_x, y0, panel_w, h - 16, color(40, 50, 60, 255));

    var buf: [128]u8 = undefined;
    var y: i32 = y0 + 8;

    if (!g_wheel.available) {
        rl.drawText("NO WHEEL (/dev/input/js0)", panel_x + 8, y, 13, color(200, 80, 80, 255));
        return;
    }

    rl.drawText("WHEEL DEBUG  [TAB close]", panel_x + 8, y, 13, color(224, 237, 239, 255));
    y += 22;

    // Raw axes
    rl.drawText("RAW AXES", panel_x + 8, y, 11, color(66, 201, 219, 255));
    y += 16;
    var i: usize = 0;
    const labels = [_][]const u8{ "steer", "gas", "brake", "hat_x", "hat_y", "a5", "a6", "a7" };
    while (i < 8) : (i += 1) {
        const v = g_wheel.axes[i];
        const bar_x = panel_x + 60;
        const bar_w = 180;
        const center_x = bar_x + @divTrunc(bar_w, 2);
        // Center line
        rl.drawLine(center_x, y + 2, center_x, y + 10, color(50, 55, 65, 255));
        // Value bar
        const half = @divTrunc(bar_w, 2);
        if (v >= 0) {
            const fw: i32 = @intFromFloat(@as(f32, @floatFromInt(half)) * v);
            rl.drawRectangle(center_x, y + 3, fw, 7, color(31, 190, 217, 255));
        } else {
            const fw: i32 = @intFromFloat(@as(f32, @floatFromInt(half)) * (-v));
            rl.drawRectangle(center_x - fw, y + 3, fw, 7, color(245, 67, 104, 255));
        }
        const label = if (i < labels.len) labels[i] else "??";
        const text = std.fmt.bufPrintZ(&buf, "{s:>5} {d:.3}", .{ label, v }) catch "";
        rl.drawText(text, panel_x + 8, y + 2, 10, color(155, 174, 181, 255));
        y += 14;
    }

    y += 6;

    // Mapped controls
    rl.drawText("MAPPED", panel_x + 8, y, 11, color(66, 201, 219, 255));
    y += 16;

    const mappings = [_]struct { name: []const u8, val: f32 }{
        .{ .name = "steer", .val = g_wheel.steering() },
        .{ .name = "thrtl", .val = g_wheel.throttle() },
        .{ .name = "brake", .val = g_wheel.brake() },
    };
    for (mappings) |m| {
        const bar_x = panel_x + 60;
        const bar_w = 180;
        const fw: i32 = @intFromFloat(@as(f32, @floatFromInt(bar_w)) * std.math.clamp(@abs(m.val), 0.0, 1.0));
        rl.drawRectangle(bar_x, y + 3, fw, 7, color(31, 190, 217, 255));
        const text = std.fmt.bufPrintZ(&buf, "{s:>5} {d:.3}", .{ m.name, m.val }) catch "";
        rl.drawText(text, panel_x + 8, y + 2, 10, color(155, 174, 181, 255));
        y += 14;
    }

    y += 6;

    // Buttons
    rl.drawText("BUTTONS", panel_x + 8, y, 11, color(66, 201, 219, 255));
    y += 16;
    var col: i32 = 0;
    var btn: usize = 0;
    while (btn < 16) : (btn += 1) {
        const bx = panel_x + 8 + col * 34;
        const pressed = g_wheel.buttons[btn];
        const c = if (pressed) color(31, 190, 217, 255) else color(40, 45, 55, 255);
        rl.drawRectangle(bx, y, 30, 18, c);
        const text = std.fmt.bufPrintZ(&buf, "{d}", .{btn}) catch "";
        rl.drawText(text, bx + 10, y + 3, 10, if (pressed) color(6, 8, 14, 255) else color(100, 110, 120, 255));
        col += 1;
        if (col >= 7) {
            col = 0;
            y += 22;
        }
    }
}

// === Loading screen ===
var g_load_anim: f32 = 0;
var g_title_tex: rl.Texture2D = undefined;

fn drawLoading(stage: [:0]const u8) void {
    g_load_anim += 0.15;
    beginFrame();
    defer endFrame();
    rl.clearBackground(color(4, 4, 3, 255));

    // Title image background (cover-fit)
    const img_w: f32 = @floatFromInt(g_title_tex.width);
    const img_h: f32 = @floatFromInt(g_title_tex.height);
    const scr_w: f32 = @floatFromInt(screen_width);
    const scr_h: f32 = @floatFromInt(screen_height);
    const cover_scale = @max(scr_w / img_w, scr_h / img_h);
    const draw_w = img_w * cover_scale;
    const draw_h = img_h * cover_scale;
    rl.drawTexturePro(
        g_title_tex,
        .{ .x = 0, .y = 0, .width = img_w, .height = img_h },
        .{ .x = (scr_w - draw_w) * 0.5, .y = (scr_h - draw_h) * 0.5, .width = draw_w, .height = draw_h },
        .{ .x = 0, .y = 0 },
        0,
        color(255, 255, 255, 255),
    );
    // Dark overlay for text readability
    rl.drawRectangle(0, 0, screen_width, screen_height, color(4, 6, 10, 140));

    const cx = screen_width / 2;
    const cy = screen_height / 2;

    // Title
    rl.drawText("ASA MADE", cx - 90, cy - 50, 30, color(224, 237, 239, 255));
    rl.drawText("HANSHIN EXPRESSWAY LOOP", cx - 120, cy - 18, 12, color(66, 201, 219, 255));

    // Stage text
    rl.drawText(stage, cx - 80, cy + 20, 16, color(66, 201, 219, 255));

    // Pulsing progress bar
    const bar_w = 200;
    const bar_x = cx - bar_w / 2;
    const bar_y = cy + 50;
    rl.drawRectangle(bar_x, bar_y, bar_w, 4, color(20, 28, 35, 255));
    const pulse = 0.5 + 0.5 * @sin(g_load_anim * 3.0);
    rl.drawRectangle(bar_x, bar_y, @intFromFloat(@as(f32, @floatFromInt(bar_w)) * pulse), 4, color(31, 190, 217, 255));
}

// === Map system ===
const MapEntry = struct {
    name: [:0]const u8,
    desc: [:0]const u8,
    available: bool,
    json: []const u8,
};

const osaka_json = embedded_assets.osaka_json;
const poznan_json = embedded_assets.poznan_json;

const maps = [_]MapEntry{
    .{ .name = "OSAKA", .desc = "Hanshin Expressway Loop", .available = true, .json = osaka_json },
    .{ .name = "POZNAN", .desc = "Poznan City Loop", .available = true, .json = poznan_json },
};

var g_map_loaded = false;

// === Audio ===
const SongEntry = struct {
    path: [:0]const u8,
    name: [:0]const u8,
};

const song_entries = [_]SongEntry{
    .{ .path = "assets/music/Pole Position Pulse.mp3", .name = "Pole Position Pulse" },
    .{ .path = "assets/music/Rally House.mp3", .name = "Rally House" },
    .{ .path = "assets/music/Midnight Rally.mp3", .name = "Midnight Rally" },
    .{ .path = "assets/music/Osaka Loop.mp3", .name = "Osaka Loop" },
    .{ .path = "assets/music/Osaka Loop 2.mp3", .name = "Osaka Loop 2" },
    .{ .path = "assets/music/Poznań Afterglow.mp3", .name = "Poznan Afterglow" },
    .{ .path = "assets/music/Poznań Afterglow 2.mp3", .name = "Poznan Afterglow 2" },
};

const MAX_SONGS = song_entries.len;
var g_songs: [MAX_SONGS]?rl.Music = .{null} ** MAX_SONGS;
var g_song_count: usize = 0;
var g_current_song: i32 = -1;
var g_radio_paused = false;
var g_audio_ready = false;
var g_menu_music: ?rl.Music = null;
var g_menu_music_playing = false;

fn loadRadioPlaylist() void {
    if (g_audio_ready) {
        for (g_songs[0..g_song_count]) |s| {
            if (s) |song| {
                rl.stopMusicStream(song);
                rl.unloadMusicStream(song);
            }
        }
    }
    g_songs = .{null} ** MAX_SONGS;
    g_song_count = 0;
    g_current_song = -1;
    g_radio_paused = false;

    for (song_entries) |entry| {
        if (g_song_count >= MAX_SONGS) break;
        g_songs[g_song_count] = rl.loadMusicStream(entry.path) catch null;
        if (g_songs[g_song_count] != null) g_song_count += 1;
    }
}

fn playNextSong() void {
    if (!g_audio_ready or g_song_count == 0) return;
    if (g_current_song >= 0) {
        const cur = g_songs[@intCast(g_current_song)] orelse return;
        rl.stopMusicStream(cur);
    }
    g_current_song = @intCast(@mod(g_current_song + 1, @as(i32, @intCast(g_song_count))));
    g_radio_paused = false;
    if (g_songs[@intCast(g_current_song)]) |song| {
        rl.setMusicVolume(song, 0.5);
        rl.playMusicStream(song);
    }
}

fn toggleRadioPause() void {
    if (!g_audio_ready or g_current_song < 0) return;
    const song = g_songs[@intCast(g_current_song)] orelse return;
    if (g_radio_paused) {
        rl.resumeMusicStream(song);
    } else {
        rl.pauseMusicStream(song);
    }
    g_radio_paused = !g_radio_paused;
}

fn updateMusic() void {
    if (!g_audio_ready) return;
    if (g_menu_music_playing) {
        if (g_menu_music) |m| {
            rl.updateMusicStream(m);
            if (!rl.isMusicStreamPlaying(m)) rl.playMusicStream(m);
        }
        return;
    }
    if (g_current_song < 0) return;
    const song = g_songs[@intCast(g_current_song)] orelse return;
    rl.updateMusicStream(song);
    if (g_radio_paused) return;
    if (!rl.isMusicStreamPlaying(song)) playNextSong();
}

fn stopMusic() void {
    if (!g_audio_ready) return;
    if (g_current_song >= 0) {
        if (g_songs[@intCast(g_current_song)]) |song| rl.stopMusicStream(song);
        g_current_song = -1;
    }
    g_radio_paused = false;
}

fn unloadMusic() void {
    if (!g_audio_ready) return;
    stopMusic();
    for (g_songs[0..g_song_count]) |s| {
        if (s) |song| rl.unloadMusicStream(song);
    }
    g_song_count = 0;
}

fn startMenuMusic() void {
    if (!g_audio_ready or g_menu_music == null) return;
    g_menu_music_playing = true;
    rl.setMusicVolume(g_menu_music.?, 0.35);
    rl.playMusicStream(g_menu_music.?);
}

fn stopMenuMusic() void {
    if (!g_audio_ready or g_menu_music == null) return;
    rl.stopMusicStream(g_menu_music.?);
    g_menu_music_playing = false;
}

const RadioLayout = struct {
    panel: rl.Rectangle,
    pause_button: rl.Rectangle,
    next_button: rl.Rectangle,
};

fn radioLayout() RadioLayout {
    const panel_width: f32 = 420;
    const panel_x = (@as(f32, @floatFromInt(rl.getScreenWidth())) - panel_width) * 0.5;
    return .{
        .panel = .{ .x = panel_x, .y = 12, .width = panel_width, .height = 58 },
        .pause_button = .{ .x = panel_x + panel_width - 88, .y = 22, .width = 34, .height = 32 },
        .next_button = .{ .x = panel_x + panel_width - 46, .y = 22, .width = 34, .height = 32 },
    };
}

fn updateRadioControls() void {
    if (rl.isKeyPressed(.n)) playNextSong();
    if (rl.isKeyPressed(.m)) toggleRadioPause();
    if (!rl.isMouseButtonPressed(.left)) return;

    const mouse = rl.getMousePosition();
    const layout = radioLayout();
    if (rl.checkCollisionPointRec(mouse, layout.pause_button)) {
        toggleRadioPause();
    } else if (rl.checkCollisionPointRec(mouse, layout.next_button)) {
        playNextSong();
    }
}

fn drawRadio() void {
    if (g_current_song < 0 or g_song_count == 0) return;
    const layout = radioLayout();
    const mouse = rl.getMousePosition();
    const pause_hovered = rl.checkCollisionPointRec(mouse, layout.pause_button);
    const next_hovered = rl.checkCollisionPointRec(mouse, layout.next_button);
    const px: i32 = @intFromFloat(layout.panel.x);
    const py: i32 = @intFromFloat(layout.panel.y);
    const pw: i32 = @intFromFloat(layout.panel.width);
    const pause_x: i32 = @intFromFloat(layout.pause_button.x);
    const pause_y: i32 = @intFromFloat(layout.pause_button.y);
    const next_x: i32 = @intFromFloat(layout.next_button.x);
    const next_y: i32 = @intFromFloat(layout.next_button.y);

    rl.drawRectangle(px, py, pw, @intFromFloat(layout.panel.height), color(7, 10, 10, 220));
    rl.drawRectangleLines(px, py, pw, @intFromFloat(layout.panel.height), color(107, 83, 61, 190));
    rl.drawText("NIGHT RADIO", px + 12, py + 7, 10, color(205, 126, 48, 255));
    const entry_index: usize = @intCast(g_current_song);
    rl.drawText(song_entries[entry_index].name, px + 12, py + 23, 15, color(226, 224, 207, 255));

    const pause_color = if (pause_hovered) color(150, 47, 40, 255) else color(63, 31, 30, 245);
    const next_color = if (next_hovered) color(150, 47, 40, 255) else color(63, 31, 30, 245);
    rl.drawRectangle(pause_x, pause_y, @intFromFloat(layout.pause_button.width), @intFromFloat(layout.pause_button.height), pause_color);
    rl.drawRectangle(next_x, next_y, @intFromFloat(layout.next_button.width), @intFromFloat(layout.next_button.height), next_color);
    rl.drawText(if (g_radio_paused) ">" else "II", pause_x + 10, pause_y + 8, 14, color(239, 226, 207, 255));
    rl.drawText(">>", next_x + 7, next_y + 8, 14, color(239, 226, 207, 255));

    const song = g_songs[entry_index] orelse return;
    const duration = rl.getMusicTimeLength(song);
    const progress = if (duration > 0.0) std.math.clamp(rl.getMusicTimePlayed(song) / duration, 0.0, 1.0) else 0.0;
    rl.drawRectangle(px + 12, py + 48, pw - 112, 2, color(50, 48, 43, 220));
    rl.drawRectangle(px + 12, py + 48, @intFromFloat(@as(f32, @floatFromInt(pw - 112)) * progress), 2, color(205, 126, 48, 255));
}

// === Minimap ===
var g_mm_scale: f32 = 1.0;
var g_mm_cx: f32 = 0;
var g_mm_cz: f32 = 0;

fn buildMinimap() void {
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_z: f32 = std.math.inf(f32);
    var max_z: f32 = -std.math.inf(f32);
    for (g_collision) |sp| {
        if (sp.pos.x < min_x) min_x = sp.pos.x;
        if (sp.pos.x > max_x) max_x = sp.pos.x;
        if (sp.pos.z < min_z) min_z = sp.pos.z;
        if (sp.pos.z > max_z) max_z = sp.pos.z;
    }
    g_mm_cx = (min_x + max_x) * 0.5;
    g_mm_cz = (min_z + max_z) * 0.5;
    const span = @max(max_x - min_x, max_z - min_z);
    g_mm_scale = 102.0 / span;
}

fn worldToMinimap(wx: f32, wz: f32, mx: i32, my: i32, half: f32) rl.Vector2 {
    return .{
        .x = @as(f32, @floatFromInt(mx)) + (wx - g_mm_cx) * g_mm_scale + half,
        .y = @as(f32, @floatFromInt(my)) + (wz - g_mm_cz) * g_mm_scale + half,
    };
}

fn drawMinimap(car: Car) void {
    const mm_size: i32 = 110;
    const mx = rl.getScreenWidth() - mm_size - 8;
    const my: i32 = 32;
    const half: f32 = @as(f32, @floatFromInt(mm_size)) * 0.5;

    // Background
    rl.drawRectangle(mx, my, mm_size, mm_size, color(6, 8, 14, 200));
    rl.drawRectangleLines(mx, my, mm_size, mm_size, color(40, 50, 60, 255));

    // Track outline
    const n = g_collision.len;
    var i: usize = 0;
    const segment_count = if (g_route_closed) n else n - 1;
    while (i < segment_count) : (i += 1) {
        const p0 = worldToMinimap(g_collision[i].pos.x, g_collision[i].pos.z, mx, my, half);
        const p1 = worldToMinimap(g_collision[(i + 1) % n].pos.x, g_collision[(i + 1) % n].pos.z, mx, my, half);
        rl.drawLineV(p0, p1, color(50, 110, 130, 200));
    }

    // Traffic dots
    var t: usize = 0;
    while (t < 12) : (t += 1) {
        const fi: f32 = @floatFromInt(t);
        const d = @mod(fi * (g_length / 12.0), g_length);
        const sp = sampleSpline(g_spline, d);
        const tp = worldToMinimap(sp.pos.x, sp.pos.z, mx, my, half);
        rl.drawPixelV(tp, color(180, 180, 60, 200));
    }

    // Car
    const cp = worldToMinimap(car.position.x, car.position.z, mx, my, half);
    const heading = rl.Vector2{
        .x = cp.x + @sin(car.yaw) * 5.0,
        .y = cp.y + @cos(car.yaw) * 5.0,
    };
    rl.drawCircleV(cp, 3, color(255, 70, 70, 255));
    rl.drawLineV(cp, heading, color(255, 120, 120, 255));
}

fn startMap(map_idx: usize) !void {
    drawLoading("LOADING MAP DATA");
    try loadWorld(maps[map_idx].json);

    drawLoading("BAKING ROAD");
    try bakeRoadMesh();

    drawLoading("BAKING BARRIERS");
    try bakeBarrierMesh();

    drawLoading("BAKING BUILDINGS");
    try bakeBuildingMesh();

    buildMinimap();
    stopMenuMusic();
    loadRadioPlaylist();
    playNextSong();
    g_map_loaded = true;
}

fn endMap() void {
    if (!g_map_loaded) return;
    stopMusic();
    unloadMusic();
    rl.unloadMesh(g_road_mesh);
    g_road_mat.unload();
    rl.unloadMesh(g_barrier_mesh);
    g_barrier_mat.unload();
    for (g_facade_meshes, g_facade_mats) |mesh, material| {
        rl.unloadMesh(mesh);
        material.unload();
    }
    rl.unloadMesh(g_roof_mesh);
    g_roof_mat.unload();
    g_arena.deinit();
    g_map_loaded = false;
    startMenuMusic();
}

// === Main ===
pub fn main() !void {
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true });
    rl.initWindow(screen_width, screen_height, "ASA MADE");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.gl.rlSetClipPlanes(0.05, 4000.0);

    // Persistent resources
    g_title_tex = try rl.loadTexture("assets/title.png");
    defer rl.unloadTexture(g_title_tex);
    g_flat_shader = try rl.loadShaderFromMemory(flat_vs, flat_fs);
    defer g_flat_shader.unload();
    g_view_position_loc = rl.getShaderLocation(g_flat_shader, "viewPosition");
    g_scene_target = try rl.loadRenderTexture(screen_width, screen_height);
    defer g_scene_target.unload();
    g_post_shader = try rl.loadShaderFromMemory(null, post_fs);
    defer g_post_shader.unload();
    g_ground_texture = try rl.loadTexture("assets/tex/city-ground.png");
    defer rl.unloadTexture(g_ground_texture);
    rl.genTextureMipmaps(&g_ground_texture);
    rl.setTextureWrap(g_ground_texture, .repeat);
    rl.setTextureFilter(g_ground_texture, .trilinear);
    g_ground_shader = try rl.loadShaderFromMemory(ground_vs, ground_fs);
    defer g_ground_shader.unload();
    g_ground_view_position_loc = rl.getShaderLocation(g_ground_shader, "viewPosition");
    g_ground_mesh = rl.genMeshPlane(30000.0, 30000.0, 1, 1);
    defer rl.unloadMesh(g_ground_mesh);
    g_ground_mat = try rl.loadMaterialDefault();
    defer g_ground_mat.unload();
    g_ground_mat.shader = g_ground_shader;
    g_ground_mat.maps[0].texture = g_ground_texture;
    g_tarmac_texture = try rl.loadTexture("assets/tex/tarmac.png");
    defer rl.unloadTexture(g_tarmac_texture);
    rl.genTextureMipmaps(&g_tarmac_texture);
    rl.setTextureWrap(g_tarmac_texture, .repeat);
    rl.setTextureFilter(g_tarmac_texture, .trilinear);
    g_road_shader = try rl.loadShaderFromMemory(road_vs, road_fs);
    defer g_road_shader.unload();
    g_road_view_position_loc = rl.getShaderLocation(g_road_shader, "viewPosition");
    g_barrier_texture = try rl.loadTexture("assets/tex/barrier.png");
    defer rl.unloadTexture(g_barrier_texture);
    rl.genTextureMipmaps(&g_barrier_texture);
    rl.setTextureWrap(g_barrier_texture, .repeat);
    rl.setTextureFilter(g_barrier_texture, .trilinear);
    g_barrier_shader = try rl.loadShaderFromMemory(road_vs, barrier_fs);
    defer g_barrier_shader.unload();
    g_barrier_view_position_loc = rl.getShaderLocation(g_barrier_shader, "viewPosition");
    g_facade_textures[0] = try rl.loadTexture("assets/tex/front1.png");
    g_facade_textures[1] = try rl.loadTexture("assets/tex/front4.png");
    defer for (g_facade_textures) |texture| rl.unloadTexture(texture);
    for (&g_facade_textures) |*texture| {
        rl.genTextureMipmaps(texture);
        rl.setTextureWrap(texture.*, .repeat);
        rl.setTextureFilter(texture.*, .trilinear);
    }
    g_facade_shader = try rl.loadShaderFromMemory(road_vs, facade_fs);
    defer g_facade_shader.unload();
    g_facade_view_position_loc = rl.getShaderLocation(g_facade_shader, "viewPosition");
    g_roof_texture = try rl.loadTexture("assets/tex/roof.png");
    defer rl.unloadTexture(g_roof_texture);
    rl.genTextureMipmaps(&g_roof_texture);
    rl.setTextureWrap(g_roof_texture, .repeat);
    rl.setTextureFilter(g_roof_texture, .trilinear);
    g_roof_shader = try rl.loadShaderFromMemory(road_vs, roof_fs);
    defer g_roof_shader.unload();
    g_roof_view_position_loc = rl.getShaderLocation(g_roof_shader, "viewPosition");

    drawLoading("LOADING VEHICLE");
    const player_model = try PlayerModel.init();
    defer player_model.unload();

    g_wheel = Wheel.init();
    defer g_wheel.deinit();
    g_ff = ForceFeedback.init();
    defer g_ff.deinit();

    // Audio
    rl.initAudioDevice();
    defer rl.closeAudioDevice();
    g_audio_ready = true;
    g_menu_music = rl.loadMusicStream("assets/music/Pole Position Pulse.mp3") catch null;
    defer if (g_menu_music) |m| rl.unloadMusicStream(m);
    startMenuMusic();
    defer stopMenuMusic();

    const identity = rl.Matrix.identity();

    // State: 0=title, 1=car_select, 2=map_select, 3=playing
    var state: u8 = 0;
    var menu_sel: i32 = 0;
    var garage_yaw: f32 = 0;
    var car = Car{};
    var camera_rig = CameraRig{};
    var elapsed: f32 = 0;
    var show_debug = false;
    var cam_mode: u8 = 0;
    var prev_btn3 = false;

    main_loop: while (true) {
        if (rl.windowShouldClose()) break;
        const dt = @min(rl.getFrameTime(), 1.0 / 30.0);
        elapsed += dt;
        g_wheel.poll();
        updateMusic();
        garage_yaw += dt * 0.6;

        switch (state) {
            0 => {
                // === TITLE ===
                if (rl.isKeyPressed(.escape)) break :main_loop;
                if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space) or
                    (g_wheel.available and (g_wheel.buttons[0] or g_wheel.buttons[1])))
                {
                    state = 1;
                }
                drawTitleScreen(elapsed);
            },
            1 => {
                // === CAR SELECT ===
                if (rl.isKeyPressed(.escape)) {
                    state = 0;
                } else if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space) or
                    (g_wheel.available and g_wheel.buttons[0]))
                {
                    state = 2;
                    menu_sel = 0;
                }
                drawCarSelect(player_model, garage_yaw, elapsed);
            },
            2 => {
                // === MAP SELECT ===
                if (rl.isKeyPressed(.escape)) {
                    state = 1;
                } else if (rl.isKeyPressed(.up)) {
                    menu_sel = @mod(menu_sel + @as(i32, @intCast(maps.len)) - 1, @as(i32, @intCast(maps.len)));
                } else if (rl.isKeyPressed(.down)) {
                    menu_sel = @mod(menu_sel + 1, @as(i32, @intCast(maps.len)));
                } else if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space) or
                    (g_wheel.available and g_wheel.buttons[0]))
                {
                    if (maps[@intCast(menu_sel)].available) {
                        try startMap(@intCast(menu_sel));
                        const start = g_spline[0];
                        car = Car{ .position = start.pos, .yaw = std.math.atan2(start.tangent.x, start.tangent.z) };
                        camera_rig = CameraRig{ .anchor = start.pos, .yaw = car.yaw };
                        elapsed = 0;
                        state = 3;
                    }
                }
                drawMapSelect(menu_sel, elapsed);
            },
            else => {
                // === PLAYING ===
                if (rl.isKeyPressed(.escape)) {
                    endMap();
                    state = 2;
                    continue;
                }

                if (g_wheel.available and g_wheel.buttons[3] and !prev_btn3) {
                    cam_mode = if (cam_mode == 0) 1 else 0;
                }
                prev_btn3 = g_wheel.available and g_wheel.buttons[3];

                if (rl.isKeyPressed(.tab)) show_debug = !show_debug;
                if (rl.isKeyPressed(.c)) cam_mode = if (cam_mode == 0) 1 else 0;
                updateRadioControls();
                if (rl.isKeyPressed(.r) or (g_wheel.available and g_wheel.buttons[2])) {
                    car.reset();
                    camera_rig.reset(car);
                }
                car.update(dt);
                g_ff.update(car.speed, elapsed, car.collided);

                const camera = switch (cam_mode) {
                    0 => camera_rig.update(car, dt),
                    else => blk: {
                        const fwd = Vec2{ .x = @sin(car.yaw), .z = @cos(car.yaw) };
                        break :blk rl.Camera3D{
                            .position = .{
                                .x = car.position.x + fwd.x * 1.8,
                                .y = road_y + 1.4,
                                .z = car.position.z + fwd.z * 1.8,
                            },
                            .target = .{
                                .x = car.position.x + fwd.x * 20.0,
                                .y = road_y + 1.2,
                                .z = car.position.z + fwd.z * 20.0,
                            },
                            .up = .{ .x = 0, .y = 1, .z = 0 },
                            .fovy = drivingFov(car.speed),
                            .projection = .perspective,
                        };
                    },
                };

                beginFrame();
                defer endFrame();
                drawSkybox();

                const view_position = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
                rl.setShaderValue(g_flat_shader, g_view_position_loc, &view_position, .vec3);
                rl.setShaderValue(g_ground_shader, g_ground_view_position_loc, &view_position, .vec3);
                rl.setShaderValue(g_road_shader, g_road_view_position_loc, &view_position, .vec3);
                rl.setShaderValue(g_barrier_shader, g_barrier_view_position_loc, &view_position, .vec3);
                rl.setShaderValue(g_facade_shader, g_facade_view_position_loc, &view_position, .vec3);
                rl.setShaderValue(g_roof_shader, g_roof_view_position_loc, &view_position, .vec3);

                camera.begin();
                rl.drawMesh(g_ground_mesh, g_ground_mat, identity);
                rl.drawMesh(g_roof_mesh, g_roof_mat, identity);
                for (g_facade_meshes, g_facade_mats) |mesh, material| rl.drawMesh(mesh, material, identity);
                rl.drawMesh(g_road_mesh, g_road_mat, identity);
                rl.drawMesh(g_barrier_mesh, g_barrier_mat, identity);
                drawLamps(car.position);
                drawTraffic(elapsed);
                drawPlayerCar(player_model, car.position, car.yaw);
                camera.end();

                const screen_h = rl.getScreenHeight();
                rl.drawRectangleGradientV(0, @divTrunc(screen_h, 2), rl.getScreenWidth(), @divTrunc(screen_h, 2), color(32, 22, 13, 0), color(32, 22, 13, 38));

                drawHud(car);
                drawRadio();
                if (show_debug) drawDebugWheel();
            },
        }
    }
}

fn drawTitleBackground() void {
    const img_w: f32 = @floatFromInt(g_title_tex.width);
    const img_h: f32 = @floatFromInt(g_title_tex.height);
    const scr_w: f32 = @floatFromInt(screen_width);
    const scr_h: f32 = @floatFromInt(screen_height);
    const cs = @max(scr_w / img_w, scr_h / img_h);
    const dw = img_w * cs;
    const dh = img_h * cs;
    rl.drawTexturePro(
        g_title_tex,
        .{ .x = 0, .y = 0, .width = img_w, .height = img_h },
        .{ .x = (scr_w - dw) * 0.5, .y = (scr_h - dh) * 0.5, .width = dw, .height = dh },
        .{ .x = 0, .y = 0 },
        0,
        color(255, 255, 255, 255),
    );
}

fn drawTitleScreen(elapsed: f32) void {
    beginFrame();
    defer endFrame();
    rl.clearBackground(color(4, 4, 3, 255));
    drawTitleBackground();
    rl.drawRectangle(0, 0, screen_width, screen_height, color(4, 6, 10, 130));

    const cx = screen_width / 2;
    const cy = screen_height / 2;

    // Title
    rl.drawText("ASA MADE", cx - 90, cy - 70, 30, color(224, 237, 239, 255));

    // Blinking prompt
    const blink = @sin(elapsed * 3.0) > 0;
    if (blink) {
        const text: [:0]const u8 = "PRESS BUTTON TO START";
        const tw = rl.measureText(text, 16);
        rl.drawText(text, cx - @divTrunc(tw, 2), cy + 10, 16, color(31, 190, 217, 255));
    }

    const hint: [:0]const u8 = "ESC TO QUIT";
    const hw = rl.measureText(hint, 11);
    rl.drawText(hint, cx - @divTrunc(hw, 2), screen_height - 24, 11, color(90, 100, 110, 255));
}

fn drawCarSelect(player_model: PlayerModel, garage_yaw: f32, elapsed: f32) void {
    beginFrame();
    defer endFrame();
    rl.clearBackground(color(2, 1, 2, 255));
    rl.drawRectangleGradientV(0, 0, screen_width, screen_height, color(2, 1, 2, 255), color(67, 5, 12, 255));
    rl.drawCircleGradient(
        .{ .x = @as(f32, @floatFromInt(screen_width)) * 0.5, .y = @as(f32, @floatFromInt(screen_height)) * 0.62 },
        430,
        color(148, 17, 24, 62),
        color(34, 2, 7, 0),
    );

    // 3D garage scene
    const cam = rl.Camera3D{
        .position = .{ .x = 0, .y = 2.5, .z = -8 },
        .target = .{ .x = 0, .y = 1.0, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 40,
        .projection = .perspective,
    };
    cam.begin();
    // Matte plinth and a soft fake pool from the overhead lamp.
    rl.drawCylinder(.{ .x = 0, .y = 0, .z = 0 }, 3.7, 3.9, 0.12, 64, color(19, 15, 17, 255));
    rl.beginBlendMode(.alpha);
    rl.drawCylinder(.{ .x = 0, .y = 0.125, .z = 0 }, 3.15, 3.15, 0.008, 64, color(181, 33, 31, 22));
    rl.drawCylinder(.{ .x = 0, .y = 0.134, .z = 0 }, 2.35, 2.35, 0.008, 64, color(224, 84, 55, 28));
    rl.drawCylinder(.{ .x = 0, .y = 0.143, .z = 0 }, 1.55, 1.55, 0.008, 64, color(255, 184, 132, 34));
    rl.drawCylinder(.{ .x = 0, .y = 0.15, .z = 0 }, 0.32, 3.5, 4.1, 48, color(255, 91, 70, 10));
    rl.endBlendMode();
    rl.drawCylinder(.{ .x = 0, .y = 4.25, .z = 0 }, 0.62, 0.62, 0.18, 32, color(242, 188, 153, 255));
    // Car — centered at origin, rotating
    player_model.setLightBoost(2.35);
    const angle = (garage_yaw + std.math.pi * 0.5) * 180.0 / std.math.pi;
    const cx = (player_model.bounds.min.x + player_model.bounds.max.x) * 0.5;
    const cz = (player_model.bounds.min.z + player_model.bounds.max.z) * 0.5;
    const rx = cx * @cos(garage_yaw + std.math.pi * 0.5) + cz * @sin(garage_yaw + std.math.pi * 0.5);
    const rz = -cx * @sin(garage_yaw + std.math.pi * 0.5) + cz * @cos(garage_yaw + std.math.pi * 0.5);
    player_model.model.drawEx(
        .{
            .x = -rx * player_model.scale,
            .y = 0.15 - player_model.bounds.min.y * player_model.scale,
            .z = -rz * player_model.scale,
        },
        .{ .x = 0, .y = 1, .z = 0 },
        angle,
        .{ .x = player_model.scale, .y = player_model.scale, .z = player_model.scale },
        color(255, 255, 255, 255),
    );
    cam.end();

    // 2D overlay
    const cx2 = screen_width / 2;

    // Header
    const hdr: [:0]const u8 = "SELECT YOUR VEHICLE";
    const hw = rl.measureText(hdr, 14);
    rl.drawText(hdr, cx2 - @divTrunc(hw, 2), 24, 14, color(66, 201, 219, 255));

    // Car name
    const name: [:0]const u8 = "HONDA CIVIC";
    const nw = rl.measureText(name, 22);
    rl.drawText(name, cx2 - @divTrunc(nw, 2), screen_height - 52, 22, color(224, 237, 239, 255));

    // Footer
    const blink = @sin(elapsed * 3.0) > 0;
    if (blink) {
        const prompt: [:0]const u8 = "ENTER CONFIRM   ESC BACK";
        const pw = rl.measureText(prompt, 11);
        rl.drawText(prompt, cx2 - @divTrunc(pw, 2), screen_height - 22, 11, color(90, 100, 110, 255));
    }
}

fn drawMapSelect(sel: i32, elapsed: f32) void {
    beginFrame();
    defer endFrame();
    rl.clearBackground(color(4, 4, 3, 255));
    drawTitleBackground();
    rl.drawRectangle(0, 0, screen_width, screen_height, color(4, 6, 10, 150));

    const cx = screen_width / 2;

    // Header
    const hdr: [:0]const u8 = "SELECT TRACK";
    const hw = rl.measureText(hdr, 16);
    rl.drawText(hdr, cx - @divTrunc(hw, 2), 28, 16, color(66, 201, 219, 255));

    // Items
    const start_y = screen_height / 2 - 30;
    var i: i32 = 0;
    while (i < maps.len) : (i += 1) {
        const y = start_y + i * 50;
        const is_sel = i == sel;
        const map = maps[@intCast(i)];

        if (is_sel) {
            const pulse: f32 = 0.6 + 0.4 * @sin(elapsed * 4.0);
            rl.drawRectangle(cx - 140, y - 4, 280, 38, color(31, 190, 217, @intFromFloat(35.0 * pulse)));
            rl.drawRectangleLines(cx - 140, y - 4, 280, 38, color(31, 190, 217, 200));
        }

        const tc = if (!map.available) color(80, 80, 80, 255) else if (is_sel) color(31, 190, 217, 255) else color(200, 210, 215, 255);
        const tw = rl.measureText(map.name, 22);
        rl.drawText(map.name, cx - @divTrunc(tw, 2), y, 22, tc);

        const desc: [:0]const u8 = if (map.available) map.desc else "Coming Soon";
        const dw2 = rl.measureText(desc, 11);
        rl.drawText(desc, cx - @divTrunc(dw2, 2), y + 26, 11, color(120, 130, 140, 255));
    }

    const hint: [:0]const u8 = "UP/DOWN NAVIGATE   ENTER SELECT   ESC BACK";
    const hw2 = rl.measureText(hint, 11);
    rl.drawText(hint, cx - @divTrunc(hw2, 2), screen_height - 22, 11, color(90, 100, 110, 255));
}
