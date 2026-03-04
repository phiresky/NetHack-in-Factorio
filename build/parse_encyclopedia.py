#!/usr/bin/env python3
"""Parse NetHack data.base and generate encyclopedia Lua module.

Reads dat/data.base from the NetHack source and tile names from tile_config.lua,
matches tile names to encyclopedia entries, and generates scripts/encyclopedia.lua
as a static lookup table. This replaces the expensive runtime checkfile() WASM call
for long descriptions in the hover tooltip.
"""

import re
import sys


def parse_data_base(path):
    """Parse data.base into a list of (keys_list, description_text) tuples.

    Format:
    - Lines starting with '#' are comments, skipped.
    - Lines starting with non-whitespace are entry keys (one per line).
    - Lines starting with tab are description text (append to current entry).
    - '~' prefix on key means exclusion pattern, skipped.
    - '*' prefix/suffix on key means wildcard match.
    - Blank lines within descriptions are preserved.
    - A new entry begins when a key line appears after description lines.
    """
    entries = []
    current_keys = []
    current_desc = []
    in_desc = False

    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')

            # Comment lines
            if line.startswith('#'):
                continue

            # Description line (starts with tab)
            if line.startswith('\t'):
                current_desc.append(line[1:])  # strip leading tab
                in_desc = True
                continue

            # Blank line: if we're in a description, preserve it
            if not line.strip():
                if in_desc:
                    current_desc.append('')
                continue

            # Non-blank, non-tab, non-comment: this is a key line.
            # If we were in a description, the previous entry is complete.
            if in_desc and current_keys and current_desc:
                # Strip trailing blank lines from description
                while current_desc and current_desc[-1] == '':
                    current_desc.pop()
                entries.append((current_keys[:], '\n'.join(current_desc)))
                current_keys = []
                current_desc = []
                in_desc = False

            # Skip exclusion patterns
            if line.startswith('~'):
                continue

            current_keys.append(line.strip())

    # Flush last entry
    if current_keys and current_desc:
        while current_desc and current_desc[-1] == '':
            current_desc.pop()
        entries.append((current_keys, '\n'.join(current_desc)))

    return entries


def match_name(tile_name, entries):
    """Find matching entry for a tile name like 'giant-ant'.

    Tile names use hyphens; data.base keys use spaces. Matching is
    case-insensitive. Keys ending with '*' are prefix wildcards;
    keys starting with '*' are suffix wildcards.
    """
    search = tile_name.replace('-', ' ').lower()

    for keys, desc in entries:
        for key in keys:
            key_lower = key.lower()
            if key_lower.startswith('*') and key_lower.endswith('*'):
                # Both-ends wildcard: substring match
                if key_lower[1:-1] in search:
                    return desc
            elif key_lower.endswith('*'):
                if search.startswith(key_lower[:-1]):
                    return desc
            elif key_lower.startswith('*'):
                if search.endswith(key_lower[1:]):
                    return desc
            elif search == key_lower:
                return desc
    return None


def parse_tile_names(tile_config_path):
    """Extract tile names from tile_config.lua.

    The file contains arrays like:
      monster_names = { "giant-ant", "killer-bee", ... },
      object_names = { "arrow", "elven-arrow", ... },
      other_names = { "stone", "vertical-wall", ... },
    """
    tile_names = []
    with open(tile_config_path) as f:
        content = f.read()
    for match in re.finditer(r'"([^"]+)"', content):
        tile_names.append(match.group(1))
    return tile_names


def lua_escape(s):
    """Escape a string for use inside Lua double-quoted string literals."""
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\t', '\\t')
    return s


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <data.base> <tile_config.lua> <output.lua>",
              file=sys.stderr)
        sys.exit(1)

    data_base_path, tile_config_path, output_path = sys.argv[1:4]

    # Parse data.base
    entries = parse_data_base(data_base_path)
    print(f"Parsed {len(entries)} data.base entries")

    # Parse tile names from tile_config.lua
    tile_names = parse_tile_names(tile_config_path)
    print(f"Found {len(tile_names)} tile names in tile_config.lua")

    # Deduplicate tile names while preserving order
    seen = set()
    unique_names = []
    for name in tile_names:
        if name not in seen:
            seen.add(name)
            unique_names.append(name)

    # Match tile names to entries
    results = {}
    for name in unique_names:
        desc = match_name(name, entries)
        if desc:
            results[name] = desc

    # Write Lua module
    with open(output_path, 'w') as f:
        f.write('-- Generated by parse_encyclopedia.py - DO NOT EDIT\n')
        f.write('-- Encyclopedia lookup table: tile name -> long description\n')
        f.write(f'-- {len(results)} entries from {len(entries)} data.base entries\n')
        f.write('return {\n')
        for name in sorted(results):
            escaped = lua_escape(results[name])
            f.write(f'  ["{name}"] = "{escaped}",\n')
        f.write('}\n')

    print(f"Generated {output_path}: {len(results)} entries")


if __name__ == '__main__':
    main()
