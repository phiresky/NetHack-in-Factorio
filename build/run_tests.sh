#!/bin/bash
# Full WASM test pipeline:
# 1. Compile .wat files to .wasm (if wat2wasm available)
# 2. Run unit tests
# 3. Clone the WebAssembly spec test suite (if needed)
# 4. Convert .wast files to .json + .wasm using wast2json
# 5. Run spec tests
#
# Usage: ./build/run_tests.sh [--unit-only] [--spec-only]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/tests"
SPEC_DIR="$TEST_DIR/spec"
TESTSUITE_DIR="$TEST_DIR/testsuite"

# Parse args
UNIT_ONLY=false
SPEC_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --unit-only) UNIT_ONLY=true ;;
        --spec-only) SPEC_ONLY=true ;;
    esac
done

# Which .wast files to convert and test
TESTS=(
    address block br call call_indirect conversions data endianness
    f32 f64 fac float_exprs float_literals float_misc forward
    i32 i64 if int_exprs int_literals left-to-right load local_get
    local_set loop memory_size nop return stack start store switch
    unreachable unwind
)

# Detect Lua interpreter (prefer lua5.2 for bit32 support)
LUA=""
if command -v lua5.2 &>/dev/null; then
    LUA="lua5.2"
elif command -v luajit &>/dev/null; then
    LUA="luajit"
elif command -v lua &>/dev/null; then
    # Verify it has bit32
    if lua -e 'assert(bit32)' 2>/dev/null; then
        LUA="lua"
    else
        echo "ERROR: system lua lacks bit32. Install lua5.2."
        exit 1
    fi
else
    echo "ERROR: No Lua interpreter found (tried lua5.2, luajit, lua)"
    exit 1
fi

echo "Using Lua: $LUA ($($LUA -v 2>&1 | head -1))"
echo ""

cd "$PROJECT_DIR"

# --- Unit Tests ---
if [ "$SPEC_ONLY" = false ]; then
    # Compile .wat files to .wasm if wat2wasm is available
    if command -v wat2wasm &>/dev/null; then
        echo "=== Compiling .wat test files ==="
        mkdir -p "$TEST_DIR"
        for wat_file in "$TEST_DIR"/*.wat; do
            [ -f "$wat_file" ] || continue
            wasm_file="${wat_file%.wat}.wasm"
            wat2wasm "$wat_file" -o "$wasm_file" 2>&1 || echo "  WARNING: failed to compile $wat_file"
        done
        echo ""
    fi

    echo "=== Running unit tests ==="
    $LUA "$SCRIPT_DIR/test_wasm.lua"
    echo ""

    if [ "$UNIT_ONLY" = true ]; then
        exit 0
    fi
fi

# --- Spec Tests ---

# Check for wast2json
if ! command -v wast2json &>/dev/null; then
    echo "ERROR: wast2json not found. Install wabt (WebAssembly Binary Toolkit):"
    echo "  Arch:   pacman -S wabt"
    echo "  Ubuntu: apt install wabt"
    echo "  macOS:  brew install wabt"
    exit 1
fi

# Clone spec test suite if not present
if [ ! -d "$TESTSUITE_DIR" ]; then
    echo "=== Cloning WebAssembly spec test suite ==="
    mkdir -p "$TEST_DIR"
    git clone --depth 1 https://github.com/ArtificialQualia/wasm-spec-testsuite.git "$TESTSUITE_DIR"
    echo ""
else
    echo "=== Spec test suite already present ==="
fi

# Convert .wast to .json + .wasm
echo "=== Converting .wast files ==="
mkdir -p "$SPEC_DIR"

converted=0
skipped=0
for test in "${TESTS[@]}"; do
    wast_file="$TESTSUITE_DIR/${test}.wast"
    json_file="$SPEC_DIR/${test}.json"
    if [ ! -f "$wast_file" ]; then
        echo "  SKIP: $test.wast not found"
        ((skipped++)) || true
        continue
    fi
    if [ "$json_file" -nt "$wast_file" ] 2>/dev/null; then
        ((skipped++)) || true
        continue
    fi
    if wast2json "$wast_file" -o "$json_file" 2>/dev/null; then
        ((converted++)) || true
    else
        echo "  WARN: wast2json failed for $test.wast"
        ((skipped++)) || true
    fi
done
echo "  Converted: $converted, Up-to-date/skipped: $skipped"
echo ""

# Run spec tests
echo "=== Running spec tests ==="
$LUA "$SCRIPT_DIR/run_spec_tests.lua" "$SPEC_DIR/"

echo ""
echo "Done."
