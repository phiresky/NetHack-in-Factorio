#!/usr/bin/env python3
"""Convert a .wasm binary to a Lua module with embedded byte data.

The output is a Lua module that returns a table with:
  - M.size: the byte count of the WASM binary
  - M.data: the raw WASM bytes as a Lua string

Factorio's Lua 5.2 supports hex escapes (backslash-xNN) in string literals.
We split the data into chunks to avoid excessively long lines.
"""

import sys
import os


def wasm_to_lua(wasm_path, lua_path):
    with open(wasm_path, 'rb') as f:
        data = f.read()

    size = len(data)
    print(f"Converting {wasm_path} ({size} bytes) -> {lua_path}")

    with open(lua_path, 'w') as f:
        f.write('-- Auto-generated from %s\n' % os.path.basename(wasm_path))
        f.write('-- DO NOT EDIT - regenerate with wasm_to_lua.py\n')
        f.write('local M = {}\n\n')
        f.write('M.size = %d\n\n' % size)

        # Write as table of string chunks, joined with table.concat.
        # Avoids Lua's 200 C-level nesting limit for .. chains.
        CHUNK = 4096
        f.write('local _t = {}\n')
        idx = 0
        for i in range(0, size, CHUNK):
            chunk = data[i:i + CHUNK]
            hex_str = ''.join('\\x%02x' % b for b in chunk)
            idx += 1
            f.write('_t[%d] = "%s"\n' % (idx, hex_str))

        f.write('M.data = table.concat(_t)\n')
        f.write('_t = nil\n')
        f.write('\nreturn M\n')

    print(f"Done. Lua module written ({os.path.getsize(lua_path)} bytes)")


def main():
    if len(sys.argv) != 3:
        print("Usage: wasm_to_lua.py <input.wasm> <output.lua>",
              file=sys.stderr)
        sys.exit(1)

    wasm_path = sys.argv[1]
    lua_path = sys.argv[2]

    if not os.path.exists(wasm_path):
        print(f"Error: {wasm_path} not found", file=sys.stderr)
        sys.exit(1)

    # Ensure output directory exists
    out_dir = os.path.dirname(lua_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    wasm_to_lua(wasm_path, lua_path)


if __name__ == '__main__':
    main()
