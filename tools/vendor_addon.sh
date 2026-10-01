#!/bin/bash
# Vendor the double godot-sandbox libraries from the addon release releases.env pins.
#   tools/vendor_addon.sh [addon-tag]
# Each file is checked against the release's SHA256SUMS before it lands in
# addons/godot_sandbox/bin under the name the .gdextension maps.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. tools/frame/releases.env
tag=${1:-$ADDON_TAG}
base=https://github.com/V-Sekai-fire/service-godot-build/releases/download/$tag
bin=addons/godot_sandbox/bin
mac=libgodot_riscv.macos.template_release.double.universal
sum256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
for f in libgodot_riscv.windows.template_release.double.x86_64.dll \
         libgodot_riscv.linux.template_release.double.x86_64.so "$mac"; do
  curl -fsSL -o "$tmp/$f" "$base/$f"
  grep -q " $f\$" "$tmp/SHA256SUMS" || { echo "FAIL $f is not in $tag's SHA256SUMS"; exit 1; }
  (cd "$tmp" && grep " $f\$" SHA256SUMS | sum256 -c --quiet -) || { echo "FAIL $f does not match $tag"; exit 1; }
done
cp "$tmp"/*.dll "$tmp"/*.so "$bin/"
mkdir -p "$bin/$mac.framework"
cp "$tmp/$mac" "$bin/$mac.framework/$mac"
grep -E ' libgodot_riscv\.[a-z]+\.template_release\.double\.' "$tmp/SHA256SUMS"
