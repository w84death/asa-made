const std = @import("std");
const rl = @import("raylib");

const screen_width = 720;
const screen_height = 360;
const road_y: f32 = 2.2;
const track_half_x: f32 = 118.0;
const track_half_z: f32 = 52.0;
const corner_radius: f32 = 24.0;
const road_half_width: f32 = 9.0;
const segment_count = 144;
const tau: f32 = std.math.pi * 2.0;

const car_vertex_shader =
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

const car_fragment_shader =
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

const Vec2 = struct { x: f32, z: f32 };

const Car = struct {
    position: Vec2 = .{ .x = track_half_x, .z = 0.0 },
    velocity: Vec2 = .{ .x = 0.0, .z = 0.0 },
    yaw: f32 = 0.0,
    yaw_rate: f32 = 0.0,
    speed: f32 = 0.0,
    steer_visual: f32 = 0.0,
    drift_amount: f32 = 0.0,

    fn reset(self: *Car) void {
        self.* = .{};
    }

    fn update(self: *Car, dt: f32) void {
        const throttle: f32 = if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) 1.0 else 0.0;
        const brake: f32 = if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) 1.0 else 0.0;
        var steer: f32 = 0.0;
        if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) steer += 1.0;
        if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) steer -= 1.0;
        const handbrake = rl.isKeyDown(.space);

        var forward = Vec2{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        var right = Vec2{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        var longitudinal_speed = dot(self.velocity, forward);
        var lateral_speed = dot(self.velocity, right);

        if (throttle > 0.0) {
            const power_falloff = 1.0 - 0.42 * std.math.clamp(@abs(longitudinal_speed) / 84.0, 0.0, 1.0);
            self.velocity = add(self.velocity, scale(forward, 44.0 * power_falloff * dt));
        }
        if (brake > 0.0) {
            const brake_force: f32 = if (longitudinal_speed > 1.0) -62.0 else -24.0;
            self.velocity = add(self.velocity, scale(forward, brake_force * dt));
        }

        const speed_factor = std.math.clamp(@abs(longitudinal_speed) / 14.0, 0.0, 1.0);
        const reverse_sign: f32 = if (longitudinal_speed < -0.5) -1.0 else 1.0;
        const steering_rate: f32 = if (handbrake) 1.72 else 1.18;
        const target_yaw_rate = steer * steering_rate * speed_factor * reverse_sign;
        const yaw_response: f32 = if (handbrake) 7.5 else 5.0;
        self.yaw_rate += (target_yaw_rate - self.yaw_rate) * std.math.clamp(yaw_response * dt, 0.0, 1.0);
        if (handbrake and @abs(longitudinal_speed) > 18.0) self.yaw_rate += steer * 1.25 * dt * reverse_sign;
        if (@abs(steer) < 0.05) self.yaw_rate *= std.math.clamp(1.0 - 3.2 * dt, 0.0, 1.0);
        self.yaw += self.yaw_rate * dt;

        // Recompute the tire axes after yaw changes. Reduced rear grip preserves sideways momentum during a drift.
        forward = .{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        right = .{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        longitudinal_speed = dot(self.velocity, forward);
        lateral_speed = dot(self.velocity, right);
        var lateral_grip: f32 = if (handbrake) 0.72 else 6.8;
        if (!handbrake and throttle > 0.0 and @abs(lateral_speed) > 4.5 and @abs(longitudinal_speed) > 24.0) lateral_grip = 2.7;
        self.velocity = add(self.velocity, scale(right, -lateral_speed * std.math.clamp(lateral_grip * dt, 0.0, 1.0)));

        const rolling_drag: f32 = if (handbrake) 0.52 else 0.105;
        self.velocity = scale(self.velocity, std.math.clamp(1.0 - rolling_drag * dt, 0.0, 1.0));
        const velocity_length = vecLength(self.velocity);
        if (velocity_length > 84.0) self.velocity = scale(self.velocity, 84.0 / velocity_length);

        self.position = add(self.position, scale(self.velocity, dt));
        self.speed = dot(self.velocity, forward);
        const drift_target = std.math.clamp(@abs(dot(self.velocity, right)) / 15.0, 0.0, 1.0) * speed_factor;
        self.drift_amount += (drift_target - self.drift_amount) * std.math.clamp(dt * 7.0, 0.0, 1.0);
        self.steer_visual += (steer - self.steer_visual) * std.math.clamp(dt * 9.0, 0.0, 1.0);

        // Keep the prototype readable: barriers push the car back toward the road instead of stopping it dead.
        const nearest = nearestTrack(self.position);
        const lateral = dot(.{ .x = self.position.x - nearest.center.x, .z = self.position.z - nearest.center.z }, nearest.normal);
        const limit = road_half_width - 1.1;
        if (@abs(lateral) > limit) {
            const excess = lateral - std.math.clamp(lateral, -limit, limit);
            self.position.x -= nearest.normal.x * excess;
            self.position.z -= nearest.normal.z * excess;
            const normal_speed = dot(self.velocity, nearest.normal);
            if (normal_speed * lateral > 0.0) self.velocity = add(self.velocity, scale(nearest.normal, -normal_speed * 1.25));
            self.velocity = scale(self.velocity, 0.76);
            self.speed = dot(self.velocity, forward);
        }
    }
};

const CameraRig = struct {
    anchor: Vec2 = .{ .x = track_half_x, .z = 0.0 },
    yaw: f32 = 0.0,

    fn reset(self: *CameraRig, car: Car) void {
        self.anchor = car.position;
        self.yaw = car.yaw;
    }

    fn update(self: *CameraRig, car: Car, dt: f32) rl.Camera3D {
        const offset = Vec2{ .x = car.position.x - self.anchor.x, .z = car.position.z - self.anchor.z };
        const offset_length = vecLength(offset);
        const dead_zone: f32 = 0.72;
        if (offset_length > dead_zone) {
            const desired_anchor = add(car.position, scale(offset, -dead_zone / offset_length));
            self.anchor = add(self.anchor, scale(.{ .x = desired_anchor.x - self.anchor.x, .z = desired_anchor.z - self.anchor.z }, std.math.clamp(dt * 11.0, 0.0, 1.0)));
        }

        const yaw_delta = @mod(car.yaw - self.yaw + std.math.pi, tau) - std.math.pi;
        self.yaw += yaw_delta * std.math.clamp(dt * 8.5, 0.0, 1.0);
        const camera_forward = Vec2{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        const camera_distance = 10.5 - std.math.clamp(@abs(car.speed) * 0.018, 0.0, 1.5);
        return .{
            .position = .{
                .x = self.anchor.x - camera_forward.x * camera_distance,
                .y = road_y + 5.2,
                .z = self.anchor.z - camera_forward.z * camera_distance,
            },
            .target = .{
                .x = self.anchor.x + camera_forward.x * 5.5,
                .y = road_y + 1.15,
                .z = self.anchor.z + camera_forward.z * 5.5,
            },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = 67.0 + std.math.clamp(@abs(car.speed) * 0.11, 0.0, 7.0),
            .projection = .perspective,
        };
    }
};

const PlayerModel = struct {
    model: rl.Model,
    shader: rl.Shader,
    bounds: rl.BoundingBox,
    scale: f32,

    fn init() !PlayerModel {
        var model = try rl.loadModel("assets/civic-raylib.glb");
        errdefer model.unload();
        const shader = try rl.loadShaderFromMemory(car_vertex_shader, car_fragment_shader);
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
        const center_x = (self.bounds.min.x + self.bounds.max.x) * 0.5;
        const center_z = (self.bounds.min.z + self.bounds.max.z) * 0.5;
        const rotated_center_x = center_x * @cos(angle) + center_z * @sin(angle);
        const rotated_center_z = -center_x * @sin(angle) + center_z * @cos(angle);
        self.model.drawEx(
            .{
                .x = position.x - rotated_center_x * self.scale,
                .y = road_y + 0.14 - self.bounds.min.y * self.scale,
                .z = position.z - rotated_center_z * self.scale,
            },
            .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            angle * 180.0 / std.math.pi,
            .{ .x = self.scale, .y = self.scale, .z = self.scale },
            color(255, 255, 255, 255),
        );
    }
};

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn mixColor(a: rl.Color, b: rl.Color, amount: f32) rl.Color {
    const t = std.math.clamp(amount, 0.0, 1.0);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * t),
        .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * t),
    };
}

