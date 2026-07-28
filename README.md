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

## Windows Release

Cross-compile a self-contained Windows x86_64 folder from Linux:

```sh
zig build release-windows
```

Run `Release/windows-x86_64/asa-made.exe`. All runtime assets are embedded in the executable.
