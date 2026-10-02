#!/usr/bin/env bash
# The joy orbit-view bundles for a release (contract-orbit-views STANDARD.md): tools/orbit_views.sgd
# per feature writes YYYYMMDD_meshing-pen_joy-<feature>_NNNN.png and .tsv, this writes the .cff.
# Every unmet precondition is a counted FAIL; exit 0 only with none.
#   GODOT=<double editor> tools/orbit_views.sh <tag> <outdir> [--xmp] [--desk] [--control=zero_views]
# --xmp makes each .xmp with `mix cff.xmp ... --check` in MANUALS=<manuals-weftspun>; without it the
# missing .xmp is named and counted as unchecked. A release passes --xmp.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?tag}"
OUT="$(mkdir -p "${2:?outdir}" && cd "$2" && pwd)"
shift 2
DESK=0
XMP=0
CONTROL=()
for a in "$@"; do
	case "$a" in
		--desk) DESK=1 ;;
		--xmp) XMP=1 ;;
		--control=zero_views) CONTROL=(--control=zero_views) ;;
		*) echo "unknown argument $a"; exit 2 ;;
	esac
done
GODOT="${GODOT:-godot}"
TO="$(command -v timeout || command -v gtimeout)"
SHA="$(command -v sha256sum || echo 'shasum -a 256')"
ORACLE=oracle-4112f57-h8-warp
ORACLE_URL=https://github.com/V-Sekai-fire/entities-sakuragaoka-station/releases/download/$ORACLE
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
DAY="$(date -u +%Y%m%d)"
fails=0
unchecked=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

mkdir -p "$OUT/.oracle"
(
	cd "$OUT/.oracle" && curl -fsSL -o SHA256SUMS "$ORACLE_URL/SHA256SUMS" || exit 1
	for i in 0 1 2 3 4 5 6 7; do
		f=$ORACLE-view$i.png
		[ -f "$f" ] || curl -fsSL -o "$f" "$ORACLE_URL/$f" || exit 1
		grep " $f\$" SHA256SUMS | $SHA -c --quiet - || exit 1
	done
) || fail "oracle $ORACLE: download or sha256 check"

"$TO" 900 "$GODOT" --headless --path "$ROOT" --import >"$OUT/.import.log" 2>&1

for feature in walking persona world-grab; do
	case $feature in
		walking) title="walking a faithful station in VR"; joy="(likely, p=0.70)" ;;
		persona) title="the persona visitor touring on its own"; joy="(even, p=0.45)" ;;
		world-grab) title="world grab: turning the town like a model"; joy="(likely, p=0.65)" ;;
	esac
	n=1
	while compgen -G "$OUT/${DAY}_meshing-pen_joy-${feature}_$(printf %04d $n).*" >/dev/null; do n=$((n + 1)); done
	stem="${DAY}_meshing-pen_joy-${feature}_$(printf %04d $n)"
	log="$OUT/.$stem.log"
	"$TO" 1000 "$GODOT" --path "$ROOT" --xr-mode off --fixed-fps 60 --resolution 640x360 --script res://tools/orbit_views.sgd -- \
		--feature=$feature --out="$OUT/$stem.png" --oracle="$OUT/.oracle/$ORACLE-view" \
		--tag="$TAG" --commit="$COMMIT" ${CONTROL[@]+"${CONTROL[@]}"} >"$log" 2>&1
	grep '^joy:' "$log"
	if grep -q 'SafeGDScript:' "$log"; then
		grep -A3 'SafeGDScript:' "$log" | head -12
		fail "$feature: tools/orbit_views.sgd did not compile"
		continue
	fi
	if [ ! -s "$OUT/$stem.png" ] || [ ! -s "$OUT/$stem.tsv" ]; then
		grep '^RESULT' "$log" || tail -20 "$log"
		fail "$feature: no $stem.png and .tsv"
		continue
	fi
	grep -q '^RESULT: PASS' "$log" || fail "$feature: $(grep '^RESULT' "$log" || echo 'no RESULT line')"
	views="$(sed -n 's/^joy: .*views \([0-9]*\) of [0-9]* rendered.*/\1/p' "$log")"
	sum="$($SHA "$OUT/$stem.png" | cut -d' ' -f1)"
	cat >"$OUT/$stem.cff" <<CFF
cff-version: 1.2.0
message: If you use these orbit views, please cite them as below.
type: dataset
title: "$title $joy, meshing-pen $TAG"
version: "$TAG"
abstract: >-
  Orbit views of the RFD 2293 joy feature "$title", forecast $joy: ${views:-0} views from
  sphere_hammersley_sequence rendered by tools/orbit_views.sgd on the double engine at pen
  commit $COMMIT, with the camera table and metrics in $stem.tsv.
authors:
  - name: V-Sekai-fire
date-released: "$(date -u +%Y-%m-%d)"
commit: $COMMIT
url: "https://github.com/v-sekai-fire"
repository-code: https://github.com/V-Sekai-fire/transport-meshing-pen
license: MIT
keywords:
  - orbit views
  - "release: $TAG"
  - "feature: $title"
  - "joy: $joy"
  - "views: ${views:-0}"
identifiers:
  - type: other
    value: "sha256:$sum"
    description: SHA-256 of $stem.png
CFF
	if [ $XMP -eq 0 ]; then
		echo "UNCHECKED $feature: no $stem.xmp (run without --xmp)"
		unchecked=$((unchecked + 1))
	elif [ -n "${MANUALS:-}" ] && (cd "$MANUALS" && mix help cff.xmp >/dev/null 2>&1); then
		(cd "$MANUALS" && mix cff.xmp "$OUT/$stem.cff" "$OUT/$stem.xmp" && mix cff.xmp "$OUT/$stem.cff" "$OUT/$stem.xmp" --check) ||
			fail "$feature: mix cff.xmp"
	else
		fail "$feature: no $stem.xmp (mix cff.xmp is not in MANUALS=${MANUALS:-unset})"
	fi
	if [ $DESK -eq 1 ]; then
		desk="$HOME/Desktop/lookdev-contact-sheets"
		mkdir -p "$desk"
		k=1
		while [ -e "$desk/joy-$(printf %02d $k).png" ]; do k=$((k + 1)); done
		cp -n "$OUT/$stem.png" "$desk/joy-$(printf %02d $k).png" && echo "desk $desk/joy-$(printf %02d $k).png"
	fi
	echo "$feature $stem.png views=${views:-0} sha256=$sum"
done
echo "orbit views: $fails FAIL, $unchecked unchecked"
exit $((fails > 0))