fn trackPoint(t: f32) Vec2 {
    const long_straight = 2.0 * (track_half_x - corner_radius);
    const short_straight = track_half_z - corner_radius;
    const arc = std.math.pi * corner_radius * 0.5;
    const perimeter = long_straight * 2.0 + short_straight * 2.0 + arc * 4.0;
    var distance = @mod(t, tau) / tau * perimeter;

    if (distance < short_straight) return .{ .x = track_half_x, .z = distance };
    distance -= short_straight;
    if (distance < arc) {
        const angle = distance / corner_radius;
        return .{ .x = track_half_x - corner_radius + corner_radius * @cos(angle), .z = track_half_z - corner_radius + corner_radius * @sin(angle) };
    }
    distance -= arc;
    if (distance < long_straight) return .{ .x = track_half_x - corner_radius - distance, .z = track_half_z };
    distance -= long_straight;
    if (distance < arc) {
        const angle = std.math.pi * 0.5 + distance / corner_radius;
        return .{ .x = -track_half_x + corner_radius + corner_radius * @cos(angle), .z = track_half_z - corner_radius + corner_radius * @sin(angle) };
    }
    distance -= arc;
    if (distance < short_straight * 2.0) return .{ .x = -track_half_x, .z = track_half_z - corner_radius - distance };
    distance -= short_straight * 2.0;
    if (distance < arc) {
        const angle = std.math.pi + distance / corner_radius;
        return .{ .x = -track_half_x + corner_radius + corner_radius * @cos(angle), .z = -track_half_z + corner_radius + corner_radius * @sin(angle) };
    }
    distance -= arc;
    if (distance < long_straight) return .{ .x = -track_half_x + corner_radius + distance, .z = -track_half_z };
    distance -= long_straight;
    if (distance < arc) {
        const angle = std.math.pi * 1.5 + distance / corner_radius;
        return .{ .x = track_half_x - corner_radius + corner_radius * @cos(angle), .z = -track_half_z + corner_radius + corner_radius * @sin(angle) };
    }
    distance -= arc;
    return .{ .x = track_half_x, .z = -track_half_z + corner_radius + distance };
}

