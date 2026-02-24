#!/usr/bin/env python3
"""Generate placeholder sprite PNGs for the NetHack-Factorio mod.

Uses only the Python stdlib (struct + zlib) to write minimal valid PNGs.
No PIL/Pillow required.
"""

import os
import struct
import zlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MOD_ROOT = os.path.dirname(SCRIPT_DIR)
GFX_TILES = os.path.join(MOD_ROOT, "graphics", "tiles")
GFX_ENTITIES = os.path.join(MOD_ROOT, "graphics", "entities")


def write_png(path: str, width: int, height: int, pixels: bytes) -> None:
    """Write a minimal RGBA PNG file.

    `pixels` must be width*height*4 bytes (RGBA, row-major).
    """
    def chunk(chunk_type: bytes, data: bytes) -> bytes:
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    header = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    raw_rows = b""
    for y in range(height):
        raw_rows += b"\x00"  # filter byte: None
        raw_rows += pixels[y * width * 4 : (y + 1) * width * 4]
    compressed = zlib.compress(raw_rows)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(header)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", compressed))
        f.write(chunk(b"IEND", b""))


def solid_square(r: int, g: int, b: int, a: int = 255, size: int = 32) -> bytes:
    """Return size*size RGBA pixels of a solid color."""
    pixel = struct.pack("BBBB", r, g, b, a)
    return pixel * (size * size)


