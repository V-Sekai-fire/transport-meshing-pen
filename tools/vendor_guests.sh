#!/bin/bash
# Vendor the guest ELFs the pen loads from the guest releases releases.env pins.
#   tools/vendor_guests.sh [tag suffix]
# Each file is checked against its release's SHA256SUMS before it lands at the
# project root, where res://usd.elf and the other stages load it from.
#
# The ELFs are built in the repositories that own their sources, not here:
# usd.elf in interactor-usd-guest, curvenet.elf in interactor-curvenet,
# dress_on.elf and rd_worker.elf in contract-guest-runtime, and mujoco.elf in
# interactor-mujoco-sandbox-demo.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. tools/frame/releases.env
sum256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# macOS ships bash 3.2, where an empty array under `set -u` is an unbound
# variable, so no header is assembled here.
get() { curl -fsSL "$@"; }

fetch() { # repo tag file...
  repo=$1; tag=$2; shift 2
  base=https://github.com/$repo/releases/download/$tag
  get -o "$tmp/$tag.sums" "$base/SHA256SUMS" ||
    { echo "FAIL cannot read $repo@$tag/SHA256SUMS; a private release needs GH_TOKEN"; exit 1; }
  for f in "$@"; do
    get -o "$tmp/$f" "$base/$f"
    grep -q " $f\$" "$tmp/$tag.sums" || { echo "FAIL $f is not in $repo@$tag's SHA256SUMS"; exit 1; }
    (cd "$tmp" && grep " $f\$" "$tag.sums" | sum256 -c --quiet -) || { echo "FAIL $f does not match $repo@$tag"; exit 1; }
    mv "$tmp/$f" .
    # A download drops the executable bit, which leaves a tracked ELF showing a
    # mode change in every checkout. Put back whatever the index carries.
    [ "$(git ls-files -s -- "$f" | awk '{print $1}')" = "100755" ] && chmod +x "$f"
    echo "  $f  $repo@$tag"
  done
}

# interactor-usd-guest is private. A token cannot use the releases/download URL
# for a private repository, so that one goes through the API, which is what gh
# release download does; the public three read anonymously with curl.
fetch_private() { # repo tag file...
  repo=$1; tag=$2; shift 2
  gh release download "$tag" --repo "$repo" --dir "$tmp" --pattern SHA256SUMS --pattern '*' --clobber ||
    { echo "FAIL cannot read $repo@$tag; a private release needs a token gh holds"; exit 1; }
  for f in "$@"; do
    [ -f "$tmp/$f" ] || { echo "FAIL $f is not in $repo@$tag"; exit 1; }
    (cd "$tmp" && grep " $f\$" SHA256SUMS | sum256 -c --quiet -) || { echo "FAIL $f does not match $repo@$tag"; exit 1; }
    mv "$tmp/$f" .
    # A download drops the executable bit, which leaves a tracked ELF showing a
    # mode change in every checkout. Put back whatever the index carries.
    [ "$(git ls-files -s -- "$f" | awk '{print $1}')" = "100755" ] && chmod +x "$f"
    echo "  $f  $repo@$tag"
  done
}

fetch_private chibifire-smoke-water/interactor-usd-guest "$USD_TAG" usd.elf
fetch V-Sekai-fire/interactor-curvenet "$CURVENET_TAG" curvenet.elf
fetch V-Sekai-fire/contract-guest-runtime "$GUESTS_TAG" dress_on.elf rd_worker.elf
fetch V-Sekai-fire/interactor-mujoco-sandbox-demo "$MUJOCO_TAG" mujoco.elf