fn trackNormal(t: f32) Vec2 {
    const before = trackPoint(t - 0.001);
    const after = trackPoint(t + 0.001);
    const tx = after.x - before.x;
    const tz = after.z - before.z;
    const inv_len = 1.0 / @sqrt(tx * tx + tz * tz);
    return .{ .x = tz * inv_len, .z = -tx * inv_len };
}

const NearestTrack = struct { center: Vec2, normal: Vec2 };

fn nearestTrack(position: Vec2) NearestTrack {
    var result = NearestTrack{ .center = trackPoint(0.0), .normal = trackNormal(0.0) };
    var best_distance_sq: f32 = std.math.inf(f32);
    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const t0 = tau * @as(f32, @floatFromInt(i)) / segment_count;
        const t1 = tau * @as(f32, @floatFromInt(i + 1)) / segment_count;
        const a = trackPoint(t0);
        const b = trackPoint(t1);
        const edge = Vec2{ .x = b.x - a.x, .z = b.z - a.z };
        const edge_length_sq = dot(edge, edge);
        const along = std.math.clamp(dot(.{ .x = position.x - a.x, .z = position.z - a.z }, edge) / edge_length_sq, 0.0, 1.0);
        const center = add(a, scale(edge, along));
        const offset = Vec2{ .x = position.x - center.x, .z = position.z - center.z };
        const distance_sq = dot(offset, offset);
        if (distance_sq < best_distance_sq) {
            best_distance_sq = distance_sq;
            const inv_len = 1.0 / @sqrt(edge_length_sq);
            result = .{ .center = center, .normal = .{ .x = edge.z * inv_len, .z = -edge.x * inv_len } };
        }
    }
    return result;
}

fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .z = a.z + b.z };
}

