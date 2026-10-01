#!/bin/bash
# Run the pen scene on the headset through OpenVR (godot_openvr), no --xr-mode: the
# extension is the XR interface and xr_world picks it, so the companion vpen
# devices show up. Same compat-layer copy as run-pen-movie.sh.
#   run-pen-openvr.sh <tag> [wall_seconds]
tag=${1:-pen-ovr}; wall=${2:-75}
R=$HOME/rfd2287; C=$HOME/.local/share/Steam/steamapps/common; P=$R/proton-xrfix
export XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:1 WAYLAND_DISPLAY=gamescope-0
export STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.local/share/Steam STEAM_COMPAT_DATA_PATH=$R/compat-xrfix
export SteamGameId=9990002287 SteamAppId=9990002287 WINEDEBUG=err+all
cd "$R/pen"
timeout -k 10 "$wall" "$C/SteamLinuxRuntime_4-arm64/_v2-entry-point" --verb=waitforexitandrun -- \
  "$P/proton" waitforexitandrun "$R/godot-dbl/godot.windows.editor.double.x86_64.llvm.exe" \
  --log-file "Z:$R/logs/$tag.godot.log" --path "Z:$R/pen" --rendering-driver vulkan \
  > "$R/logs/$tag.out" 2>&1
echo "=== dress-on / OpenVR / companion lines:"
grep -aE "dress-on|OpenVR|openvr|companion|controller_|vpen|GDExtension|Can.t open|[Ff]ailed" "$R/logs/$tag.godot.log" 2>/dev/null | cut -c1-180 | head -50
echo "=== tail:"; tail -3 "$R/logs/$tag.out"
