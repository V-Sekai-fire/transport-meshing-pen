#!/bin/sh
# The engine the suit tasks run: $GODOT, else the manifest's sibling entities-godot build (the
# double editor with the xatlas fix). On WSL it draws through WSLg's Wayland socket.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GODOT:-$ROOT/../../4-entities/godot/bin/godot.linuxbsd.editor.double.x86_64}"
if [ ! -x "$G" ]; then
	echo "tools/godot.sh: no engine at $G (run: pixi run engine)" >&2
	exit 2
fi
if [ -d /mnt/wslg ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0
	exec "$G" --display-driver wayland "$@"
fi
exec "$G" "$@"
