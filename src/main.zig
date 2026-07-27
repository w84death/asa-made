const std = @import("std");
const rl = @import("raylib");

const screen_width = 640;
const screen_height = 480;
const road_y: f32 = 2.2;
const track_half_x: f32 = 118.0;
const track_half_z: f32 = 52.0;
const corner_radius: f32 = 24.0;
const road_half_width: f32 = 9.0;
const segment_count = 144;
const tau: f32 = std.math.pi * 2.0;

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

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
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

fn quad(a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, d: rl.Vector3, tint: rl.Color) void {
    rl.drawTriangle3D(a, b, c, tint);
    rl.drawTriangle3D(a, c, d, tint);
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
        const asphalt = if (i % 2 == 0) color(31, 35, 42, 255) else color(35, 39, 47, 255);
        quad(v3(inner0, road_y), v3(inner1, road_y), v3(outer1, road_y), v3(outer0, road_y), asphalt);

        rl.drawCylinderEx(v3(inner0, road_y + 0.62), v3(inner1, road_y + 0.62), 0.12, 0.12, 5, color(126, 141, 153, 255));
        rl.drawCylinderEx(v3(outer0, road_y + 0.62), v3(outer1, road_y + 0.62), 0.12, 0.12, 5, color(126, 141, 153, 255));
        if (i % 2 == 0) {
            for ([_]f32{ -3.0, 3.0 }) |lane| {
                rl.drawLine3D(v3(add(p0, scale(n0, lane)), road_y + 0.025), v3(add(p1, scale(n1, lane)), road_y + 0.025), color(188, 197, 196, 205));
            }
        }
        if (i % 8 == 0) {
            rl.drawCylinder(v3(p0, 0.0), 0.55, 0.75, road_y, 7, color(42, 48, 56, 255));
        }
        if (i % 7 == 0) drawStreetLight(outer0);
    }
}

fn drawStreetLight(p: Vec2) void {
    const base = v3(p, road_y);
    const top = v3(p, road_y + 5.0);
    rl.drawCylinderEx(base, top, 0.09, 0.06, 6, color(70, 80, 91, 255));
    rl.drawSphere(top, 0.42, color(255, 188, 82, 115));
    rl.drawSphere(top, 0.13, color(255, 236, 179, 255));
}

fn hash2(x: i32, z: i32) u32 {
    var n: u32 = @bitCast(x *% 374761393 +% z *% 668265263);
    n = (n ^ (n >> 13)) *% 1274126177;
    return n ^ (n >> 16);
}

fn drawCity() void {
    rl.drawPlane(.{ .x = 0, .y = -0.05, .z = 0 }, .{ .x = 330, .y = 250 }, color(9, 13, 20, 255));
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
            const facade = if (hsh % 3 == 0) color(27, 34, 48, 255) else color(34, 37, 46, 255);
            rl.drawCube(.{ .x = x, .y = height * 0.5, .z = z }, width, height, width, facade);
            rl.drawCubeWires(.{ .x = x, .y = height * 0.5, .z = z }, width, height, width, color(50, 57, 70, 255));

            var floor: i32 = 1;
            while (@as(f32, @floatFromInt(floor)) * 3.2 < height - 1.0) : (floor += 1) {
                if ((hsh +% @as(u32, @intCast(floor * 11))) % 4 == 0) continue;
                const wy = @as(f32, @floatFromInt(floor)) * 3.2;
                const glow = if ((hsh +% @as(u32, @intCast(floor))) % 5 == 0) color(72, 188, 209, 220) else color(246, 185, 88, 210);
                rl.drawCube(.{ .x = x, .y = wy, .z = z - width * 0.5 - 0.025 }, width * 0.52, 0.65, 0.05, glow);
            }
            if (hsh % 11 == 0) {
                const neon = if (hsh % 2 == 0) color(232, 34, 105, 255) else color(34, 199, 221, 255);
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
    quad(v3(bl, y0), v3(br, y0), v3(fr, y0), v3(fl, y0), tint);
    quad(v3(fl, y1), v3(fr, y1), v3(br, y1), v3(bl, y1), tint);
    quad(v3(bl, y0), v3(fl, y0), v3(fl, y1), v3(bl, y1), tint);
    quad(v3(fr, y0), v3(br, y0), v3(br, y1), v3(fr, y1), tint);
    quad(v3(br, y0), v3(bl, y0), v3(bl, y1), v3(br, y1), tint);
    quad(v3(fl, y0), v3(fr, y0), v3(fr, y1), v3(fl, y1), tint);
}

fn drawCar(position: Vec2, yaw: f32, paint: rl.Color, player: bool) void {
    boxOriented(position, road_y + 0.18, 2.05, 0.65, 4.25, yaw, paint);
    const cabin = localPoint(position, yaw, 0.0, -0.18);
    boxOriented(cabin, road_y + 0.82, 1.72, 0.62, 2.1, yaw, color(24, 42, 57, 255));
    const nose = localPoint(position, yaw, 0.0, 2.16);
    for ([_]f32{ -0.62, 0.62 }) |side| {
        const lamp = localPoint(nose, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.58), 0.15, color(206, 234, 255, 255));
    }
    const tail = localPoint(position, yaw, 0.0, -2.16);
    for ([_]f32{ -0.68, 0.68 }) |side| {
        const lamp = localPoint(tail, yaw, side, 0.0);
        rl.drawSphere(v3(lamp, road_y + 0.55), 0.14, color(255, 36, 44, 255));
    }
    if (player) {
        const wing_l = localPoint(position, yaw, -0.93, -1.75);
        const wing_r = localPoint(position, yaw, 0.93, -1.75);
        rl.drawCylinderEx(v3(wing_l, road_y + 1.25), v3(wing_r, road_y + 1.25), 0.06, 0.06, 5, color(18, 20, 25, 255));
    }
}

fn drawTraffic(elapsed: f32) void {
    const paints = [_]rl.Color{
        color(221, 225, 230, 255), color(37, 71, 137, 255),  color(176, 35, 49, 255),
        color(67, 69, 73, 255),    color(220, 153, 36, 255), color(45, 120, 106, 255),
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
        drawCar(pos, std.math.atan2(tangent.x, tangent.z), paints[i % paints.len], false);
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

    var car = Car{};
    var elapsed: f32 = 0.0;
    while (!rl.windowShouldClose()) {
        const dt = @min(rl.getFrameTime(), 1.0 / 30.0);
        elapsed += dt;
        if (rl.isKeyPressed(.r)) car.reset();
        car.update(dt);

        const forward = Vec2{ .x = @sin(car.yaw), .z = @cos(car.yaw) };
        const camera_distance = 10.5 + std.math.clamp(@abs(car.speed) * 0.055, 0.0, 3.5);
        const camera = rl.Camera3D{
            .position = .{
                .x = car.position.x - forward.x * camera_distance,
                .y = road_y + 5.2,
                .z = car.position.z - forward.z * camera_distance,
            },
            .target = .{
                .x = car.position.x + forward.x * 5.5,
                .y = road_y + 1.15,
                .z = car.position.z + forward.z * 5.5,
            },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = 67.0 + std.math.clamp(@abs(car.speed) * 0.11, 0.0, 7.0),
            .projection = .perspective,
        };

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(color(4, 6, 13, 255));
        rl.drawRectangleGradientV(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), color(7, 12, 28, 255), color(25, 18, 33, 255));
        camera.begin();
        drawCity();
        drawTrack();
        drawTraffic(elapsed);
        drawCar(car.position, car.yaw, color(70, 191, 216, 255), true);
        camera.end();
        drawHud(car);
    }
}
