#!/bin/bash
# Vendor the Godot port of Sakuragaoka Station and the MToon shaders it renders with, from
# entities-sakuragaoka-station at a commit some remote branch contains.
#   tools/vendor_station.sh <commit> [checkout]     checkout defaults to the placed 4-entities one
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
src=${2:-../../4-entities/sakuragaoka-station}
git -C "$src" fetch -q v-sekai-fire
sha=$(git -C "$src" rev-parse "${1:?commit}^{commit}")
git -C "$src" branch -r --contains "$sha" | grep -q . || { echo "FAIL $sha is on no remote branch"; exit 1; }
rm -rf addons/sakuragaoka_station addons/Godot-MToon-Shader
git -C "$src" archive "$sha" addons/sakuragaoka_station addons/Godot-MToon-Shader | tar -x
git -C "$src" show "$sha:LICENSE" > addons/sakuragaoka_station/LICENSE
cat > addons/sakuragaoka_station/CITATION.cff <<CFF
cff-version: 1.2.0
message: If you use this addon, cite the Godot port of Sakuragaoka Station and its original.
title: Sakuragaoka Station, Godot port (vendored)
abstract: >-
  The world modules of the three.js Sakuragaoka Station ported to GDScript, checked against the
  original's oracle and realized with CSG and godot-vrm's MToon, vendored by
  tools/vendor_station.sh with the MToon shaders beside it.
authors:
  - name: Sakuragaoka Station contributors
  - name: V-Sekai-fire
repository-code: https://github.com/V-Sekai-fire/entities-sakuragaoka-station
commit: $sha
license: MIT
references:
  - type: software
    title: Sakuragaoka Station (three.js)
    authors:
      - name: Sakuragaoka Station contributors
    repository-code: https://github.com/Kenton-GMI/sakuragaoka-station
    commit: 4112f57208b7e29998344ca71fef74202c2b2bdd
    license: MIT
CFF
echo "vendored entities-sakuragaoka-station $sha"
