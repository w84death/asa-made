# Kanjo Night

A dependency-light Zig and raylib proof of concept for a PSP-era arcade city-driving game. The elevated expressway, traffic, buildings, lights, cars, and HUD are procedural placeholders, so no asset download is required.

## Run

```sh
zig build run
```

Controls:

- `WASD` or arrow keys: accelerate, brake, and steer
- `Space`: handbrake
- `R`: reset the car
- `Esc`: quit

The project targets Zig 0.16.0 and pins raylib-zig in `build.zig.zon`.
