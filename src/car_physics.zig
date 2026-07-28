const std = @import("std");

pub const Vec2 = struct { x: f32, z: f32 };

pub fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .z = a.z + b.z };
}

pub fn scale(vector: Vec2, amount: f32) Vec2 {
    return .{ .x = vector.x * amount, .z = vector.z * amount };
}

pub fn dot(a: Vec2, b: Vec2) f32 {
    return a.x * b.x + a.z * b.z;
}

pub fn length(vector: Vec2) f32 {
    return @sqrt(dot(vector, vector));
}

pub const Controls = struct {
    throttle: f32 = 0,
    brake: f32 = 0,
    steer: f32 = 0,
    handbrake: bool = false,
};

pub const Config = struct {
    top_speed: f32 = 56.0,
    reverse_speed: f32 = 12.0,
    acceleration: f32 = 4.0,
    braking: f32 = 11.5,
    reverse_acceleration: f32 = 4.0,
    drag: f32 = 0.0035,
};

pub const civic_config = Config{};

pub const Car = struct {
    position: Vec2 = .{ .x = 0, .z = 0 },
    velocity: Vec2 = .{ .x = 0, .z = 0 },
    yaw: f32 = 0,
    yaw_rate: f32 = 0,
    speed: f32 = 0,
    steer_visual: f32 = 0,
    drift_amount: f32 = 0,
    collided: bool = false,

    pub fn reset(self: *Car, position: Vec2, yaw: f32) void {
        self.* = .{ .position = position, .yaw = yaw };
    }

    pub fn update(self: *Car, dt: f32, controls: Controls, config: Config) void {
        const throttle = std.math.clamp(controls.throttle, 0.0, 1.0);
        const brake = std.math.clamp(controls.brake, 0.0, 1.0);
        const steer = std.math.clamp(controls.steer, -1.3, 1.3);
        const handbrake = controls.handbrake;

        var forward = Vec2{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        var right = Vec2{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        var long_speed = dot(self.velocity, forward);
        var lateral_speed = dot(self.velocity, right);

        if (throttle > 0.0) {
            const speed_ratio = std.math.clamp(@abs(long_speed) / config.top_speed, 0.0, 1.0);
            const power_falloff = 1.0 - std.math.pow(f32, speed_ratio, 2.2);
            self.velocity = add(self.velocity, scale(forward, config.acceleration * throttle * power_falloff * dt));
        }
        if (brake > 0.0) {
            const force = if (long_speed > 1.0) -config.braking else if (long_speed > -config.reverse_speed) -config.reverse_acceleration else 0.0;
            self.velocity = add(self.velocity, scale(forward, force * brake * dt));
        }

        const speed_factor = std.math.clamp(@abs(long_speed) / 14.0, 0.0, 1.0);
        const reverse: f32 = if (long_speed < -0.5) -1.0 else 1.0;
        const steer_rate: f32 = if (handbrake) 1.72 else 1.18;
        const target_yaw_rate = steer * steer_rate * speed_factor * reverse;
        const yaw_response: f32 = if (handbrake) 7.5 else 5.0;
        self.yaw_rate += (target_yaw_rate - self.yaw_rate) * std.math.clamp(yaw_response * dt, 0.0, 1.0);
        if (handbrake and @abs(long_speed) > 18.0) self.yaw_rate += steer * 1.25 * dt * reverse;
        if (@abs(steer) < 0.05) self.yaw_rate *= std.math.clamp(1.0 - 3.2 * dt, 0.0, 1.0);
        self.yaw += self.yaw_rate * dt;

        forward = .{ .x = @sin(self.yaw), .z = @cos(self.yaw) };
        right = .{ .x = @cos(self.yaw), .z = -@sin(self.yaw) };
        long_speed = dot(self.velocity, forward);
        lateral_speed = dot(self.velocity, right);
        var grip: f32 = if (handbrake) 0.72 else 6.8;
        if (!handbrake and throttle > 0.0 and @abs(lateral_speed) > 4.5 and @abs(long_speed) > 24.0) grip = 2.7;
        self.velocity = add(self.velocity, scale(right, -lateral_speed * std.math.clamp(grip * dt, 0.0, 1.0)));

        const drag: f32 = if (handbrake) 0.52 else config.drag;
        self.velocity = scale(self.velocity, std.math.clamp(1.0 - drag * dt, 0.0, 1.0));
        const velocity_length = length(self.velocity);
        if (velocity_length > config.top_speed) self.velocity = scale(self.velocity, config.top_speed / velocity_length);

        self.position = add(self.position, scale(self.velocity, dt));
        self.speed = dot(self.velocity, forward);
        const drift_target = std.math.clamp(@abs(dot(self.velocity, right)) / 15.0, 0.0, 1.0) * speed_factor;
        self.drift_amount += (drift_target - self.drift_amount) * std.math.clamp(dt * 7.0, 0.0, 1.0);
        self.steer_visual += (steer - self.steer_visual) * std.math.clamp(dt * 9.0, 0.0, 1.0);
        self.collided = false;
    }
};
