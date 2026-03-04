#!/usr/bin/env python3
"""Convert NetHack tile text files to Factorio-compatible sprite sheets and PNGs.

Parses win/share/{monsters,objects,other}.txt from the NetHack source,
generates:
  - graphics/sheets/nh-monsters.png   (sprite sheet)
  - graphics/sheets/nh-objects.png     (sprite sheet)
  - graphics/sheets/nh-other.png       (sprite sheet)
  - graphics/tiles/nh-{floor,corridor,void,water,lava,ice,grass}.png (ground tiles, 512x512)
  - scripts/tile_config.lua            (tile count constants)

Uses only Python stdlib (struct + zlib) — no PIL/Pillow required.
"""

import json
import os
import re
import struct
import sys
import zlib

SHEET_COLS = 32       # tiles per row in sprite sheets
TILE_SRC = 16         # source tile size (pixels)
TILE_DST = 32         # output tile size (2x upscale)
GROUND_SIZE = 512     # ground tile PNG size (Factorio material_background)


def sanitize_tile_name(name):
    """Convert a NetHack tile name to a valid Factorio entity ID fragment.

    e.g. "giant ant" -> "giant-ant", "runed arrow / elven arrow" -> "runed-arrow-elven-arrow"
    """
    s = name.lower()
    # Replace slashes, spaces, and other non-alphanumeric with hyphens
    s = re.sub(r'[^a-z0-9]+', '-', s)
    # Collapse multiple hyphens and strip leading/trailing
    s = re.sub(r'-+', '-', s).strip('-')
    return s


def make_unique_names(tiles):
    """Generate unique sanitized names for a list of tiles, suffixing duplicates."""
    seen = {}
    names = []
    for tile in tiles:
        base = sanitize_tile_name(tile["name"])
        if base in seen:
            seen[base] += 1
            names.append(f"{base}-{seen[base]}")
            # print to stderr
            print(f"WARNING: duplicate tile name '{tile['name']}' -> '{base}', renamed to '{base}-{seen[base]}'", file=sys.stderr)
        else:
            seen[base] = 1
            names.append(base)
    return names


# ================================================================
# PNG writer (same approach as gen_sprites.py)
# ================================================================

def write_png(path, width, height, pixels):
    """Write a minimal RGBA PNG. pixels = width*height*4 bytes."""
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = b""
    for y in range(height):
        raw += b"\x00"  # filter: None
        raw += pixels[y * width * 4 : (y + 1) * width * 4]
    compressed = zlib.compress(raw)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", compressed))
        f.write(chunk(b"IEND", b""))


# ================================================================
# Tile text parser
# ================================================================

def parse_palette(lines):
    """Parse color palette from header lines like 'A = (0, 0, 0)'."""
    palette = {}
    for line in lines:
        line = line.strip()
        m = re.match(r'^(.) = \((\d+),\s*(\d+),\s*(\d+)\)', line)
        if m:
            ch, r, g, b = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
            palette[ch] = (r, g, b)
    return palette


def parse_tile_file(filepath):
    """Parse a NetHack tile text file. Returns (palette, tiles_list).

    Each tile is a dict: {index, name, rows} where rows is a list of 16 strings.
    """
    with open(filepath, "r") as f:
        lines = f.readlines()

    # Parse palette from header (before first tile)
    palette_lines = []
    tile_start = 0
    for i, line in enumerate(lines):
        if line.startswith("# tile "):
            tile_start = i
            break
        palette_lines.append(line)

    palette = parse_palette(palette_lines)

    # Parse tiles
    tiles = []
    i = tile_start
    while i < len(lines):
        line = lines[i].strip()

        # Look for "# tile N (name)"
        m = re.match(r'^# tile (\d+) \((.+)\)', line)
        if m:
            tile_idx = int(m.group(1))
            tile_name = m.group(2)

            # Find the opening brace
            i += 1
            while i < len(lines) and lines[i].strip() != "{":
                i += 1
            i += 1  # skip the {

            # Read 16 rows
            rows = []
            while i < len(lines) and lines[i].strip() != "}":
                row = lines[i].strip()
                if len(row) >= TILE_SRC:
                    rows.append(row[:TILE_SRC])
                i += 1
            i += 1  # skip the }

            if len(rows) == TILE_SRC:
                tiles.append({"index": tile_idx, "name": tile_name, "rows": rows})
            continue

        i += 1

    return palette, tiles


