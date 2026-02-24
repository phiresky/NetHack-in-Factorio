#!/bin/bash
# Build NetHack 3.6.7 for the Factorio WASM interpreter.
#
# This script bootstraps the build:
#   1. Clone NetHack 3.6.7 (if not already present)
#   2. Build native 32-bit host tools (makedefs, lev_comp, dgn_comp)
#   3. Cross-compile to WASM and generate Lua modules (via Makefile)
#
# Prerequisites (Arch Linux):
#   pacman -S clang wasi-libc wasi-compiler-rt lib32-glibc lib32-gcc-libs
#            lib32-ncurses python
#
# Usage:
#   cd build && bash build_nethack.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NETHACK_DIR="$ROOT_DIR/NetHack"
NETHACK_TAG="NetHack-3.6.7_Released"
NETHACK_REPO="https://github.com/NetHack/NetHack.git"

# ================================================================
# Step 1: Clone NetHack
# ================================================================

if [ ! -d "$NETHACK_DIR" ]; then
    echo "=== Cloning NetHack at $NETHACK_TAG ==="
    git clone --depth 1 --branch "$NETHACK_TAG" "$NETHACK_REPO" "$NETHACK_DIR"
else
    echo "=== NetHack directory already exists, skipping clone ==="
fi

# ================================================================
# Step 2: Build native 32-bit host tools
# ================================================================

echo "=== Building host tools (makedefs, lev_comp, dgn_comp) ==="

# setup.sh generates Makefiles from the hints file
cd "$NETHACK_DIR/sys/unix"
bash setup.sh hints/linux-minimal

# Build with -m32 -std=gnu89 for 32-bit struct layout (matching WASM)
# and K&R C compatibility. Override CC on CLI so we don't need to patch
# the hints file — make CLI vars override Makefile vars.
cd "$NETHACK_DIR"
make CC="cc -m32 -std=gnu89" all

# ================================================================
# Step 3: Cross-compile and generate Lua modules
# ================================================================

echo "=== Cross-compiling to WASM and generating Lua modules ==="

cd "$SCRIPT_DIR"
make all

echo "=== Build complete ==="
