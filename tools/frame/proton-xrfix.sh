#!/bin/bash
# Make ~/rfd2287/proton-xrfix from the stock compat layer, on the headset.
# The copy differs from stock Proton 11.0 (ARM64), proton-11.0-2c-arm64, in one
# byte of win32u.so: `ldr x4, [x9, #976]` at file offset 0x13dd34 becomes
# `ldr x4, [x9, #984]`. Both hashes are checked; any other stock build is refused.
set -euo pipefail
src=${1:-$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)}
dst=${2:-$HOME/rfd2287/proton-xrfix}
so=files/lib/wine/aarch64-unix/win32u.so
stock=922534cdb54e3f4b5a3063ebaf9eba5125692125f2bd088a4c01e0853a53a449
fixed=e713768878b659e647f26678665d720bc68a128159fb36cfefbe20a262f10059

have() { sha256sum "$1" | cut -d' ' -f1; }
case $(have "$dst/$so" 2>/dev/null || true) in
  "$fixed") echo "ok   $dst already patched"; exit 0 ;;
esac
[ "$(have "$src/$so")" = "$stock" ] || { echo "FAIL $src/$so is not the stock build this patch is for"; exit 1; }
rm -rf "$dst.tmp"
trap 'rm -rf "$dst.tmp"' EXIT
cp -a "$src" "$dst.tmp"
chmod u+w "$dst.tmp/$so"
printf '\xed' | dd of="$dst.tmp/$so" bs=1 seek=$((0x13dd35)) conv=notrunc status=none
chmod --reference="$src/$so" "$dst.tmp/$so"
[ "$(have "$dst.tmp/$so")" = "$fixed" ] || { echo "FAIL patched win32u.so hash mismatch"; exit 1; }
rm -rf "$dst"
mv "$dst.tmp" "$dst"
echo "ok   $dst patched from $src"
