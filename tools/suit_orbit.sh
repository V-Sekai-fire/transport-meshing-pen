#!/bin/sh
# The suit-body orbit views (contract-orbit-views STANDARD.md) and the zero-views control, which
# must FAIL. Run by `pixi run suit`; bundles go to build/orbit-suit.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export FEATURES=suit-body GODOT="$ROOT/tools/godot.sh"
bash tools/orbit_views.sh dev4-suit build/orbit-suit || exit 1
if bash tools/orbit_views.sh control build/orbit-suit-control --control=zero_views; then
	echo "FAIL the zero-views control passed"
	exit 1
fi
echo "suit orbit: PASS (the zero-views control failed as it must)"
