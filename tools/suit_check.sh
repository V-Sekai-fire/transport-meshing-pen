#!/bin/sh
# The suit body's checks (weftspun RFD 2332), run by `pixi run suit`:
#  1. every panel's UVs turn the same way as its faces (tools/probe_suit_winding.gd), per avatar;
#  2. close renders from four sides: every marker read is the one the UV map puts there
#     (tools/suit_texture.py --read with probe_suit.gd's truth render), and the same render
#     flipped left to right must FAIL.
# Writes renders to ${OUT:-build/suit-check}; exits 1 on any failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
OUT="${OUT:-$ROOT/build/suit-check}"
mkdir -p "$OUT"
G="$ROOT/tools/godot.sh"
"$G" --headless --path . --import >"$OUT/import.log" 2>&1
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
for a in foxgirl maro; do
	"$G" --headless --path . --script tools/probe_suit_winding.gd -- --avatar=$a >"$OUT/$a-winding.log" 2>&1
	grep -E "triangles" "$OUT/$a-winding.log"
	grep -q '^RESULT: PASS' "$OUT/$a-winding.log" || fail "$a: panels turn both ways"
	for y in 0 90 180 270; do
		png="$OUT/$a-$y.png"
		rm -f "$png"
		# Judged by the PASS line and the image, not the exit code: the engine can exit non-zero
		# on teardown after the frame is saved.
		timeout 300 "$G" --path . --resolution 320x180 --xr-mode off --script tools/probe_suit.gd -- \
			--avatar=$a --out="$png" --truth="$OUT/$a-$y-truth.png" --yaw=$y --dist=1.1 >"$OUT/$a-$y.log" 2>&1
		if ! grep -q '^RESULT: PASS' "$OUT/$a-$y.log" || [ ! -s "$png" ]; then
			fail "$a yaw $y: no render"
			continue
		fi
		python tools/suit_texture.py --read "$png" --truth "$OUT/$a-$y-truth.png" || fail "$a yaw $y: markers read are not the ones the UV map puts there"
		python -c "import cv2,sys;cv2.imwrite(sys.argv[2],cv2.flip(cv2.imread(sys.argv[1]),1))" "$png" "$OUT/$a-$y-flipped.png"
		if python tools/suit_texture.py --read "$OUT/$a-$y-flipped.png" --truth "$OUT/$a-$y-truth.png"; then
			fail "$a yaw $y: the flipped control passed"
		fi
	done
done
echo "suit check: $fails FAIL"
exit $((fails > 0))
