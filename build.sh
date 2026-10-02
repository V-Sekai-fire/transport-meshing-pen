#!/usr/bin/env bash
# Build the guest ELFs (curvenet, lasso, probes, ggml_test, dress_on) for the
# RISC-V sandbox and drop them at this project's root. The stage code is in
# sibling checkouts of the goal manifest.
#
#   ./build.sh                # configure (once) + build
#   RISCV64_SYSROOT=... ./build.sh
#   GGML_EMIT=1 ./build.sh    # also check kernels/ggml against a fresh Lean emission
#
# Needs: cmake, ninja, a clang++ with a riscv64 target (auto-located if the
# bare clang++ is mingw-only), and the riscv64 glibc sysroot from the org's
# mujoco demo (third_party/riscv64-sysroot: toolchain.cmake + sysroot/). The
# sysroot is 150 MB and is not vendored here; point RISCV64_SYSROOT at it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSROOT="${RISCV64_SYSROOT:-/c/contract-manifest/3-interactor/mujoco-sandbox-demo/third_party/riscv64-sysroot}"
BUILD="${BUILD_DIR:-$HERE/build}"
# The stage code is in sibling checkouts of the goal manifest.
WEFT="${WEFT_ROOT:-$(cd "$HERE/../.." && pwd)}"
RUNTIME="$WEFT/2-contract/guest-runtime"

if [ ! -f "$SYSROOT/toolchain.cmake" ]; then
	echo "error: no toolchain.cmake under RISCV64_SYSROOT=$SYSROOT" >&2
	exit 1
fi

# The toolchain file invokes a bare clang++, so a riscv64-capable one must
# resolve first on PATH.
has_riscv() { "$1" --print-targets 2>/dev/null | grep -qi riscv64; }
if ! { command -v clang++ >/dev/null 2>&1 && has_riscv clang++; }; then
	FOUND=""
	for c in "$HOME/scoop/apps/llvm/current/bin/clang++" "/c/Program Files/LLVM/bin/clang++"; do
		if [ -x "$c" ] && has_riscv "$c"; then FOUND="$c"; break; fi
	done
	if [ -z "$FOUND" ]; then
		echo "error: no clang++ with a riscv64 target found (a mingw-only clang will not do)" >&2
		exit 1
	fi
	export PATH="$(dirname "$FOUND"):$PATH"
fi

NINJA="$(command -v ninja || true)"
[ -n "$NINJA" ] || NINJA="$HOME/.pixi/bin/ninja.exe"
[ -x "$NINJA" ] || { echo "error: ninja not found" >&2; exit 1; }

# No V extension: rv64gc plus the bit-manipulation extensions. Ubuntu clang
# 18's vector code traps on the Linux addon (AGENTS.md facts), and the ELF
# does not need it.
# CMake wants the toolchain path in its own spelling.
TOOLCHAIN="$(cygpath -m "$SYSROOT/toolchain.cmake" 2>/dev/null || echo "$SYSROOT/toolchain.cmake")"

# The Gate 0F probe kernels; PROBES_EMIT=1 re-emits them from
# lean/ and fails if they differ from the committed kernels/probes/slang/.
if [ "${PROBES_EMIT:-0}" = 1 ]; then
	BUILD_DIR="$BUILD" bash "$RUNTIME/kernels/probes/gen.sh"
else
	BUILD_DIR="$BUILD" bash "$RUNTIME/kernels/probes/gen.sh" --no-emit
fi

# The ggml-rd kernels (Cut 3), same pattern: GGML_EMIT=1 re-emits them from
# lean/ and fails if they differ from the committed kernels/ggml/slang/ (an
# op family writes them with kernels/ggml/gen.sh --update).
if [ "${GGML_EMIT:-0}" = 1 ]; then
	BUILD_DIR="$BUILD" bash "$WEFT/2-contract/ggml-rd/kernels/ggml/gen.sh"
else
	BUILD_DIR="$BUILD" bash "$WEFT/2-contract/ggml-rd/kernels/ggml/gen.sh" --no-emit
fi

# A Linux slangc writes the cpp emits with an absolute include of its prelude
# where the reference inlines it; put the inline form back (byte-identical to
# the committed emits, so nothing churns).
EMIT_REPOS=(2-contract/ggml-rd 3-interactor/curvenet)
python3 "$RUNTIME/tools/inline_prelude.py" "${EMIT_REPOS[@]/#/$WEFT/}"

if [ ! -f "$BUILD/build.ninja" ]; then
	cmake -S "$HERE" -B "$BUILD" -G Ninja \
		-DWEFT_ROOT="$WEFT" \
		-DCMAKE_MAKE_PROGRAM="$NINJA" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		${COMPILER_LAUNCHER:+-DCMAKE_C_COMPILER_LAUNCHER="$COMPILER_LAUNCHER" -DCMAKE_CXX_COMPILER_LAUNCHER="$COMPILER_LAUNCHER"} \
		-DSANDBOX_RISCV_EXT_V=OFF \
		-DDOUBLE_PRECISION=ON
fi
# BUILD_TARGETS (space-separated) limits the build, e.g. to one ELF.
# shellcheck disable=SC2086
cmake --build "$BUILD" ${BUILD_TARGETS:+--target $BUILD_TARGETS} -- -j "${BUILD_JOBS:-8}"
ls -la "$HERE/dress_on.elf" "$HERE/curvenet.elf" "$HERE/probes.elf" \
	"$HERE/ggml_test.elf" "$HERE/lasso.elf"
ls -la "$HERE/usd.elf" 2>/dev/null && sha256sum "$HERE/usd.elf" || echo "usd.elf: not built (no OpenUSD riscv64 build at USD_RV64_DIR)"