def letter_on_bg(letter: str, fg: tuple, bg: tuple, size: int = 32) -> bytes:
    """Render a letter as a simple 5x7 bitmap font centered on a colored background.

    Returns size*size*4 RGBA bytes.
    """
    # Minimal 5x7 bitmap font for A-Z and a-z
    # Each glyph is 5 columns x 7 rows, stored as 7 bytes (each byte = 5 bits, MSB = left)
    font_upper = {
        'A': [0x04, 0x0A, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        'D': [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
        'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        'G': [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
        'H': [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'I': [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        'J': [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
        'K': [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L': [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        'M': [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N': [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
        'O': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'P': [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        'Q': [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        'R': [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        'S': [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E],
        'T': [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U': [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'V': [0x11, 0x11, 0x11, 0x11, 0x0A, 0x0A, 0x04],
        'W': [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
        'X': [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        'Y': [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        'Z': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
    }
    # Lowercase: use uppercase bitmaps with a small tweak (shift down by 1 row)
    font_lower = {}
    for ch in "abcdefghijklmnopqrstuvwxyz":
        upper = ch.upper()
        if upper in font_upper:
            # Lowercase rendered slightly smaller - just reuse upper for now
            font_lower[ch] = font_upper[upper]

    font = {}
    font.update(font_upper)
    font.update(font_lower)

    # Special symbols
    font['@'] = [0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E]  # @ sign
    font['-'] = [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00]
    font['|'] = [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]
    font['+'] = [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00]
    font['#'] = [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A]
    font['>'] = [0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10]
    font['<'] = [0x01, 0x02, 0x04, 0x08, 0x04, 0x02, 0x01]
    font['*'] = [0x00, 0x04, 0x15, 0x0E, 0x15, 0x04, 0x00]
    font[')'] = [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08]
    font['('] = [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02]
    font['['] = [0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E]
    font['/'] = [0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10]
    font['%'] = [0x11, 0x01, 0x02, 0x04, 0x08, 0x10, 0x11]
    font['!'] = [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04]
    font['?'] = [0x0E, 0x11, 0x01, 0x06, 0x04, 0x00, 0x04]
    font['='] = [0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00]
    font['.'] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04]

    glyph = font.get(letter, font_upper.get('?', [0]*7))

    # Scale: each font pixel = 3x3 actual pixels, giving 15x21 centered in 32x32
    scale = 3
    gw, gh = 5 * scale, 7 * scale  # 15, 21
    ox = (size - gw) // 2
    oy = (size - gh) // 2

    fg_bytes = struct.pack("BBBB", fg[0], fg[1], fg[2], 255)
    bg_bytes = struct.pack("BBBB", bg[0], bg[1], bg[2], bg[3] if len(bg) > 3 else 255)

    buf = bytearray(bg_bytes * (size * size))
    for row in range(7):
        for col in range(5):
            if glyph[row] & (0x10 >> col):
                for sy in range(scale):
                    for sx in range(scale):
                        px = ox + col * scale + sx
                        py = oy + row * scale + sy
                        if 0 <= px < size and 0 <= py < size:
                            off = (py * size + px) * 4
                            buf[off:off+4] = fg_bytes
    return bytes(buf)


def generate_tiles():
    """Generate solid-color tile sprites."""
    tiles = {
        "nh-floor":    (166, 153, 128),
        "nh-corridor": (115, 102,  89),
        "nh-void":     ( 38,  38,  38),
        "nh-lava":     (230,  77,  26),
        "nh-water":    ( 51,  77, 204),
        "nh-ice":      (153, 230, 242),
        "nh-grass":    ( 77, 153,  51),
    }
    for name, (r, g, b) in tiles.items():
        path = os.path.join(GFX_TILES, f"{name}.png")
        write_png(path, 32, 32, solid_square(r, g, b))
        print(f"  tile: {path}")


def generate_entities():
    """Generate entity sprites: walls, monsters, items, etc."""
    # Walls
    wall_color = (128, 128, 128)
    write_png(
        os.path.join(GFX_ENTITIES, "nh-wall-h.png"), 32, 32,
        letter_on_bg('-', (200, 200, 200), wall_color)
    )
    write_png(
        os.path.join(GFX_ENTITIES, "nh-wall-v.png"), 32, 32,
        letter_on_bg('|', (200, 200, 200), wall_color)
    )

    # Doors
    door_color = (139, 90, 43)
    write_png(
        os.path.join(GFX_ENTITIES, "nh-door-closed.png"), 32, 32,
        letter_on_bg('+', (220, 180, 100), door_color)
    )
    write_png(
        os.path.join(GFX_ENTITIES, "nh-door-open.png"), 32, 32,
        letter_on_bg('.', (220, 180, 100), door_color)
    )

    # Monster letters: a-z and A-Z (white on dark transparent background)
    mon_bg = (0, 0, 0, 0)  # transparent
    mon_fg = (255, 255, 255)
    for ch in "abcdefghijklmnopqrstuvwxyz":
        write_png(
            os.path.join(GFX_ENTITIES, f"nh-mon-{ch}.png"), 32, 32,
            letter_on_bg(ch, mon_fg, mon_bg)
        )
    for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        write_png(
            os.path.join(GFX_ENTITIES, f"nh-mon-upper-{ch}.png"), 32, 32,
            letter_on_bg(ch, mon_fg, mon_bg)
        )

    # Generic item
    write_png(
        os.path.join(GFX_ENTITIES, "nh-item.png"), 32, 32,
        letter_on_bg('*', (255, 215, 0), (0, 0, 0, 0))
    )

    # Stairs
    write_png(
        os.path.join(GFX_ENTITIES, "nh-stairs-up.png"), 32, 32,
        letter_on_bg('<', (255, 255, 255), (0, 0, 0, 0))
    )
    write_png(
        os.path.join(GFX_ENTITIES, "nh-stairs-down.png"), 32, 32,
        letter_on_bg('>', (255, 255, 255), (0, 0, 0, 0))
    )

    # Player marker (@ sign)
    write_png(
        os.path.join(GFX_ENTITIES, "nh-player-marker.png"), 32, 32,
        letter_on_bg('@', (255, 255, 255), (0, 0, 0, 0))
    )

    print(f"  entities: {GFX_ENTITIES}/")


if __name__ == "__main__":
    print("Generating NetHack-Factorio placeholder sprites...")
    generate_tiles()
    generate_entities()
    print("Done.")
