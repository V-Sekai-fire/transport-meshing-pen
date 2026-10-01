#!/bin/bash
# Run the Windows double build of the pen scene through the compat layer, from SSH.
#   run-xr.sh <tag> xr|hidden|flat [driver args...]
# xr: --xr-mode on, expect XR. hidden: the same with XR_RUNTIME_JSON at a missing
# file, still expecting XR, so it must FAIL. flat: --xr-mode off, expect flat.
# The compat layer's steam.exe writes the VR registry key wineopenxr reads only
# for a game process, which it takes SteamGameId to mean; NOSGI=1 leaves it unset.
# PROTON_DIR/COMPAT pick another compat layer copy and prefix; DRIVER the renderer.
tag=$1; mode=$2; shift 2
R=$HOME/rfd2287
C=$HOME/.local/share/Steam/steamapps/common
P=${PROTON_DIR:-$C/Proton 11.0 (ARM64)}
V=$HOME/.local/share/Steam/logs/vrcompositor.txt
S=$HOME/.local/share/Steam/logs/vrserver.txt
export XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:1 WAYLAND_DISPLAY=gamescope-0
export STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.local/share/Steam STEAM_COMPAT_DATA_PATH=${COMPAT:-$R/compat}
mkdir -p "$STEAM_COMPAT_DATA_PATH"
unset PROTON_LOG SteamGameId SteamAppId XR_RUNTIME_JSON
if [ "${NOSGI:-0}" != 1 ]; then export SteamGameId=${SGI:-9990002287} SteamAppId=${SGI:-9990002287}; fi
export WINEDEBUG=${WINEDEBUG:-+openxr,+vrclient,+steam,err+all}
xrmode=on; expect=xr
case $mode in
  hidden) export XR_RUNTIME_JSON='C:\no-such-runtime\hidden.json' ;;
  flat) xrmode=off; expect=flat ;;
esac
off=$(stat -c %s $V); offs=$(stat -c %s $S)
cd $R/pen
{
  echo "=== $(date -Is) tag=$tag mode=$mode driver=${DRIVER:-vulkan} proton=$P prefix=$STEAM_COMPAT_DATA_PATH SteamGameId=${SteamGameId:-} WINEDEBUG=$WINEDEBUG XR_RUNTIME_JSON=${XR_RUNTIME_JSON:-}"
  timeout -k 10 ${WALL:-400} "$C/SteamLinuxRuntime_4-arm64/_v2-entry-point" --verb=waitforexitandrun -- \
    "$P/proton" waitforexitandrun "$R/godot-dbl/godot.windows.editor.double.x86_64.llvm.exe" \
    --log-file "Z:$R/logs/$tag.godot.log" --path "Z:$R/pen" --rendering-driver ${DRIVER:-vulkan} --xr-mode $xrmode \
    --script tools/gate_xr_scripted.gd -- --expect=$expect --out="Z:$R/logs/$tag.txt" --png="Z:$R/logs/$tag.png" "$@"
  echo "rc=$? at $(date -Is)"
} > $R/logs/$tag.out 2>&1
tail -c +$((off + 1)) $V > $R/logs/$tag.vrcompositor.txt
tail -c +$((offs + 1)) $S > $R/logs/$tag.vrserver.txt
tail -2 $R/logs/$tag.out
