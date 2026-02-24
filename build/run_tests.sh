#!/bin/bash
# Run WASM interpreter tests
# Usage: ./build/run_tests.sh
#
# If wat2wasm (from wabt) is available, it will also compile .wat files
# from build/tests/*.wat to .wasm and include them in the test run.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/tests"

# Detect Lua interpreter
LUA=""
if command -v luajit &>/dev/null; then
    LUA="luajit"
elif command -v lua5.2 &>/dev/null; then
    LUA="lua5.2"
elif command -v lua &>/dev/null; then
    LUA="lua"
else
    echo "ERROR: No Lua interpreter found (tried luajit, lua5.2, lua)"
    exit 1
fi

echo "Using Lua: $LUA ($($LUA -v 2>&1 | head -1))"
echo ""

# Compile .wat files to .wasm if wat2wasm is available
if command -v wat2wasm &>/dev/null; then
    echo "wat2wasm found, compiling .wat files..."
    mkdir -p "$TEST_DIR"
    for wat_file in "$TEST_DIR"/*.wat; do
        [ -f "$wat_file" ] || continue
        wasm_file="${wat_file%.wat}.wasm"
        echo "  $wat_file -> $wasm_file"
        wat2wasm "$wat_file" -o "$wasm_file" 2>&1 || echo "  WARNING: failed to compile $wat_file"
    done
    echo ""
else
    echo "wat2wasm not found (install wabt to compile .wat test files)"
    echo "Running with hand-crafted test binaries only."
    echo ""
fi

# Run the test suite
cd "$PROJECT_DIR"
exec $LUA "$SCRIPT_DIR/test_wasm.lua"