fn scale(v: Vec2, amount: f32) Vec2 {
    return .{ .x = v.x * amount, .z = v.z * amount };
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

fn vertex(position: rl.Vector3, tint: rl.Color) void {
    rl.gl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
    rl.gl.rlVertex3f(position.x, position.y, position.z);
}

fn coloredQuad(a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, d: rl.Vector3, ca: rl.Color, cb: rl.Color, cc: rl.Color, cd: rl.Color) void {
    rl.gl.rlBegin(rl.gl.rl_triangles);
    vertex(a, ca);
    vertex(b, cb);
    vertex(c, cc);
    vertex(a, ca);
    vertex(c, cc);
    vertex(d, cd);
    rl.gl.rlEnd();
}

fn roadColorAt(index: usize) rl.Color {
    const spacing: usize = 9;
    const phase = index % spacing;
    const distance = @min(phase, spacing - phase);
    const light = 1.0 - std.math.clamp(@as(f32, @floatFromInt(distance)) / 3.5, 0.0, 1.0);
    return mixColor(color(29, 28, 27, 255), color(77, 59, 41, 255), light * 0.78);
}

fn roadStrip(p0: Vec2, p1: Vec2, n0: Vec2, n1: Vec2, offset: f32, strip_width: f32, tint: rl.Color) void {
    const a = add(p0, scale(n0, offset - strip_width * 0.5));
    const b = add(p1, scale(n1, offset - strip_width * 0.5));
    const c = add(p1, scale(n1, offset + strip_width * 0.5));
    const d = add(p0, scale(n0, offset + strip_width * 0.5));
    coloredQuad(v3(a, road_y + 0.035), v3(b, road_y + 0.035), v3(c, road_y + 0.035), v3(d, road_y + 0.035), tint, tint, tint, tint);
}

fn markingBetween(a: Vec2, b: Vec2, strip_width: f32, tint: rl.Color) void {
    const direction = Vec2{ .x = b.x - a.x, .z = b.z - a.z };
    const inv_len = 1.0 / vecLength(direction);
    const side = Vec2{ .x = direction.z * inv_len * strip_width * 0.5, .z = -direction.x * inv_len * strip_width * 0.5 };
    coloredQuad(v3(add(a, side), road_y + 0.04), v3(add(b, side), road_y + 0.04), v3(add(b, scale(side, -1.0)), road_y + 0.04), v3(add(a, scale(side, -1.0)), road_y + 0.04), tint, tint, tint, tint);
}

fn drawLightPool(center: Vec2, cool: bool) void {
    const center_color = if (cool) color(71, 225, 218, 62) else color(255, 153, 62, 72);
    const edge_color = color(35, 28, 22, 0);
    const slices = 14;
    var i: usize = 0;
    while (i < slices) : (i += 1) {
        const a0 = tau * @as(f32, @floatFromInt(i)) / slices;
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / slices;
        const p0 = Vec2{ .x = center.x + @cos(a0) * 5.5, .z = center.z + @sin(a0) * 8.5 };
        const p1 = Vec2{ .x = center.x + @cos(a1) * 5.5, .z = center.z + @sin(a1) * 8.5 };
        rl.gl.rlBegin(rl.gl.rl_triangles);
        vertex(v3(center, road_y + 0.018), center_color);
        vertex(v3(p1, road_y + 0.018), edge_color);
        vertex(v3(p0, road_y + 0.018), edge_color);
        rl.gl.rlEnd();
    }
}

fn drawTrack() void {
    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const t0 = tau * @as(f32, @floatFromInt(i)) / segment_count;
        const t1 = tau * @as(f32, @floatFromInt(i + 1)) / segment_count;
        const p0 = trackPoint(t0);
        const p1 = trackPoint(t1);
        const n0 = trackNormal(t0);
        const n1 = trackNormal(t1);
        const inner0 = add(p0, scale(n0, -road_half_width));
        const outer0 = add(p0, scale(n0, road_half_width));
        const inner1 = add(p1, scale(n1, -road_half_width));
        const outer1 = add(p1, scale(n1, road_half_width));
        const asphalt0 = roadColorAt(i);
        const asphalt1 = roadColorAt(i + 1);
        coloredQuad(v3(inner0, road_y), v3(inner1, road_y), v3(outer1, road_y), v3(outer0, road_y), asphalt0, asphalt1, asphalt1, asphalt0);

        rl.drawCylinderEx(v3(inner0, road_y + 0.62), v3(inner1, road_y + 0.62), 0.12, 0.12, 5, color(126, 116, 101, 255));
        rl.drawCylinderEx(v3(outer0, road_y + 0.62), v3(outer1, road_y + 0.62), 0.12, 0.12, 5, color(126, 116, 101, 255));
        roadStrip(p0, p1, n0, n1, -road_half_width + 0.55, 0.2, color(222, 218, 195, 255));
        roadStrip(p0, p1, n0, n1, road_half_width - 0.55, 0.23, color(218, 142, 47, 255));
        if (i % 2 == 0) {
            for ([_]f32{ -3.0, 3.0 }) |lane| {
                roadStrip(p0, p1, n0, n1, lane, 0.18, color(226, 224, 207, 245));
            }
        }
        if ((i >= 31 and i < 45) or (i >= 103 and i < 116)) {
            if (i % 2 == 0) markingBetween(add(p0, scale(n0, -7.8)), add(p1, scale(n1, -4.4)), 0.16, color(216, 213, 196, 235));
        }
        if (i % 8 == 0) {
            rl.drawCylinder(v3(p0, 0.0), 0.55, 0.75, road_y, 7, color(42, 48, 56, 255));
        }
        if (i % 9 == 0) {
            const cool = (i / 9) % 5 == 2;
            drawLightPool(add(p0, scale(n0, 3.2)), cool);
            drawStreetLight(outer0, n0, cool);
        }
    }
}

