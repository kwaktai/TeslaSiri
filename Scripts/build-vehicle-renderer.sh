#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
PROJECT_DIR="$ROOT_DIR/GodotVehicleRenderer"
OUTPUT_DIR="$ROOT_DIR/TeslaSiri/Resources"
OUTPUT_PATH="$OUTPUT_DIR/VehicleRenderer.pck"

if [[ -z "${GODOT_BIN:-}" ]]; then
    for candidate in \
        "/Applications/Godot.app/Contents/MacOS/Godot" \
        "/tmp/Godot.app/Contents/MacOS/Godot" \
        "/tmp/Godot_v4.6.3-stable_macos.universal/Godot.app/Contents/MacOS/Godot"
    do
        if [[ -x "$candidate" ]]; then
            GODOT_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "${GODOT_BIN:-}" || ! -x "$GODOT_BIN" ]]; then
    print -u2 "Godot 4.6 executable not found. Set GODOT_BIN to the editor binary."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

"$GODOT_BIN" --headless --editor --path "$PROJECT_DIR" --quit
"$GODOT_BIN" --headless --path "$PROJECT_DIR" --script res://scripts/validate_renderer.gd
"$GODOT_BIN" --headless --path "$PROJECT_DIR" --export-pack "iOS" "$OUTPUT_PATH"

if [[ ! -s "$OUTPUT_PATH" ]]; then
    print -u2 "Godot did not produce $OUTPUT_PATH"
    exit 1
fi

print "Built $OUTPUT_PATH"