# ================================================================
# Tile rendering
# ================================================================

def render_tile(palette, tile, transparent_bg=True):
    """Render a 16x16 tile to 32x32 RGBA pixels (2x nearest-neighbor upscale).

    If transparent_bg=True, the background char '.' is rendered transparent.
    Otherwise it uses the palette color for '.'.
    """
    bg_char = "."
    pixels = bytearray(TILE_DST * TILE_DST * 4)

    for row_idx, row in enumerate(tile["rows"]):
        for col_idx, ch in enumerate(row):
            if transparent_bg and ch == bg_char:
                r, g, b, a = 0, 0, 0, 0
            elif ch in palette:
                r, g, b = palette[ch]
                a = 255
            else:
                # Unknown char - render as magenta for debugging
                r, g, b, a = 255, 0, 255, 255

            pixel = struct.pack("BBBB", r, g, b, a)

            # 2x upscale: each source pixel becomes a 2x2 block
            for dy in range(2):
                for dx in range(2):
                    px = col_idx * 2 + dx
                    py = row_idx * 2 + dy
                    off = (py * TILE_DST + px) * 4
                    pixels[off:off + 4] = pixel

    return bytes(pixels)


def render_tile_opaque(palette, tile):
    """Render a tile with opaque background (for ground tiles)."""
    return render_tile(palette, tile, transparent_bg=False)


# ================================================================
# Sprite sheet generation
# ================================================================

def generate_sprite_sheet(palette, tiles, output_path, palette_overrides=None):
    """Generate a sprite sheet PNG from a list of tiles.

    Layout: SHEET_COLS tiles per row, each tile TILE_DST x TILE_DST pixels.
    palette_overrides: dict of {tile_index: {char: (r,g,b), ...}} to override
        palette entries for specific tiles (rendered opaque, no transparent bg).
    """
    n_tiles = len(tiles)
    n_cols = SHEET_COLS
    n_rows = (n_tiles + n_cols - 1) // n_cols
    sheet_w = n_cols * TILE_DST
    sheet_h = n_rows * TILE_DST

    # Initialize with transparent black
    sheet = bytearray(sheet_w * sheet_h * 4)

    for i, tile in enumerate(tiles):
        overrides = palette_overrides and palette_overrides.get(tile["index"])
        if overrides:
            pal = dict(palette)
            pal.update(overrides)
            tile_pixels = render_tile(pal, tile, transparent_bg=False)
        else:
            tile_pixels = render_tile(palette, tile, transparent_bg=True)
        col = i % n_cols
        row = i // n_cols
        ox = col * TILE_DST
        oy = row * TILE_DST

        # Copy tile pixels into sheet
        for ty in range(TILE_DST):
            src_off = ty * TILE_DST * 4
            dst_off = ((oy + ty) * sheet_w + ox) * 4
            sheet[dst_off:dst_off + TILE_DST * 4] = tile_pixels[src_off:src_off + TILE_DST * 4]

    write_png(output_path, sheet_w, sheet_h, bytes(sheet))
    print(f"  sheet: {output_path} ({n_tiles} tiles, {sheet_w}x{sheet_h})")
    return n_tiles


def generate_tile_icons(palette, tiles, names, output_dir, prefix):
    """Generate individual 32x32 PNGs for each tile (for Factorio icons)."""
    os.makedirs(output_dir, exist_ok=True)
    for i, tile in enumerate(tiles):
        pixels = render_tile(palette, tile, transparent_bg=True)
        write_png(os.path.join(output_dir, f"{prefix}{names[i]}.png"),
                  TILE_DST, TILE_DST, pixels)
    print(f"  icons: {output_dir} ({len(tiles)} icons, prefix={prefix})")


def generate_ground_tile(palette, tile, output_path):
    """Generate a 512x512 ground tile PNG by tiling a single opaque tile."""
    tile_pixels = render_tile_opaque(palette, tile)

    # Tile the 32x32 image into 512x512 (16x16 repetitions)
    reps = GROUND_SIZE // TILE_DST
    ground = bytearray(GROUND_SIZE * GROUND_SIZE * 4)

    for ty in range(reps):
        for tx in range(reps):
            ox = tx * TILE_DST
            oy = ty * TILE_DST
            for row in range(TILE_DST):
                src_off = row * TILE_DST * 4
                dst_off = ((oy + row) * GROUND_SIZE + ox) * 4
                ground[dst_off:dst_off + TILE_DST * 4] = tile_pixels[src_off:src_off + TILE_DST * 4]

    write_png(output_path, GROUND_SIZE, GROUND_SIZE, bytes(ground))
    print(f"  ground: {output_path}")