fn drawStreetLight(p: Vec2, normal: Vec2, cool: bool) void {
    const base = v3(p, road_y);
    const top = v3(p, road_y + 5.0);
    const lamp_position = add(p, scale(normal, -2.8));
    const lamp = v3(lamp_position, road_y + 4.85);
    rl.drawCylinderEx(base, top, 0.09, 0.06, 6, color(73, 67, 59, 255));
    rl.drawCylinderEx(top, lamp, 0.06, 0.045, 6, color(91, 79, 65, 255));
    const glow = if (cool) color(65, 229, 221, 100) else color(255, 145, 53, 105);
    const core = if (cool) color(204, 255, 239, 255) else color(255, 231, 177, 255);
    rl.drawSphere(lamp, 0.4, glow);
    rl.drawSphere(lamp, 0.13, core);
}

fn hash2(x: i32, z: i32) u32 {
    var n: u32 = @bitCast(x *% 374761393 +% z *% 668265263);
    n = (n ^ (n >> 13)) *% 1274126177;
    return n ^ (n >> 16);
}

fn drawCity() void {
    rl.drawPlane(.{ .x = 0, .y = -0.05, .z = 0 }, .{ .x = 330, .y = 250 }, color(10, 10, 8, 255));
    var gx: i32 = -7;
    while (gx <= 7) : (gx += 1) {
        var gz: i32 = -5;
        while (gz <= 5) : (gz += 1) {
            const x: f32 = @as(f32, @floatFromInt(gx)) * 17.0;
            const z: f32 = @as(f32, @floatFromInt(gz)) * 17.0;
            const nearest = nearestTrack(.{ .x = x, .z = z });
            const d = @sqrt((x - nearest.center.x) * (x - nearest.center.x) + (z - nearest.center.z) * (z - nearest.center.z));
            if (d < road_half_width + 7.0) continue;

            const hsh = hash2(gx, gz);
            const height = 7.0 + @as(f32, @floatFromInt(hsh % 34));
            const width = 10.0 + @as(f32, @floatFromInt((hsh >> 6) % 5));
            const facade = if (hsh % 3 == 0) color(29, 27, 23, 255) else color(38, 33, 27, 255);
            rl.drawCube(.{ .x = x, .y = height * 0.5, .z = z }, width, height, width, facade);
            rl.drawCubeWires(.{ .x = x, .y = height * 0.5, .z = z }, width, height, width, color(58, 50, 39, 255));

            var floor: i32 = 1;
            while (@as(f32, @floatFromInt(floor)) * 3.2 < height - 1.0) : (floor += 1) {
                if ((hsh +% @as(u32, @intCast(floor * 11))) % 4 == 0) continue;
                const wy = @as(f32, @floatFromInt(floor)) * 3.2;
                const glow = if ((hsh +% @as(u32, @intCast(floor))) % 8 == 0) color(113, 208, 178, 220) else color(246, 174, 78, 210);
                rl.drawCube(.{ .x = x, .y = wy, .z = z - width * 0.5 - 0.025 }, width * 0.52, 0.65, 0.05, glow);
            }
            if (hsh % 11 == 0) {
                const neon = if (hsh % 2 == 0) color(107, 223, 159, 255) else color(106, 82, 226, 255);
                rl.drawCube(.{ .x = x, .y = height * 0.68, .z = z - width * 0.52 }, width * 0.72, 2.0, 0.16, neon);
            }
        }
    }
}

