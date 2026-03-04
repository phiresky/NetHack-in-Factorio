#!/usr/bin/env python3
"""Parse NetHack data.base and generate encyclopedia locale + Lua normalizer.

Reads dat/data.base from the NetHack source and tile names from tile_config.lua,
matches tile names to encyclopedia entries, and generates:
  1. locale/en/encyclopedia.cfg — Factorio locale file with full descriptions
  2. scripts/encyclopedia.lua  — normalizer mapping tile names to locale keys

This replaces the expensive runtime checkfile() WASM call for long descriptions.
"""

import os
import re
import sys


def _unwrap_paragraphs(lines):
    """Join hard-wrapped prose lines into flowing paragraphs.

    data.base wraps at ~60 columns for terminal display. We unwrap by
    joining a line with the next if the next starts with a lowercase
    letter (indicating a mid-sentence continuation). Lines starting
    with uppercase, punctuation, or special formatting are kept separate
    (preserving poetry, dialogue, and citations).
    """
    result = []
    current = []

    def flush():
        if current:
            result.append(' '.join(current))
            current.clear()

    for line in lines:
        stripped = line.lstrip('\t ')
        # Blank line = paragraph break
        if not stripped:
            flush()
            result.append('')
            continue
        # Citation lines stay on their own line
        if stripped.startswith('[ ') or stripped == '[]':
            flush()
            result.append(line)
            continue
        # Extra indentation = intentional formatting
        if line.startswith('\t') or line.startswith('  '):
            flush()
            result.append(line)
            continue
        # If this line starts with a lowercase letter, it's a continuation
        # of the previous line (hard-wrapped prose). Join it.
        if current and stripped[0].islower():
            current.append(stripped)
        else:
            # New sentence/verse/paragraph — start fresh
            flush()
            current.append(stripped)

    flush()
    return '\n'.join(result)


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
                entries.append((current_keys[:], _unwrap_paragraphs(current_desc)))
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
        entries.append((current_keys, _unwrap_paragraphs(current_desc)))

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


def format_rich_text(desc):
    """Convert NetHack data.base inline formatting to Factorio rich text.

    Patterns:
    - _text_ → [font=default-semibold]text[/font]  (italic emphasis → bold)
    - \\t[ Source, by Author ] → [color=#888888][ Source ][/color]  (citations gray)
    """
    # First pass: join multi-line citations.
    # Citations start with \t[ and end with ] but may span lines.
    lines = desc.split('\n')
    merged = []
    in_citation = False
    for line in lines:
        stripped = line.lstrip('\t ')
        if not in_citation and stripped.startswith('[ '):
            if stripped.endswith(' ]'):
                merged.append(stripped)
            else:
                in_citation = True
                citation_buf = stripped
        elif in_citation:
            citation_buf += ' ' + stripped
            if stripped.endswith(' ]'):
                in_citation = False
                merged.append(citation_buf)
        else:
            merged.append(line)
    if in_citation:
        merged.append(citation_buf)

    # Second pass: apply formatting
    result = []
    for line in merged:
        stripped = line.lstrip('\t ')
        if stripped.startswith('[ ') and stripped.endswith(' ]'):
            line = '[color=#888888]' + stripped + '[/color]'
        else:
            # _text_ → bold (but not __dunder__ or ___ triple)
            line = re.sub(
                r'(?<![_\\])_([^_\n]+?)_(?!_)',
                r'[font=default-semibold]\1[/font]',
                line,
            )
        result.append(line)
    return '\n'.join(result)


def cfg_escape(s):
    """Escape a string for use in a Factorio .cfg locale value.

    .cfg values are single-line; newlines become literal \\n.
    """
    return s.replace('\\', '\\\\').replace('\n', '\\n')


def lua_escape(s):
    """Escape a string for use inside Lua double-quoted string literals."""
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    return s


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <data.base> <tile_config.lua> <output_dir>",
              file=sys.stderr)
        print(f"  Generates <output_dir>/scripts/encyclopedia.lua and "
              f"<output_dir>/locale/en/encyclopedia.cfg", file=sys.stderr)
        sys.exit(1)

    data_base_path, tile_config_path, output_dir = sys.argv[1:4]

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

    # Match tile names to entries, applying rich text formatting
    results = {}  # tile_name -> description text
    for name in unique_names:
        desc = match_name(name, entries)
        if desc:
            results[name] = format_rich_text(desc)

    # Deduplicate: group tile names by their description text.
    # Pick the first tile name (alphabetically) as the canonical locale key.
    desc_to_canonical = {}  # description text -> canonical tile name (locale key)
    for name in sorted(results):
        desc = results[name]
        if desc not in desc_to_canonical:
            desc_to_canonical[desc] = name

    # Build normalizer: tile_name -> canonical locale key
    normalizer = {}  # tile_name -> canonical_key
    for name in sorted(results):
        normalizer[name] = desc_to_canonical[results[name]]

    n_total = len(normalizer)
    n_unique = len(desc_to_canonical)

    # Write locale .cfg file
    locale_dir = os.path.join(output_dir, "locale", "en")
    os.makedirs(locale_dir, exist_ok=True)
    locale_path = os.path.join(locale_dir, "encyclopedia.cfg")
    with open(locale_path, 'w') as f:
        f.write("# Generated by parse_encyclopedia.py - DO NOT EDIT\n")
        f.write("[nh-encyclopedia]\n")
        for canonical in sorted(desc_to_canonical, key=lambda d: desc_to_canonical[d]):
            key = desc_to_canonical[canonical]
            f.write(f"{key}={cfg_escape(canonical)}\n")
    print(f"Generated {locale_path}: {n_unique} locale entries")

    # Write Lua normalizer module
    lua_path = os.path.join(output_dir, "scripts", "encyclopedia.lua")
    with open(lua_path, 'w') as f:
        f.write('-- Generated by parse_encyclopedia.py - DO NOT EDIT\n')
        f.write(f'-- {n_total} tile entries mapping to {n_unique} unique locale keys\n')
        f.write('local L = {\n')
        for name in sorted(normalizer):
            key = normalizer[name]
            if name == key:
                # Self-referencing: tile name IS the locale key
                f.write(f'  ["{lua_escape(name)}"] = true,\n')
            else:
                f.write(f'  ["{lua_escape(name)}"] = "{lua_escape(key)}",\n')
        f.write('}\n')
        f.write('return setmetatable({}, {__index = function(_, k)\n')
        f.write('  local v = L[k]\n')
        f.write('  if v == nil then return nil end\n')
        f.write('  local key = v == true and k or v\n')
        f.write('  return {"nh-encyclopedia." .. key}\n')
        f.write('end})\n')

    print(f"Generated {lua_path}: {n_total} entries, {n_unique} unique descriptions")


if __name__ == '__main__':
    main()
