#!/bin/bash
# Build NetHack-in-Factorio from source.
#
# Full pipeline: clone NetHack -> host tools -> tilemap -> WASM -> sprites
#
# Usage:
#   ./build.sh              # full build
#   ./build.sh --wasm-only  # recompile WASM + regenerate Lua modules (via Makefile)
#   ./build.sh --sprites    # regenerate sprites only
#   ./build.sh --clean      # remove all generated files
#   ./build.sh --verify     # check all generated files exist
#
# Prerequisites (Arch Linux):
#   pacman -S clang wasi-libc wasi-compiler-rt binaryen \
#             lib32-glibc lib32-gcc-libs lib32-ncurses python python-pillow

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
NETHACK_DIR="$ROOT_DIR/NetHack"
NETHACK_TAG="NetHack-3.6.7_Released"
NETHACK_REPO="https://github.com/NetHack/NetHack.git"

# Generated files to verify
GENERATED_FILES=(
    build/nethack.wasm
    scripts/nethack_wasm.lua
    scripts/nethack_data.lua
    scripts/nethack_compiled.lua
    scripts/tile_config.lua
)
GENERATED_DIRS=(
    graphics/sheets
    graphics/tiles
)

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

step() { echo; bold "=== $1 ==="; }

die() { red "ERROR: $1"; exit 1; }

do_verify() {
    step "Verifying generated files"
    local ok=true
    for f in "${GENERATED_FILES[@]}"; do
        if [ -f "$ROOT_DIR/$f" ]; then
            local size
            size=$(stat -c%s "$ROOT_DIR/$f" 2>/dev/null || stat -f%z "$ROOT_DIR/$f" 2>/dev/null)
            printf "  %-40s %s\n" "$f" "$(green "OK") ($size bytes)"
        else
            printf "  %-40s %s\n" "$f" "$(red "MISSING")"
            ok=false
        fi
    done
    for d in "${GENERATED_DIRS[@]}"; do
        if [ -d "$ROOT_DIR/$d" ]; then
            local count
            count=$(find "$ROOT_DIR/$d" -name '*.png' | wc -l)
            printf "  %-40s %s\n" "$d/" "$(green "OK") ($count PNGs)"
        else
            printf "  %-40s %s\n" "$d/" "$(red "MISSING")"
            ok=false
        fi
    done
    echo
    $ok && green "All generated files present. Mod is ready to use." \
        || { red "Some files are missing. Run ./build.sh to generate them."; return 1; }
}

# ----------------------------------------------------------------
# Full build pipeline
# ----------------------------------------------------------------

do_full_build() {
    local start_time
    start_time=$(date +%s)

    # Step 1: Clone NetHack
    if [ ! -d "$NETHACK_DIR" ]; then
        step "Cloning NetHack at $NETHACK_TAG"
        git clone --depth 1 --branch "$NETHACK_TAG" "$NETHACK_REPO" "$NETHACK_DIR"
    else
        step "NetHack directory already exists, skipping clone"
    fi

    # Step 2: Build native 32-bit host tools
    step "Building host tools (makedefs, lev_comp, dgn_comp)"
    cd "$NETHACK_DIR/sys/unix"
    bash setup.sh hints/linux-minimal
    cd "$NETHACK_DIR"
    make CC="cc -m32 -std=gnu89" all

    # Step 3: Build tilemap to generate glyph2tile[]
    step "Building tilemap"
    cd "$NETHACK_DIR"
    cc -m32 -std=gnu89 -Iinclude -o util/tilemap \
        win/share/tilemap.c src/objects.o src/monst.o src/drawing.o
    cd "$NETHACK_DIR/util"
    ./tilemap

    # Step 4: Cross-compile to WASM and generate Lua modules
    step "Cross-compiling to WASM and generating Lua modules"
    make -C "$BUILD_DIR" all -j"$(nproc)"

    # Step 5: Convert tile art to Factorio sprites
    step "Converting tile art to sprites"
    python3 "$BUILD_DIR/convert_tiles.py" "$NETHACK_DIR"

    do_verify

    local elapsed=$(( $(date +%s) - start_time ))
    echo
    green "Full build completed in ${elapsed}s"
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: ./build.sh [COMMAND]

Commands:
  (none)        Full build: clone + host tools + tilemap + WASM + sprites
  --wasm-only   Recompile WASM and regenerate Lua modules only
  --sprites     Regenerate sprite sheets only
  --clean       Remove all generated files
  --verify      Check all generated files exist
  --help        Show this help

Prerequisites (Arch Linux):
  pacman -S clang wasi-libc wasi-compiler-rt binaryen \
            lib32-glibc lib32-gcc-libs lib32-ncurses python python-pillow
USAGE
}

case "${1:-}" in
    --clean)
        make -C "$BUILD_DIR" clean
        rm -f "$ROOT_DIR/scripts/tile_config.lua"
        rm -rf "$ROOT_DIR/graphics/sheets" "$ROOT_DIR/graphics/tiles"
        green "Clean complete"
        ;;
    --verify)
        do_verify
        ;;
    --wasm-only)
        [ -d "$NETHACK_DIR" ] || die "NetHack/ not found. Run ./build.sh first."
        make -C "$BUILD_DIR" all -j"$(nproc)"
        do_verify
        ;;
    --sprites)
        [ -d "$NETHACK_DIR" ] || die "NetHack/ not found. Run ./build.sh first."
        python3 "$BUILD_DIR/convert_tiles.py" "$NETHACK_DIR"
        do_verify
        ;;
    --help|-h)
        usage
        ;;
    "")
        do_full_build
        ;;
    *)
        die "Unknown option: $1. Use --help for usage."
        ;;
esac
