#!/bin/bash
# Put a recorded pen and the engine release it pins on the headset.
#   push.sh [git-ref]        HEAD by default; a release tag pushes that release
# The pen is `git archive` of the ref, carrying the vendored addon; rsync --delete keeps
# only the headset's import cache (.godot/) and translations (bintr/). The tags are the
# ref's tools/frame/releases.env, or ENGINE_TAG and ADDON_TAG. The headset fetches the
# engine, checks it and the pen's addon DLL against their releases' SHA256SUMS, and
# writes ~/rfd2287/PUSHED. The first push keeps the hand-made pen and engine as *.hand.
set -euo pipefail
ref=${1:-HEAD}
host=${FRAME:-frame}
sha=$(git rev-parse "$ref^{commit}")
pins=$(git show "$sha:tools/frame/releases.env")
etag=${ENGINE_TAG:-$(sed -n 's/^ENGINE_TAG=//p' <<<"$pins")}
atag=${ADDON_TAG:-$(sed -n 's/^ADDON_TAG=//p' <<<"$pins")}
[ -n "$etag" ] && [ -n "$atag" ] || { echo "FAIL $ref pins no engine or addon tag"; exit 1; }
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

check() { # <sums> <file>: the file must be listed and match
  grep -q " ${2##*/}\$" "$1" || { echo "FAIL ${2##*/} is not in $1"; exit 1; }
  (cd "$(dirname "$2")" && grep " ${2##*/}\$" "$1" | sha256sum -c --quiet -) || { echo "FAIL $2 does not match $1"; exit 1; }
}

e=$R/engine/$etag
mkdir -p "$e"
curl -fsSL -o "$e/SHA256SUMS" "$base/$etag/SHA256SUMS"
for f in "$exe.exe" "$exe.console.exe"; do
  [ -s "$e/$f" ] || curl -fsSL -o "$e/$f" "$base/$etag/$f"
  check "$e/SHA256SUMS" "$e/$f"
done
ln -sfn "$e" "$R/godot-dbl"
a=$R/addon/$atag
mkdir -p "$a"
curl -fsSL -o "$a/SHA256SUMS" "$base/$atag/SHA256SUMS"
check "$a/SHA256SUMS" "$R/pen/addons/godot_sandbox/bin/$dll"

{
  echo "pushed $(date -Is)"
  echo "pen    $sha"
  echo "engine $etag $(grep " $exe.exe\$" "$e/SHA256SUMS")"
  echo "addon  $atag $(grep " $dll\$" "$a/SHA256SUMS")"
} | tee "$R/PUSHED"
EOF
