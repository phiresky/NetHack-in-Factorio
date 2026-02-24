#!/usr/bin/env python3
"""Embed NetHack data files into a Lua module for the virtual filesystem.

The output Lua module returns a table mapping filenames to file contents.
Text files use Lua long strings ([=[...]=]); binary files use hex escapes.
"""

import os
import sys
import glob


def find_long_string_level(content):
    """Find the minimum '=' level for a Lua long string that won't conflict."""
    level = 0
    while level < 10:
        closing = ']' + '=' * level + ']'
        if closing not in content:
            return level
        level += 1
    return level


def is_text_file(data):
    """Check if file data is likely text (no null bytes, mostly printable)."""
    if b'\x00' in data:
        return False
    try:
        data.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def embed_data(dat_dir, output_path):
    files = {}
    for filepath in sorted(glob.glob(os.path.join(dat_dir, '*'))):
        if not os.path.isfile(filepath):
            continue
        filename = os.path.basename(filepath)
        # Skip build-system files
        if filename in ('GENFILES', 'Makefile', 'gitignore'):
            continue
        with open(filepath, 'rb') as f:
            data = f.read()
        files[filename] = data

    with open(output_path, 'w') as f:
        f.write('-- Auto-generated NetHack data files\n')
        f.write('-- DO NOT EDIT - regenerate with embed_data.py\n')
        f.write('local M = {}\n\n')

        for filename, data in sorted(files.items()):
            if is_text_file(data):
                content = data.decode('utf-8')
                level = find_long_string_level(content)
                eq = '=' * level
                f.write('M["%s"] = [%s[%s]%s]\n\n' % (filename, eq, content, eq))
            else:
                # Binary file: use hex string chunks
                hex_str = ''.join('\\x%02x' % b for b in data)
                f.write('M["%s"] = "%s"\n\n' % (filename, hex_str))

        f.write('return M\n')

    file_count = len(files)
    total_bytes = sum(len(d) for d in files.values())
    output_size = os.path.getsize(output_path)
    print(f"Embedded {file_count} files ({total_bytes} bytes) -> {output_path} ({output_size} bytes)")


def main():
    if len(sys.argv) != 3:
        print("Usage: embed_data.py <dat_dir> <output.lua>", file=sys.stderr)
        sys.exit(1)

    dat_dir = sys.argv[1]
    output_path = sys.argv[2]

    if not os.path.isdir(dat_dir):
        print(f"Error: {dat_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    out_dir = os.path.dirname(output_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    embed_data(dat_dir, output_path)


if __name__ == '__main__':
    main()
