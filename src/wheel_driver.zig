const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const io = if (is_linux) @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
}) else struct {};
const ev = if (is_linux) @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("linux/input.h");
}) else struct {};

const JS_EVENT_AXIS: u8 = 0x02;
const JS_EVENT_BUTTON: u8 = 0x01;

const JsEvent = extern struct {
    time: u32,
    value: i16,
    type: u8,
    number: u8,
};

pub const Wheel = struct {
    fd: c_int = -1,
    axes: [8]f32 = .{0} ** 8,
    buttons: [32]bool = .{false} ** 32,
    available: bool = false,

    pub fn init() Wheel {
        if (comptime !is_linux) return .{};
        const fd = io.open("/dev/input/js0", io.O_RDONLY | io.O_NONBLOCK);
        return .{ .fd = fd, .available = fd >= 0 };
    }

    pub fn deinit(self: *Wheel) void {
        if (comptime !is_linux) return;
        if (self.available) _ = io.close(self.fd);
    }

    pub fn poll(self: *Wheel) void {
        if (comptime !is_linux) return;
        if (!self.available) return;
        var event: JsEvent = undefined;
        const size: usize = @sizeOf(JsEvent);
        while (true) {
            const bytes_read = io.read(self.fd, &event, size);
            if (bytes_read != size) break;
            if (event.type & JS_EVENT_AXIS != 0) {
                if (event.number < self.axes.len) self.axes[event.number] = @as(f32, @floatFromInt(event.value)) / 32767.0;
            } else if (event.type & JS_EVENT_BUTTON != 0) {
                if (event.number < self.buttons.len) self.buttons[event.number] = event.value != 0;
            }
        }
    }

    pub fn steering(self: Wheel) f32 {
        return self.axes[0];
    }

    pub fn throttle(self: Wheel) f32 {
        return std.math.clamp((1.0 - self.axes[1]) * 0.5, 0.0, 1.0);
    }

    pub fn brake(self: Wheel) f32 {
        return std.math.clamp((1.0 - self.axes[2]) * 0.5, 0.0, 1.0);
    }
};

const EVIOCSFF: c_ulong = 0x40304580;
const EVIOCRMFF: c_ulong = 0x40044581;
const FF_CONSTANT: u16 = 0x52;
const FF_GAIN: u16 = 0x60;
const FF_AUTOCENTER: u16 = 0x61;
const EV_FF: u16 = 0x15;
const Effect = if (is_linux) ev.struct_ff_effect else u8;

pub const ForceFeedback = struct {
    fd: c_int = -1,
    available: bool = false,
    effect: Effect = std.mem.zeroes(Effect),
    collision_force: f32 = 0,

    pub fn init() ForceFeedback {
        if (comptime !is_linux) return .{};
        var self = ForceFeedback{};
        var index: c_int = 0;
        while (index < 32) : (index += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{index}) catch continue;
            const fd = io.open(path.ptr, io.O_RDWR);
            if (fd < 0) continue;

            var evbits: [4]u8 = .{0} ** 4;
            const EVIOCGBIT0: c_ulong = 0x80044520;
            _ = ev.ioctl(fd, EVIOCGBIT0, &evbits);
            if (evbits[2] & (@as(u8, 1) << 5) != 0) {
                self.fd = fd;
                self.available = true;
                break;
            }
            _ = io.close(fd);
        }
        if (!self.available) return self;

        self.write(FF_GAIN, 0xFFFF);
        self.write(FF_AUTOCENTER, 0x5000);
        self.effect.type = FF_CONSTANT;
        self.effect.id = -1;
        self.effect.replay.length = 0;
        self.effect.u.constant.level = 0;
        _ = ev.ioctl(self.fd, EVIOCSFF, &self.effect);
        self.write(EV_FF, 1);
        return self;
    }

    pub fn deinit(self: *ForceFeedback) void {
        if (comptime !is_linux) return;
        if (!self.available) return;
        self.write(EV_FF, 0);
        if (self.effect.id >= 0) _ = ev.ioctl(self.fd, EVIOCRMFF, self.effect.id);
        self.write(FF_AUTOCENTER, 0);
        _ = io.close(self.fd);
    }

    pub fn update(self: *ForceFeedback, speed: f32, time: f32, collided: bool) void {
        if (comptime !is_linux) return;
        if (!self.available) return;
        var level: f32 = 0;
        const speed_factor = std.math.clamp(@abs(speed) / 50.0, 0.0, 1.0);
        if (speed_factor > 0.05) {
            const rumble = @sin(time * 65.0) * speed_factor * 3000.0;
            const noise: f32 = @sin(time * 999.7) * 5.0;
            level += rumble + noise * speed_factor * 300.0;
        }
        if (collided) self.collision_force = 28000.0;
        self.collision_force *= 0.80;
        if (self.collision_force > 1.0) level += self.collision_force;
        self.effect.u.constant.level = @intFromFloat(std.math.clamp(level, -32767.0, 32767.0));
        _ = ev.ioctl(self.fd, EVIOCSFF, &self.effect);
    }

    fn write(self: ForceFeedback, code: u16, value: i32) void {
        if (comptime !is_linux) return;
        var event: ev.struct_input_event = std.mem.zeroes(ev.struct_input_event);
        event.type = EV_FF;
        event.code = if (self.effect.id >= 0 and code == EV_FF) @intCast(self.effect.id) else code;
        event.value = value;
        _ = io.write(self.fd, &event, @sizeOf(ev.struct_input_event));
    }
};