fn localPoint(center: Vec2, yaw: f32, right_amount: f32, forward_amount: f32) Vec2 {
    return .{
        .x = center.x + @cos(yaw) * right_amount + @sin(yaw) * forward_amount,
        .z = center.z - @sin(yaw) * right_amount + @cos(yaw) * forward_amount,
    };
}

fn boxOriented(center: Vec2, y: f32, width: f32, height: f32, length: f32, yaw: f32, tint: rl.Color) void {
    const bl = localPoint(center, yaw, -width * 0.5, -length * 0.5);
    const br = localPoint(center, yaw, width * 0.5, -length * 0.5);
    const fl = localPoint(center, yaw, -width * 0.5, length * 0.5);
    const fr = localPoint(center, yaw, width * 0.5, length * 0.5);
    const y0 = y;
    const y1 = y + height;
    const dark = mixColor(tint, color(6, 5, 4, tint.a), 0.55);
    const side = mixColor(tint, color(24, 16, 10, tint.a), 0.3);
    const top = mixColor(tint, color(255, 185, 104, tint.a), 0.24);
    coloredQuad(v3(bl, y0), v3(br, y0), v3(fr, y0), v3(fl, y0), dark, dark, dark, dark);
    coloredQuad(v3(fl, y1), v3(fr, y1), v3(br, y1), v3(bl, y1), top, top, top, top);
    coloredQuad(v3(bl, y0), v3(fl, y0), v3(fl, y1), v3(bl, y1), side, side, tint, tint);
    coloredQuad(v3(fr, y0), v3(br, y0), v3(br, y1), v3(fr, y1), side, side, tint, tint);
    coloredQuad(v3(br, y0), v3(bl, y0), v3(bl, y1), v3(br, y1), dark, dark, side, side);
    coloredQuad(v3(fl, y0), v3(fr, y0), v3(fr, y1), v3(fl, y1), side, side, top, top);
}

fn drawHeadlightWash(position: Vec2, yaw: f32) void {
    const near_left = localPoint(position, yaw, -0.72, 2.0);
    const near_right = localPoint(position, yaw, 0.72, 2.0);
    const far_left = localPoint(position, yaw, -3.1, 12.5);
    const far_right = localPoint(position, yaw, 3.1, 12.5);
    const near = color(255, 224, 170, 48);
    const far = color(255, 191, 102, 0);
    coloredQuad(v3(near_left, road_y + 0.055), v3(far_left, road_y + 0.055), v3(far_right, road_y + 0.055), v3(near_right, road_y + 0.055), near, far, far, near);
}

fn drawCar(position: Vec2, yaw: f32, paint: rl.Color) void {
    drawHeadlightWash(position, yaw);
    boxOriented(position, road_y + 0.18, 2.05, 0.65, 4.25, yaw, paint);
    const cabin = localPoint(position, yaw, 0.0, -0.18);
    boxOriented(cabin, road_y + 0.82, 1.72, 0.62, 2.1, yaw, color(24, 42, 57, 255));
    const nose = localPoint(position, yaw, 0.0, 2.16);
    for ([_]f32{ -0.62, 0.62 }) |side| {
        const lamp = localPoint(nose, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.2, color(255, 227, 177, 105));
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.11, color(255, 249, 222, 255));
    }
    const tail = localPoint(position, yaw, 0.0, -2.16);
    for ([_]f32{ -0.68, 0.68 }) |side| {
        const lamp = localPoint(tail, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.22, color(255, 24, 19, 90));
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.11, color(255, 61, 38, 255));
    }
}

fn drawPlayerCar(player_model: PlayerModel, position: Vec2, yaw: f32) void {
    drawHeadlightWash(position, yaw);
    player_model.draw(position, yaw);
    const nose = localPoint(position, yaw, 0.0, 2.16);
    for ([_]f32{ -0.62, 0.62 }) |side| {
        const lamp = localPoint(nose, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.2, color(255, 227, 177, 105));
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.11, color(255, 249, 222, 255));
    }
    const tail = localPoint(position, yaw, 0.0, -2.16);
    for ([_]f32{ -0.68, 0.68 }) |side| {
        const lamp = localPoint(tail, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.22, color(255, 24, 19, 90));
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.11, color(255, 61, 38, 255));
    }
}

