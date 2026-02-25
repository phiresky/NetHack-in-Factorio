#!/usr/bin/env python3
"""Convert NetHack Qt XPM icons to Factorio-compatible PNGs.

Parses qt_xpms.h from the NetHack source and generates PNG icons
for use in Factorio's rich text GUI system.

Output: graphics/icons/nh-icon-*.png
Uses raw struct+zlib (no PIL required).
"""

import os
import re
import struct
import sys
import zlib

SCRIPT_DIR = os.path.dirname(__file__)
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(ROOT_DIR, "graphics", "icons")

# Map XPM variable names to our icon names
XPM_TO_ICON = {
    "str_xpm":       "str",
    "dex_xpm":       "dex",
    "cns_xpm":       "con",
    "int_xpm":       "int",
    "wis_xpm":       "wis",
    "cha_xpm":       "cha",
    "lawful_xpm":    "lawful",
    "neutral_xpm":   "neutral",
    "chaotic_xpm":   "chaotic",
    "hungry_xpm":    "hungry",
    "satiated_xpm":  "satiated",
    "confused_xpm":  "confused",
    "blind_xpm":     "blind",
    "stunned_xpm":   "stunned",
    "hallu_xpm":     "hallu",
    "sick_fp_xpm":   "sick-fp",
    "sick_il_xpm":   "sick-il",
    "slt_enc_xpm":   "enc-slt",
    "mod_enc_xpm":   "enc-mod",
    "hvy_enc_xpm":   "enc-hvy",
    "ext_enc_xpm":   "enc-ext",
    "ovr_enc_xpm":   "enc-ovr",
    "pet_mark_xpm":  "pet-mark",
    "pile_mark_xpm": "pile-mark",
    # Toolbar icons (from qt4main.cpp)
    "again_xpm":     "tb-again",
    "get_xpm":       "tb-get",
    "kick_xpm":      "tb-kick",
    "throw_xpm":     "tb-throw",
    "fire_xpm":      "tb-fire",
    "drop_xpm":      "tb-drop",
    "eat_xpm":       "tb-eat",
    "rest_xpm":      "tb-rest",
}


def write_png(filename, pixels, width, height):
    """Write RGBA pixel data as a PNG file."""

    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))

    raw = b""
    for y in range(height):
        raw += b"\x00"  # filter: none
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw += struct.pack("BBBB", r, g, b, a)

    idat = chunk(b"IDAT", zlib.compress(raw))
    iend = chunk(b"IEND", b"")

    path = os.path.join(OUT_DIR, filename)
    with open(path, "wb") as f:
        f.write(sig + ihdr + idat + iend)


def parse_color(color_str):
    """Parse an XPM color string to (R, G, B, A) tuple."""
    color_str = color_str.strip()
    if color_str.lower() == "none":
        return (0, 0, 0, 0)
    if color_str.startswith("#"):
        hex_str = color_str[1:]
        if len(hex_str) == 12:
            # 48-bit: 4 hex digits per channel (take top 8 bits)
            r = int(hex_str[0:4], 16) >> 8
            g = int(hex_str[4:8], 16) >> 8
            b = int(hex_str[8:12], 16) >> 8
            return (r, g, b, 255)
        elif len(hex_str) == 6:
            r = int(hex_str[0:2], 16)
            g = int(hex_str[2:4], 16)
            b = int(hex_str[4:6], 16)
            return (r, g, b, 255)
        elif len(hex_str) == 3:
            r = int(hex_str[0], 16) * 17
            g = int(hex_str[1], 16) * 17
            b = int(hex_str[2], 16) * 17
            return (r, g, b, 255)
    # Named colors (common in XPM)
    named = {
        "black": (0, 0, 0, 255),
        "white": (255, 255, 255, 255),
        "red": (255, 0, 0, 255),
        "green": (0, 255, 0, 255),
        "blue": (0, 0, 255, 255),
        "gray": (128, 128, 128, 255),
        "grey": (128, 128, 128, 255),
    }
    if color_str.lower() in named:
        return named[color_str.lower()]
    print(f"  Warning: unknown color '{color_str}', using magenta")
    return (255, 0, 255, 255)


def parse_xpm_data(lines):
    """Parse XPM string data into (width, height, pixels)."""
    # First line: "width height ncolors chars_per_pixel"
    header = lines[0].strip('"')
    parts = header.split()
    width = int(parts[0])
    height = int(parts[1])
    ncolors = int(parts[2])
    cpp = int(parts[3])

    # Parse color table
    colors = {}
    for i in range(1, ncolors + 1):
        line = lines[i].strip('"')
        key = line[:cpp]
        # Find "c <color>" in the rest
        rest = line[cpp:]
        m = re.search(r'\bc\s+(.+?)(?:\s+[a-z]\s|$)', rest)
        if m:
            colors[key] = parse_color(m.group(1))
        else:
            # Fallback: just take everything after "c "
            m2 = re.search(r'\bc\s+(\S+)', rest)
            if m2:
                colors[key] = parse_color(m2.group(1))
            else:
                colors[key] = (255, 0, 255, 255)

    # Parse pixel data
    pixels = []
    for i in range(ncolors + 1, ncolors + 1 + height):
        line = lines[i].strip('"')
        for x in range(0, width * cpp, cpp):
            key = line[x:x + cpp]
            pixels.append(colors.get(key, (255, 0, 255, 255)))

    return width, height, pixels


def parse_xpms_header(filepath):
    """Parse qt_xpms.h and extract all XPM icon data."""
    with open(filepath, "r") as f:
        content = f.read()

    icons = {}
    # Find each XPM array
    pattern = r'static\s+const\s+char\s+\*\s*(\w+)\[\]\s*=\s*\{([^}]+)\}'
    for m in re.finditer(pattern, content, re.DOTALL):
        var_name = m.group(1)
        body = m.group(2)

        # Extract quoted strings
        strings = re.findall(r'"([^"]*)"', body)
        if not strings:
            continue

        icon_name = XPM_TO_ICON.get(var_name)
        if icon_name is None:
            continue  # Skip unmapped icons

        try:
            width, height, pixels = parse_xpm_data(strings)
            icons[icon_name] = (width, height, pixels)
        except Exception as e:
            print(f"  Warning: failed to parse {var_name}: {e}")

    return icons


def main():
    # Find NetHack source
    if len(sys.argv) > 1:
        nh_dir = sys.argv[1]
    else:
        nh_dir = os.path.join(ROOT_DIR, "NetHack")

    xpms_path = os.path.join(nh_dir, "include", "qt_xpms.h")
    qt4main_path = os.path.join(nh_dir, "win", "Qt4", "qt4main.cpp")
    if not os.path.exists(xpms_path):
        print(f"Error: {xpms_path} not found. Run ./build.sh first to clone NetHack.")
        sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)
    print("Parsing Qt XPM icons...")
    icons = parse_xpms_header(xpms_path)

    if os.path.exists(qt4main_path):
        print("Parsing toolbar XPM icons...")
        toolbar_icons = parse_xpms_header(qt4main_path)
        icons.update(toolbar_icons)

    print(f"Converting {len(icons)} icons to PNG...")
    for name, (width, height, pixels) in sorted(icons.items()):
        filename = f"nh-icon-{name}.png"
        write_png(filename, pixels, width, height)
        print(f"  {filename} ({width}x{height})")

    print("Done.")


if __name__ == "__main__":
    main()
