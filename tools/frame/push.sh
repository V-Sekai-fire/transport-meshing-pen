#!/bin/bash
# Put a recorded pen and the engine and addon releases on the headset.
#   push.sh <engine-tag> <addon-tag> [git-ref]
# The pen is `git archive` of the ref (HEAD by default); rsync --delete keeps only the
# headset's import cache (.godot/) and translations (bintr/). The headset fetches the
# release assets itself, checks them against each release's SHA256SUMS, and writes
# ~/rfd2287/PUSHED. The first push keeps the hand-made pen and engine as *.hand.
set -euo pipefail
etag=$1; atag=$2; ref=${3:-HEAD}
host=${FRAME:-frame}
sha=$(git rev-parse "$ref^{commit}")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
git archive "$sha" | tar -x -C "$stage"

ssh "$host" 'R=$HOME/rfd2287
if [ ! -e $R/pen.hand ] && [ -d $R/pen ]; then cp -a $R/pen $R/pen.hand; fi
if [ -d $R/godot-dbl ] && [ ! -L $R/godot-dbl ]; then mv $R/godot-dbl $R/godot-dbl.hand; fi
mkdir -p $R/pen $R/logs'
rsync -a --delete --exclude=/.godot/ --exclude=/bintr/ "$stage/" "$host:rfd2287/pen/"
rsync -a "$stage"/tools/frame/*.sh "$host:rfd2287/"

ssh "$host" bash -s -- "$etag" "$atag" "$sha" <<'EOF'
set -euo pipefail
etag=$1; atag=$2; sha=$3
R=$HOME/rfd2287
base=https://github.com/V-Sekai-fire/service-godot-build/releases/download
exe=godot.windows.editor.double.x86_64.llvm
dll=libgodot_riscv.windows.template_release.double.x86_64.dll

fetch() { # <tag> <dir> <file...>: download, then every file must be listed and match
  local tag=$1 dir=$2; shift 2
  mkdir -p "$dir"; cd "$dir"
  curl -fsSL -o SHA256SUMS "$base/$tag/SHA256SUMS"
  for f in "$@"; do
    [ -s "$f" ] || curl -fsSL -o "$f" "$base/$tag/$f"
    grep -q " $f\$" SHA256SUMS || { echo "FAIL $f is not in $tag's SHA256SUMS"; exit 1; }
    grep " $f\$" SHA256SUMS | sha256sum -c --quiet - || { echo "FAIL $f does not match $tag"; exit 1; }
  done
}

fetch "$etag" "$R/engine/$etag" "$exe.exe" "$exe.console.exe"
ln -sfn "$R/engine/$etag" "$R/godot-dbl"
fetch "$atag" "$R/addon/$atag" "$dll"
cp "$R/addon/$atag/$dll" "$R/pen/addons/godot_sandbox/bin/$dll"

{
  echo "pushed $(date -Is)"
  echo "pen    $sha"
  echo "engine $etag $(grep " $exe.exe\$" "$R/engine/$etag/SHA256SUMS")"
  echo "addon  $atag $(grep " $dll\$" "$R/addon/$atag/SHA256SUMS")"
} | tee "$R/PUSHED"
EOF