fn drawTraffic(elapsed: f32) void {
    const paints = [_]rl.Color{
        color(224, 218, 199, 255), color(31, 50, 117, 255),  color(151, 38, 30, 255),
        color(38, 36, 32, 255),    color(186, 124, 42, 255), color(43, 91, 75, 255),
    };
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const t = @mod(fi * 0.67 + elapsed * (0.075 + fi * 0.002), tau);
        const p = trackPoint(t);
        const n = trackNormal(t);
        const lane: f32 = if (i % 2 == 0) -4.6 else 1.5;
        const pos = add(p, scale(n, lane));
        const before = trackPoint(t - 0.001);
        const after = trackPoint(t + 0.001);
        const tangent = Vec2{ .x = after.x - before.x, .z = after.z - before.z };
        drawCar(pos, std.math.atan2(tangent.x, tangent.z), paints[i % paints.len]);
    }
}

fn drawHud(car: Car) void {
    const width = rl.getScreenWidth();
    const height = rl.getScreenHeight();
    const speed_x = width - 82;
    const speed_y = height - 94;

    rl.drawRectangleGradientV(0, 0, width, 88, color(4, 8, 15, 185), color(4, 8, 15, 0));
    rl.drawText("KANJO NIGHT", 28, 22, 24, color(224, 237, 239, 255));
    rl.drawText("WANGAN LOOP // 01:17 AM", 29, 50, 12, color(66, 201, 219, 255));
    rl.drawFPS(width - 92, 18);

    rl.drawCircleGradient(.{ .x = @floatFromInt(speed_x), .y = @floatFromInt(speed_y) }, 76, color(10, 14, 23, 210), color(10, 14, 23, 35));
    rl.drawCircleLines(speed_x, speed_y, 59, color(89, 109, 121, 220));
    const kmh: i32 = @intFromFloat(@abs(car.speed) * 3.6);
    var speed_buf: [16]u8 = undefined;
    const speed_text = std.fmt.bufPrintZ(&speed_buf, "{d:0>3}", .{kmh}) catch "---";
    rl.drawText(speed_text, speed_x - 39, speed_y - 24, 38, color(239, 245, 241, 255));
    rl.drawText("KM/H", speed_x - 18, speed_y + 18, 13, color(74, 210, 224, 255));
    rl.drawText(if (car.speed < -0.5) "R" else "5", speed_x + 20, speed_y + 25, 22, color(245, 67, 104, 255));
    if (car.drift_amount > 0.18) {
        rl.drawText("DRIFT", speed_x - 25, speed_y - 58, 16, color(245, 67, 104, 255));
    }

    rl.drawRectangle(27, height - 57, 205, 5, color(29, 40, 51, 230));
    const boost_width: i32 = @intFromFloat(205.0 * std.math.clamp(@abs(car.speed) / 84.0, 0.0, 1.0));
    rl.drawRectangle(27, height - 57, boost_width, 5, color(31, 190, 217, 255));
    rl.drawText("SPEED BREAKER", 27, height - 45, 12, color(155, 174, 181, 255));
    rl.drawText("WASD/ARROWS DRIVE  SPACE HANDBRAKE  R RESET", 27, height - 21, 11, color(122, 139, 148, 255));
}

pub fn main() !void {
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .vsync_hint = true });
    rl.initWindow(screen_width, screen_height, "KANJO NIGHT // Zig + raylib");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const player_model = try PlayerModel.init();
    defer player_model.unload();

    var car = Car{};
    var camera_rig = CameraRig{};
    var elapsed: f32 = 0.0;
    while (!rl.windowShouldClose()) {
        const dt = @min(rl.getFrameTime(), 1.0 / 30.0);
        elapsed += dt;
        if (rl.isKeyPressed(.r)) {
            car.reset();
            camera_rig.reset(car);
        }
        car.update(dt);
        const camera = camera_rig.update(car, dt);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(color(4, 4, 3, 255));
        rl.drawRectangleGradientV(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), color(3, 5, 5, 255), color(31, 20, 12, 255));
        camera.begin();
        drawCity();
        drawTrack();
        drawTraffic(elapsed);
        drawPlayerCar(player_model, car.position, car.yaw);
        camera.end();
        drawHud(car);
    }
}
