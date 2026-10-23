#!/bin/sh
# Sim-to-real frames of the suit (weftspun RFD 2332), run by `pixi run suit-sim`.
# Renders each avatar in the plain SOMA sheet and in ours (the same board with multilevel
# adjusted patches, tools/suit_multiscale.py) from four lighthouse-stand cameras: 2.2 m high,
# 3 m out on the diagonals, 1920x1080 with a 90 degree horizontal lens (58.7 vertical). Each
# render comes with its truth render (the sheet square under every pixel). tools/suit_sim.py then
# degrades the frames as a cheap 60/120 fps camera does and writes the dataset.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
OUT="${OUT:-$ROOT/build/suit-sim}"
mkdir -p "$OUT/renders"
python tools/suit_multiscale.py --out xr/suit >/dev/null || { echo "FAIL tools/suit_multiscale.py"; exit 1; }
G="$ROOT/tools/godot.sh"
"$G" --headless --path . --import >"$OUT/import.log" 2>&1
fails=0
for a in foxgirl maro; do
	for sheet in plain ours; do
		res=res://xr/suit/charuco-suit.png
		[ $sheet = ours ] && res=res://xr/suit/charuco-suit-multiscale.png
		for y in 45 135 225 315; do
			stem="$OUT/renders/$a-$y-$sheet"
			rm -f "$stem.png" "$stem-truth.png"
			timeout 300 "$G" --path . --resolution 320x180 --xr-mode off --script tools/probe_suit.gd -- \
				--avatar=$a --sheet=$res --yaw=$y --dist=3.0 --cam_y=2.2 --w=1920 --h=1080 --fov=58.7 \
				--out="$stem.png" --truth="$stem-truth.png" >"$stem.log" 2>&1
			if ! grep -q '^RESULT: PASS' "$stem.log" || [ ! -s "$stem.png" ] || [ ! -s "$stem-truth.png" ]; then
				echo "FAIL $a $sheet yaw $y: no render"
				fails=$((fails + 1))
			fi
		done
	done
done
[ $fails -eq 0 ] || exit 1
python tools/suit_sim.py "$OUT"