# ================================================================
# Main
# ================================================================

def find_tile_by_name(tiles, name_pattern):
    """Find the first tile whose name contains the pattern."""
    for tile in tiles:
        if name_pattern in tile["name"]:
            return tile
    return None


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <nethack-source-dir>")
        sys.exit(1)

    nethack_dir = sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    mod_root = os.path.dirname(script_dir)

    win_share = os.path.join(nethack_dir, "win", "share")
    sheets_dir = os.path.join(mod_root, "graphics", "sheets")
    tiles_dir = os.path.join(mod_root, "graphics", "tiles")
    scripts_dir = os.path.join(mod_root, "scripts")

    print("Converting NetHack tiles to Factorio sprites...")

    # Parse all three tile files
    mon_palette, mon_tiles = parse_tile_file(os.path.join(win_share, "monsters.txt"))
    obj_palette, obj_tiles = parse_tile_file(os.path.join(win_share, "objects.txt"))
    oth_palette, oth_tiles = parse_tile_file(os.path.join(win_share, "other.txt"))

    print(f"  Parsed: {len(mon_tiles)} monsters, {len(obj_tiles)} objects, {len(oth_tiles)} other")

    # Override misleading tile names from the source tile text files
    # Tile 0 in other.txt is S_stone (unexplored rock) but named "dark part of a room"
    # which collides with tile 20 (S_darkroom, the actual dark room floor).
    other_name_overrides = {0: "stone"}
    for tile in oth_tiles:
        if tile["index"] in other_name_overrides:
            tile["name"] = other_name_overrides[tile["index"]]

    # Generate unique sanitized names for each tile category
    mon_names = make_unique_names(mon_tiles)
    obj_names = make_unique_names(obj_tiles)
    oth_names = make_unique_names(oth_tiles)

    # Generate sprite sheets
    n_mon = generate_sprite_sheet(mon_palette, mon_tiles,
                                  os.path.join(sheets_dir, "nh-monsters.png"))
    n_obj = generate_sprite_sheet(obj_palette, obj_tiles,
                                  os.path.join(sheets_dir, "nh-objects.png"))
    # S_darkroom (tile 20): checkerboard of '.' (71,108,108) and 'A' (0,0,0)
    # looks bad at 2x — average both to a clean dark blue-gray
    avg = (35, 54, 54)
    oth_pal_overrides = {20: {".": avg, "A": avg}}
    n_oth = generate_sprite_sheet(oth_palette, oth_tiles,
                                  os.path.join(sheets_dir, "nh-other.png"),
                                  palette_overrides=oth_pal_overrides)

    # Generate individual icon PNGs for Factorio prototypes (items + entity icons)
    icons_base = os.path.join(mod_root, "graphics", "icons")
    generate_tile_icons(mon_palette, mon_tiles, mon_names,
                        os.path.join(icons_base, "monsters"), "nh-mon-")
    generate_tile_icons(obj_palette, obj_tiles, obj_names,
                        os.path.join(icons_base, "objects"), "nh-item-")
    generate_tile_icons(oth_palette, oth_tiles, oth_names,
                        os.path.join(icons_base, "other"), "nh-other-")

    # Generate ground tile PNGs from specific "other" tiles
    ground_mapping = {
        "nh-floor":     "floor of a room",
        "nh-corridor":  "corridor",         # plain "corridor" (not lit/engraving)
        "nh-water":     "water",
        "nh-lava":      "molten lava",
        "nh-ice":       "ice",
        "nh-grass":     "tree",
    }

    for tile_name, search_name in ground_mapping.items():
        tile = find_tile_by_name(oth_tiles, search_name)
        if tile:
            generate_ground_tile(oth_palette, tile,
                                 os.path.join(tiles_dir, f"{tile_name}.png"))
        else:
            print(f"  WARNING: could not find tile matching '{search_name}' for {tile_name}")

    # Void tile is solid black (fog of war / unexplored)
    void_buf = bytearray(GROUND_SIZE * GROUND_SIZE * 4)
    for i in range(GROUND_SIZE * GROUND_SIZE):
        void_buf[i * 4 + 3] = 255  # alpha
    void_path = os.path.join(tiles_dir, "nh-void.png")
    write_png(void_path, GROUND_SIZE, GROUND_SIZE, bytes(void_buf))
    print(f"  void: {void_path} (solid black)")

    # Generate wall/door collision info for entities.lua
    # Identify which "other" tile indices are walls and doors
    wall_indices = []
    door_closed_indices = []
    door_open_indices = []
    for tile in oth_tiles:
        name = tile["name"]
        idx = tile["index"]
        if "wall" in name and "drawbridge" not in name and "lava" not in name:
            wall_indices.append(idx)
        elif "closed door" in name or "closed drawbridge" in name:
            door_closed_indices.append(idx)
        elif "open door" in name or "open drawbridge" in name:
            door_open_indices.append(idx)

    # Generate JSON tile config for web-ui (if --web-json flag provided)
    tile_config_data = {
        "n_monsters": n_mon,
        "n_objects": n_obj,
        "n_other": n_oth,
        "sheet_cols": SHEET_COLS,
        "wall_indices": wall_indices,
        "door_closed_indices": door_closed_indices,
        "door_open_indices": door_open_indices,
        "monster_names": mon_names,
        "object_names": obj_names,
        "other_names": oth_names,
    }
    web_json_idx = None
    for i, arg in enumerate(sys.argv):
        if arg == "--web-json" and i + 1 < len(sys.argv):
            web_json_idx = i
            json_path = sys.argv[i + 1]
            os.makedirs(os.path.dirname(json_path) or ".", exist_ok=True)
            with open(json_path, "w") as jf:
                json.dump(tile_config_data, jf)
            print(f"  web config: {json_path}")

    # Generate scripts/tile_config.lua
    config_path = os.path.join(scripts_dir, "tile_config.lua")
    with open(config_path, "w") as f:
        f.write("-- Auto-generated by convert_tiles.py — do not edit\n")
        f.write("return {\n")
        f.write(f"  n_monsters = {n_mon},\n")
        f.write(f"  n_objects = {n_obj},\n")
        f.write(f"  n_other = {n_oth},\n")
        f.write(f"  sheet_cols = {SHEET_COLS},\n")
        f.write(f"  wall_indices = {{{', '.join(str(i) for i in wall_indices)}}},\n")
        f.write(f"  door_closed_indices = {{{', '.join(str(i) for i in door_closed_indices)}}},\n")
        f.write(f"  door_open_indices = {{{', '.join(str(i) for i in door_open_indices)}}},\n")

        # Emit name arrays (Lua 1-indexed)
        def write_name_array(varname, names):
            f.write(f"  {varname} = {{\n")
            for name in names:
                f.write(f'    "{name}",\n')
            f.write("  },\n")

        write_name_array("monster_names", mon_names)
        write_name_array("object_names", obj_names)
        write_name_array("other_names", oth_names)

        # Emit original (unsanitized) display names for localised_name in prototypes
        # Title-case names that are all-lowercase; preserve existing casing otherwise.
        _MINOR = {"a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or", "but", "with"}
        def _title_case(name):
            if name != name.lower():
                return name
            parts = name.split(" / ")
            result = []
            for part in parts:
                words = part.split()
                cased = []
                for j, w in enumerate(words):
                    if j == 0 or w not in _MINOR:
                        cased.append(w.capitalize())
                    else:
                        cased.append(w)
                result.append(" ".join(cased))
            return " / ".join(result)

        def write_display_names(varname, tiles):
            f.write(f"  {varname} = {{\n")
            for tile in tiles:
                escaped = _title_case(tile["name"]).replace("\\", "\\\\").replace('"', '\\"')
                f.write(f'    "{escaped}",\n')
            f.write("  },\n")

        write_display_names("monster_display_names", mon_tiles)
        write_display_names("object_display_names", obj_tiles)
        write_display_names("other_display_names", oth_tiles)

        f.write("}\n")
    print(f"  config: {config_path}")

    print("Done.")


if __name__ == "__main__":
    main()
