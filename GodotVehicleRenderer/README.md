# TeslaSiri vehicle renderer

This is a deliberately small Godot 4.6 project used as an embedded, passive
vehicle hero in the iOS app. It imports the ten portable GLBs supplied in the
local Tesla recovery kit, loads only the selected vehicle, and accepts a
sanitized state dictionary from Swift.

Build the pack with:

```sh
GODOT_BIN=/path/to/Godot ./Scripts/build-vehicle-renderer.sh
```

The generated pack is written to `TeslaSiri/Resources/VehicleRenderer.pck`.
The GLBs and PCK are stored with Git LFS. These recovered Tesla assets are for
this private hobby project only and must not be redistributed publicly.
