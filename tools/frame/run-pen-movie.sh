#!/bin/bash
# Render the pen scene flat to a movie (Godot Movie Maker mode), companions driven
# by the vpen feeder. Flat viewport, so nothing submits to the OpenVR compositor
# (which asserts under the compat layer). Quits cleanly via --quit-after. RFD 2287.
#   run-pen-movie.sh <tag> <frames> <fps>
tag=${1:-movie}; frames=${2:-450}; fps=${3:-30}
R=$HOME/rfd2287; C=$HOME/.local/share/Steam/steamapps/common; P=$R/proton-xrfix
export XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:1 WAYLAND_DISPLAY=gamescope-0
export STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.local/share/Steam STEAM_COMPAT_DATA_PATH=$R/compat-xrfix
export SteamGameId=9990002287 SteamAppId=9990002287 WINEDEBUG=err+all
mkdir -p $R/movie
cd "$R/pen"
timeout -k 10 360 "$C/SteamLinuxRuntime_4-arm64/_v2-entry-point" --verb=waitforexitandrun -- \
  "$P/proton" waitforexitandrun "$R/godot-dbl/godot.windows.editor.double.x86_64.llvm.exe" \
  --log-file "Z:$R/logs/$tag.godot.log" --path "Z:$R/pen" --rendering-driver vulkan \
  --write-movie "Z:$R/movie/$tag.avi" --fixed-fps $fps --quit-after $frames \
  > "$R/logs/$tag.out" 2>&1
echo "rc=$? ; movie file:"; ls -l $R/movie/$tag.avi 2>/dev/null
grep -aE "companion pen|[0-9]+ spawned|Movie|signal 11|xr_main:" $R/logs/$tag.godot.log 2>/dev/null | cut -c1-150 | head
