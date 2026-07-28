const std = @import("std");
const rl = @import("raylib");

// === Linux joystick direct access ===
const jsy = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const JS_EVENT_AXIS: u8 = 0x02;
const JS_EVENT_BUTTON: u8 = 0x01;
const JS_EVENT_INIT: u8 = 0x80;

const JsEvent = extern struct {
    time: u32,
    value: i16,
    @"type": u8,
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
        var ev: JsEvent = undefined;
        const sz: usize = @sizeOf(JsEvent);
        while (true) {
            const n = jsy.read(self.fd, &ev, sz);
            if (n != sz) break;
            if (ev.@"type" & JS_EVENT_AXIS != 0) {
                if (ev.number < 8) self.axes[ev.number] = @as(f32, @floatFromInt(ev.value)) / 32767.0;
            } else if (ev.@"type" & JS_EVENT_BUTTON != 0) {
                if (ev.number < 32) self.buttons[ev.number] = ev.value != 0;
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

// === Config ===
const screen_width = 720;
const screen_height = 360;
const road_y: f32 = 6.0;
const road_half_width: f32 = 6.0;
const spline_spacing: f32 = 3.0;
const collision_spacing: f32 = 12.0;
const building_cull_dist: f32 = 65.0;
const lamp_interval: f32 = 50.0;
const tau: f32 = std.math.pi * 2.0;

// === Shaders ===
const flat_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vertexColor;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const flat_fs =
    \\#version 330
    \\in vec4 fragColor;
    \\uniform vec4 colDiffuse;
    \\out vec4 finalColor;
    \\void main() {
    \\    finalColor = fragColor * colDiffuse;
    \\}
;

const car_vs =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec3 vertexNormal;
    \\in vec2 vertexTexCoord;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\out vec2 fragTexCoord;
    \\out vec4 fragColor;
    \\void main() {
    \\    float top = max(vertexNormal.y, 0.0);
    \\    float side = max(dot(normalize(vertexNormal), normalize(vec3(-0.45, 0.35, 0.82))), 0.0);
    \\    vec3 sodium = vec3(1.0, 0.68, 0.38);
    \\    vec3 lighting = vec3(0.22, 0.20, 0.18) + sodium * (top * 0.42 + side * 0.28);
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
var g_arena: std.heap.ArenaAllocator = undefined;

// === Mesh globals ===
var g_flat_shader: rl.Shader = undefined;
var g_road_mesh: rl.Mesh = undefined;
var g_road_mat: rl.Material = undefined;
var g_bldg_mesh: rl.Mesh = undefined;
var g_bldg_mat: rl.Material = undefined;
var g_pool_mesh: rl.Mesh = undefined;
var g_pool_mat: rl.Material = undefined;

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
fn loadWorld() !void {
    g_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const a = g_arena.allocator();

    const json_bytes = @embedFile("loop_scene.json");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json_bytes, .{});
    const root = parsed.object;

    // --- Route points ---
    const route_arr = root.get("route").?.object.get("points").?.array;
    var route_pts = try a.alloc(Vec2, route_arr.items.len);
    for (route_arr.items, 0..) |pt, i| {
        const pos = pt.object.get("position").?.array;
        route_pts[i] = .{ .x = jf(pos.items[0]), .z = jf(pos.items[2]) };
    }

    g_spline = try buildSpline(a, route_pts, spline_spacing);
    g_length = g_spline[g_spline.len - 1].dist;
    g_collision = try buildSpline(a, route_pts, collision_spacing);

    // --- Buildings (culled by distance to collision spline) ---
    const bld_arr = root.get("buildings").?.array;
    var bld_list: std.ArrayList(BuildingData) = .empty;
    for (bld_arr.items) |bld| {
        const obj = bld.object;
        const height = if (obj.get("height_m")) |h| jf(h) else if (obj.get("fallback_height_m")) |h| jf(h) else 12.0;

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

fn buildSpline(a: std.mem.Allocator, route: []const Vec2, spacing: f32) ![]SplinePt {
    var list: std.ArrayList(SplinePt) = .empty;
    const n = route.len;

    var i: usize = 0;
    while (i < n) : (i += 1) {
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

    const sp = try list.toOwnedSlice(a);
    const m = sp.len;
    var cumdist: f32 = 0;
    for (0..m) |idx| {
        const prev = sp[(idx + m - 1) % m];
        const next = sp[(idx + 1) % m];
        const tx = next.pos.x - prev.pos.x;
        const tz = next.pos.z - prev.pos.z;
        const inv = 1.0 / @sqrt(tx * tx + tz * tz);
        sp[idx].tangent = .{ .x = tx * inv, .z = tz * inv };
        sp[idx].normal = .{ .x = sp[idx].tangent.z, .z = -sp[idx].tangent.x };
        sp[idx].dist = cumdist;
        const fwd = sp[(idx + 1) % m];
        cumdist += vecLength(.{ .x = fwd.pos.x - sp[idx].pos.x, .z = fwd.pos.z - sp[idx].pos.z });
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
    const d = @mod(distance, g_length);
    var lo: usize = 0;
    var hi: usize = spline.len - 1;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (spline[mid].dist < d) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return spline[0];
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

const NearestTrack = struct { center: Vec2, normal: Vec2 };

fn nearestTrack(position: Vec2) NearestTrack {
    var result = NearestTrack{ .center = g_collision[0].pos, .normal = g_collision[0].normal };
    var best_d2: f32 = std.math.inf(f32);
    for (g_collision) |sp| {
        const dx = position.x - sp.pos.x;
        const dz = position.z - sp.pos.z;
        const d2 = dx * dx + dz * dz;
        if (d2 < best_d2) {
            best_d2 = d2;
            result = .{ .center = sp.pos, .normal = sp.normal };
        }
    }
    return result;
}

// === Mesh builder ===
const MeshBuilder = struct {
    alloc: std.mem.Allocator,
    pos: std.ArrayList(f32),
    col: std.ArrayList(u8),

    fn init(c: std.mem.Allocator) MeshBuilder {
        return .{ .alloc = c, .pos = .empty, .col = .empty };
    }

    fn deinit(self: *MeshBuilder) void {
        self.pos.deinit(self.alloc);
        self.col.deinit(self.alloc);
    }

    fn vert(self: *MeshBuilder, x: f32, y: f32, z: f32, c: rl.Color) !void {
        try self.pos.appendSlice(self.alloc, &.{ x, y, z });
        try self.col.appendSlice(self.alloc, &.{ c.r, c.g, c.b, c.a });
    }

    fn tri(self: *MeshBuilder, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32, cx: f32, cy: f32, cz: f32, ca: rl.Color, cb: rl.Color, cc: rl.Color) !void {
        try self.vert(ax, ay, az, ca);
        try self.vert(bx, by, bz, cb);
        try self.vert(cx, cy, cz, cc);
    }

    fn build(self: *MeshBuilder, shader: rl.Shader) !struct { mesh: rl.Mesh, mat: rl.Material } {
        const pos_owned = try self.pos.toOwnedSlice(self.alloc);
        const col_owned = try self.col.toOwnedSlice(self.alloc);

        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertexCount = @intCast(pos_owned.len / 3);
        mesh.triangleCount = @intCast(pos_owned.len / 9);
        mesh.vertices = pos_owned.ptr;
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

    var i: usize = 0;
    while (i < n) : (i += 1) {
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

        // Asphalt with warm lamp-position variation
        const spacing_idx: usize = 16;
        const phase = i % spacing_idx;
        const dist_from_lamp = @min(phase, spacing_idx - phase);
        const lit = 1.0 - std.math.clamp(@as(f32, @floatFromInt(dist_from_lamp)) / 6.0, 0.0, 1.0);
        const asphalt = mixColor(color(24, 22, 20, 255), color(62, 48, 34, 255), lit * 0.7);

        try mb.tri(in0.x, road_y, in0.z, in1.x, road_y, in1.z, out1.x, road_y, out1.z, asphalt, asphalt, asphalt);
        try mb.tri(in0.x, road_y, in0.z, out1.x, road_y, out1.z, out0.x, road_y, out0.z, asphalt, asphalt, asphalt);

        // Shoulder lines
        const white = color(222, 218, 195, 255);
        const amber = color(218, 142, 47, 255);
        try stripQuad(&mb, p0, p1, n0, n1, -road_half_width + 0.35, 0.18, white);
        try stripQuad(&mb, p0, p1, n0, n1, road_half_width - 0.35, 0.18, amber);

        // Dashed lane lines
        if (i % 2 == 0) {
            try stripQuad(&mb, p0, p1, n0, n1, -2.2, 0.14, white);
            try stripQuad(&mb, p0, p1, n0, n1, 2.2, 0.14, white);
        }
    }

    const built = try mb.build(g_flat_shader);
    g_road_mesh = built.mesh;
    g_road_mat = built.mat;
}

fn stripQuad(mb: *MeshBuilder, p0: Vec2, p1: Vec2, n0: Vec2, n1: Vec2, offset: f32, w: f32, c: rl.Color) !void {
    const a = add(p0, scale(n0, offset - w * 0.5));
    const b = add(p1, scale(n1, offset - w * 0.5));
    const cc = add(p1, scale(n1, offset + w * 0.5));
    const d = add(p0, scale(n0, offset + w * 0.5));
    const y = road_y + 0.04;
    try mb.tri(a.x, y, a.z, b.x, y, b.z, cc.x, y, cc.z, c, c, c);
    try mb.tri(a.x, y, a.z, cc.x, y, cc.z, d.x, y, d.z, c, c, c);
}

// === Building mesh baking ===
fn bakeBuildingMesh() !void {
    var mb = MeshBuilder.init(std.heap.c_allocator);
    defer mb.deinit();

    var b: usize = 0;
    while (b < g_buildings.len) : (b += 1) {
        const bld = g_buildings[b];
        const pts = bld.pts;
        const h = bld.height;
        if (pts.len < 3) continue;

        // Deterministic hash for building color variation
        const hsh: u32 = @intCast(b);
        const facade = if (hsh % 3 == 0) color(30, 28, 24, 255) else color(38, 33, 27, 255);
        const wall_dark = mixColor(facade, color(8, 6, 4, 0), 0.4);
        const wall_top = mixColor(facade, color(255, 185, 104, 0), 0.15);

        // Walls
        var j: usize = 0;
        while (j < pts.len) : (j += 1) {
            const pa = pts[j];
            const pb = pts[(j + 1) % pts.len];
            try mb.tri(pa.x, 0, pa.z, pb.x, 0, pb.z, pb.x, h, pb.z, wall_dark, wall_dark, wall_top);
            try mb.tri(pa.x, 0, pa.z, pb.x, h, pb.z, pa.x, h, pa.z, wall_dark, wall_top, wall_top);
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
        const roof = mixColor(facade, color(6, 5, 4, 0), 0.6);
        j = 0;
        while (j < pts.len) : (j += 1) {
            const pa = pts[j];
            const pb = pts[(j + 1) % pts.len];
            try mb.tri(cx, h, cz, pa.x, h, pa.z, pb.x, h, pb.z, roof, roof, roof);
        }
    }

    const built = try mb.build(g_flat_shader);
    g_bldg_mesh = built.mesh;
    g_bldg_mat = built.mat;
}

// === Light pool mesh baking ===
fn bakeLightPoolMesh() !void {
    var mb = MeshBuilder.init(std.heap.c_allocator);
    defer mb.deinit();

    for (g_lamps) |lamp| {
        const center_c = if (lamp.cool) color(71, 225, 218, 55) else color(255, 153, 62, 65);
        const edge_c = color(35, 28, 22, 0);
        const slices: usize = 10;
        var s: usize = 0;
        while (s < slices) : (s += 1) {
            const a0 = tau * @as(f32, @floatFromInt(s)) / slices;
            const a1 = tau * @as(f32, @floatFromInt(s + 1)) / slices;
            const p0 = Vec2{ .x = lamp.pos.x + @cos(a0) * 4.5, .z = lamp.pos.z + @sin(a0) * 7.0 };
            const p1 = Vec2{ .x = lamp.pos.x + @cos(a1) * 4.5, .z = lamp.pos.z + @sin(a1) * 7.0 };
            const y = road_y + 0.02;
            try mb.tri(lamp.pos.x, y, lamp.pos.z, p1.x, y, p1.z, p0.x, y, p0.z, center_c, edge_c, edge_c);
        }
    }

    const built = try mb.build(g_flat_shader);
    g_pool_mesh = built.mesh;
    g_pool_mat = built.mat;
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
            if (@abs(raw_steer) > 0.02) steer = -raw_steer;

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
            const power_falloff = 1.0 - 0.42 * std.math.clamp(@abs(long_speed) / 84.0, 0.0, 1.0);
            self.velocity = add(self.velocity, scale(forward, 44.0 * power_falloff * dt));
        }
        if (brake > 0.0) {
            const force: f32 = if (long_speed > 1.0) -62.0 else -24.0;
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

        const drag: f32 = if (handbrake) 0.52 else 0.105;
        self.velocity = scale(self.velocity, std.math.clamp(1.0 - drag * dt, 0.0, 1.0));
        const vl = vecLength(self.velocity);
        if (vl > 84.0) self.velocity = scale(self.velocity, 84.0 / vl);

        self.position = add(self.position, scale(self.velocity, dt));
        self.speed = dot(self.velocity, forward);
        const drift_t = std.math.clamp(@abs(dot(self.velocity, right)) / 15.0, 0.0, 1.0) * speed_factor;
        self.drift_amount += (drift_t - self.drift_amount) * std.math.clamp(dt * 7.0, 0.0, 1.0);
        self.steer_visual += (steer - self.steer_visual) * std.math.clamp(dt * 9.0, 0.0, 1.0);

        const nearest = nearestTrack(self.position);
        const lateral = dot(.{ .x = self.position.x - nearest.center.x, .z = self.position.z - nearest.center.z }, nearest.normal);
        const limit = road_half_width - 1.1;
        if (@abs(lateral) > limit) {
            const excess = lateral - std.math.clamp(lateral, -limit, limit);
            self.position.x -= nearest.normal.x * excess;
            self.position.z -= nearest.normal.z * excess;
            const ns = dot(self.velocity, nearest.normal);
            if (ns * lateral > 0.0) self.velocity = add(self.velocity, scale(nearest.normal, -ns * 1.25));
            self.velocity = scale(self.velocity, 0.76);
            self.speed = dot(self.velocity, forward);
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
            .fovy = 67.0 + std.math.clamp(@abs(car.speed) * 0.11, 0.0, 7.0),
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

    fn init() !PlayerModel {
        var model = try rl.loadModel("assets/civic-raylib.glb");
        errdefer model.unload();
        const shader = try rl.loadShaderFromMemory(car_vs, car_fs);
        errdefer shader.unload();
        var i: usize = 0;
        while (i < @as(usize, @intCast(model.materialCount))) : (i += 1) model.materials[i].shader = shader;

        const bounds = rl.getModelBoundingBox(model);
        const model_length = @max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z);
        return .{ .model = model, .shader = shader, .bounds = bounds, .scale = 4.35 / model_length };
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
};

// === Drawing ===
fn drawHeadlightWash(position: Vec2, yaw: f32) void {
    const nl = localPoint(position, yaw, -0.72, 2.0);
    const nr = localPoint(position, yaw, 0.72, 2.0);
    const fl = localPoint(position, yaw, -3.1, 12.5);
    const fr = localPoint(position, yaw, 3.1, 12.5);
    const near = color(255, 224, 170, 48);
    const far = color(255, 191, 102, 0);
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

fn boxOriented(center: Vec2, y: f32, w: f32, h: f32, l: f32, yaw: f32, tint: rl.Color) void {
    const bl = localPoint(center, yaw, -w * 0.5, -l * 0.5);
    const br = localPoint(center, yaw, w * 0.5, -l * 0.5);
    const fl = localPoint(center, yaw, -w * 0.5, l * 0.5);
    const fr = localPoint(center, yaw, w * 0.5, l * 0.5);
    const y0 = y;
    const y1 = y + h;
    const dark = mixColor(tint, color(6, 5, 4, 255), 0.55);
    const side = mixColor(tint, color(24, 16, 10, 255), 0.3);
    const top = mixColor(tint, color(255, 185, 104, 255), 0.24);
    const tri = struct {
        fn t(a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, col: rl.Color) void {
            rl.gl.rlBegin(rl.gl.rl_triangles);
            rl.gl.rlColor4ub(col.r, col.g, col.b, col.a);
            rl.gl.rlVertex3f(a.x, a.y, a.z);
            rl.gl.rlColor4ub(col.r, col.g, col.b, col.a);
            rl.gl.rlVertex3f(b.x, b.y, b.z);
            rl.gl.rlColor4ub(col.r, col.g, col.b, col.a);
            rl.gl.rlVertex3f(c.x, c.y, c.z);
            rl.gl.rlEnd();
        }
    };
    _ = tri;
    _ = dark;
    _ = side;
    _ = top;
    _ = bl;
    _ = br;
    _ = fl;
    _ = fr;
    _ = y0;
    _ = y1;
    // Simple single-color box for traffic
    rl.drawCubeV(.{ .x = center.x, .y = y + h * 0.5, .z = center.z }, .{ .x = w, .y = h, .z = l }, tint);
}

fn drawCar(position: Vec2, yaw: f32, paint: rl.Color) void {
    drawHeadlightWash(position, yaw);
    rl.drawCubeV(.{ .x = position.x, .y = road_y + 0.5, .z = position.z }, .{ .x = 2.0, .y = 0.7, .z = 4.2 }, paint);
    rl.drawCubeWiresV(.{ .x = position.x, .y = road_y + 0.5, .z = position.z }, .{ .x = 2.0, .y = 0.7, .z = 4.2 }, color(15, 12, 8, 255));
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
        rl.drawCylinderEx(base, top, 0.09, 0.06, 6, color(73, 67, 59, 255));
        rl.drawCylinderEx(top, lamp3, 0.06, 0.045, 6, color(91, 79, 65, 255));
        const glow = if (lamp.cool) color(65, 229, 221, 100) else color(255, 145, 53, 105);
        const core = if (lamp.cool) color(204, 255, 239, 255) else color(255, 231, 177, 255);
        rl.drawSphere(lamp3, 0.4, glow);
        rl.drawSphere(lamp3, 0.13, core);
    }
}

fn drawTraffic(elapsed: f32) void {
    const paints = [_]rl.Color{
        color(224, 218, 199, 255), color(31, 50, 117, 255),  color(151, 38, 30, 255),
        color(38, 36, 32, 255),    color(186, 124, 42, 255), color(43, 91, 75, 255),
    };
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const d = @mod(fi * (g_length / 12.0) + elapsed * (8.0 + fi * 0.5), g_length);
        const sp = sampleSpline(g_spline, d);
        const lane: f32 = if (i % 2 == 0) -2.5 else 2.5;
        const pos = add(sp.pos, scale(sp.normal, lane));
        drawCar(pos, std.math.atan2(sp.tangent.x, sp.tangent.z), paints[i % paints.len]);
    }
}

fn drawHud(car: Car) void {
    const width = rl.getScreenWidth();
    const height = rl.getScreenHeight();
    const sx = width - 82;
    const sy = height - 94;

    rl.drawRectangleGradientV(0, 0, width, 88, color(4, 8, 15, 185), color(4, 8, 15, 0));
    rl.drawText("ASA MADE", 28, 22, 24, color(224, 237, 239, 255));
    rl.drawText("HANSHIN LOOP // OSAKA", 29, 50, 12, color(66, 201, 219, 255));
    rl.drawFPS(width - 92, 18);

    rl.drawCircleGradient(.{ .x = @floatFromInt(sx), .y = @floatFromInt(sy) }, 76, color(10, 14, 23, 210), color(10, 14, 23, 35));
    rl.drawCircleLines(sx, sy, 59, color(89, 109, 121, 220));
    const kmh: i32 = @intFromFloat(@abs(car.speed) * 3.6);
    var speed_buf: [16]u8 = undefined;
    const speed_text = std.fmt.bufPrintZ(&speed_buf, "{d:0>3}", .{kmh}) catch "---";
    rl.drawText(speed_text, sx - 39, sy - 24, 38, color(239, 245, 241, 255));
    rl.drawText("KM/H", sx - 18, sy + 18, 13, color(74, 210, 224, 255));
    rl.drawText(if (car.speed < -0.5) "R" else "5", sx + 20, sy + 25, 22, color(245, 67, 104, 255));
    if (car.drift_amount > 0.18) {
        rl.drawText("DRIFT", sx - 25, sy - 58, 16, color(245, 67, 104, 255));
    }

    rl.drawRectangle(27, height - 57, 205, 5, color(29, 40, 51, 230));
    const bw: i32 = @intFromFloat(205.0 * std.math.clamp(@abs(car.speed) / 84.0, 0.0, 1.0));
    rl.drawRectangle(27, height - 57, bw, 5, color(31, 190, 217, 255));
    rl.drawText("SPEED BREAKER", 27, height - 45, 12, color(155, 174, 181, 255));
    rl.drawText("WASD/WHEEL DRIVE  SPACE HANDBRAKE  R RESET", 27, height - 21, 11, color(122, 139, 148, 255));

    if (g_wheel.available) {
        rl.drawText("DFP CONNECTED", width - 120, height - 21, 11, color(31, 190, 217, 255));
    }
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
    rl.beginDrawing();
    defer rl.endDrawing();
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

// === Main ===
pub fn main() !void {
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true });
    rl.initWindow(screen_width, screen_height, "ASA MADE");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.gl.rlSetClipPlanes(0.05, 4000.0);

    g_title_tex = try rl.loadTexture("assets/title.png");
    defer rl.unloadTexture(g_title_tex);

    drawLoading("LOADING MAP DATA");
    try loadWorld();

    g_flat_shader = try rl.loadShaderFromMemory(flat_vs, flat_fs);

    drawLoading("BAKING ROAD");
    try bakeRoadMesh();

    drawLoading("BAKING BUILDINGS");
    try bakeBuildingMesh();

    drawLoading("BAKING LIGHTS");
    try bakeLightPoolMesh();

    drawLoading("LOADING VEHICLE");
    const player_model = try PlayerModel.init();
    defer player_model.unload();

    const start = g_spline[0];
    var car = Car{ .position = start.pos, .yaw = std.math.atan2(start.tangent.x, start.tangent.z) };
    var camera_rig = CameraRig{ .anchor = start.pos, .yaw = car.yaw };
    var elapsed: f32 = 0;
    var show_debug = false;

    g_wheel = Wheel.init();
    defer g_wheel.deinit();

    const identity = rl.Matrix.identity();

    while (!rl.windowShouldClose()) {
        const dt = @min(rl.getFrameTime(), 1.0 / 30.0);
        elapsed += dt;
        g_wheel.poll();

        if (rl.isKeyPressed(.tab)) show_debug = !show_debug;
        if (rl.isKeyPressed(.r) or (g_wheel.available and g_wheel.buttons[2])) {
            car.reset();
            camera_rig.reset(car);
        }
        car.update(dt);
        const camera = camera_rig.update(car, dt);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(color(4, 4, 3, 255));
        rl.drawRectangleGradientV(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), color(3, 5, 5, 255), color(20, 14, 8, 255));

        camera.begin();
        rl.drawPlane(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 3000, .y = 3000 }, color(8, 7, 5, 255));
        rl.drawMesh(g_bldg_mesh, g_bldg_mat, identity);
        rl.drawMesh(g_road_mesh, g_road_mat, identity);
        rl.beginBlendMode(.alpha);
        rl.drawMesh(g_pool_mesh, g_pool_mat, identity);
        rl.endBlendMode();
        drawLamps(car.position);
        drawTraffic(elapsed);
        drawPlayerCar(player_model, car.position, car.yaw);
        camera.end();

        drawHud(car);
        if (show_debug) drawDebugWheel();
    }
}
