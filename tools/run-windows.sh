#!/usr/bin/env bash
# Run the pen on native Windows SteamVR (Git Bash). One XR interface per run:
#   tools/run-windows.sh           OpenVR renders the headset and tracks the companion pens
#   tools/run-windows.sh openxr    OpenXR renders; companions stay off
# COUNT=<n> starts vpen_feeder.exe animating n companions (openvr mode; 0 = none).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-openvr}"
GODOT="${GODOT:-/c/b/godot-dbl/bin/godot.windows.editor.double.x86_64.llvm.exe}"
OPENVR_ADDON="${OPENVR_ADDON:-/c/b/godot-openvr-frame/godot-openvr}"
SANDBOX_DLL="${SANDBOX_DLL:-/c/b/frame-pen/addons/godot_sandbox/bin/libgodot_riscv.windows.template_release.double.x86_64.dll}"
FEEDER="${FEEDER:-/c/b/frame-controller-sim-win/driver/vpen/bin/win64/vpen_feeder.exe}"
STEAMXR="${STEAMXR:-C:/Program Files (x86)/Steam/steamapps/common/SteamVR/steamxr_win64.json}"
COUNT="${COUNT:-0}"

fail() { echo "run-windows: FAIL $*" >&2; exit 1; }
[ -x "$GODOT" ] || fail "no double-precision Godot at $GODOT"
[ -f "$SANDBOX_DLL" ] || fail "no godot_sandbox double DLL at $SANDBOX_DLL"
cp -u "$SANDBOX_DLL" "$ROOT/addons/godot_sandbox/bin/"
tasklist | grep -qi '^vrserver.exe' || fail "SteamVR is not running"

mkdir -p "$ROOT/.godot"
SANDBOX_EXT="res://addons/godot_sandbox/bin/godot-riscv.gdextension"
case "$MODE" in
openvr)
	[ -f "$OPENVR_ADDON/godot_openvr.gdextension" ] || fail "no godot-openvr addon at $OPENVR_ADDON"
	mkdir -p "$ROOT/addons/godot-openvr"
	cp -ru "$OPENVR_ADDON/." "$ROOT/addons/godot-openvr/"
	printf '%s\nres://addons/godot-openvr/godot_openvr.gdextension\n' "$SANDBOX_EXT" >"$ROOT/.godot/extension_list.cfg"
	printf '[xr]\n\nopenxr/enabled=false\nshaders/enabled=true\n' >"$ROOT/override.cfg"
	ARGS=(-- --render=openvr)
	;;
openxr)
	[ -f "$STEAMXR" ] || fail "no SteamVR OpenXR runtime at $STEAMXR"
	printf '%s\n' "$SANDBOX_EXT" >"$ROOT/.godot/extension_list.cfg"
	printf '[xr]\n\nopenxr/enabled=true\nshaders/enabled=true\n' >"$ROOT/override.cfg"
	export XR_RUNTIME_JSON="$STEAMXR"
	ARGS=(--xr-mode on)
	;;
*) fail "unknown mode '$MODE' (openvr | openxr)" ;;
esac

[ -d "$ROOT/.godot/imported" ] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

feeder_pid=""
if [ "$MODE" = openvr ] && [ "$COUNT" -gt 0 ]; then
	[ -x "$FEEDER" ] || fail "no vpen_feeder.exe at $FEEDER"
	"$FEEDER" --count "$COUNT" >/dev/null &
	feeder_pid=$!
	trap 'kill "$feeder_pid" 2>/dev/null' EXIT
fi
"$GODOT" --path "$ROOT" "${ARGS[@]}"
