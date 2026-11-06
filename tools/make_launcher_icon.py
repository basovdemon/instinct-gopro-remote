"""Generates resources/drawables/launcher_icon.png: a small outlined action camera, white on transparent.

Line art rather than a filled silhouette: a rounded body, the lens as a ring with a dot, the
shutter button on top. Hard pixels (alpha 0 or 255): the Instinct 3 display is 1-bit.

No dependencies (writes PNG via zlib). Size comes from the device's
compiler.json -> launcherIcon (instinct3solar45mm: 62x62).

    python tools/make_launcher_icon.py              # overwrites the icon in the repo
    python tools/make_launcher_icon.py other.png    # writes elsewhere
"""
import os
import struct
import sys
import zlib

# Relative to the repo root (this file's folder's parent), not to the current directory.
DEFAULT_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "resources", "drawables", "launcher_icon.png")

W = H = 62
STROKE = 2

# Body: 34 x 24, centred a little below the middle to leave room for the button.
BODY = (14, 22, 48, 46)       # left, top, right, bottom
CORNER = 5
LENS = (26, 34, 7.5)          # centre x, centre y, outer radius
BUTTON = (36, 19, 43, 22)     # sits on the body's top edge


def in_rounded_rect(x, y, left, top, right, bottom, radius):
    if not (left <= x <= right and top <= y <= bottom):
        return False
    # Distance from the nearest corner centre, only inside the corner squares.
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def inside(px, py):
    x, y = px + 0.5, py + 0.5
    left, top, right, bottom = BODY
    outline = in_rounded_rect(x, y, left, top, right, bottom, CORNER) and not in_rounded_rect(
        x, y, left + STROKE, top + STROKE, right - STROKE, bottom - STROKE, CORNER - STROKE)
    lx, ly, lr = LENS
    d = ((x - lx) ** 2 + (y - ly) ** 2) ** 0.5
    lens = lr - STROKE <= d <= lr or d <= 1.8
    bl, bt, br, bb = BUTTON
    button = bl <= x <= br and bt <= y <= bb
    return outline or lens or button


def main(path=DEFAULT_PATH):
    rows = b""
    for y in range(H):
        row = b"\x00"
        for x in range(W):
            row += b"\xff\xff\xff\xff" if inside(x, y) else b"\x00\x00\x00\x00"
        rows += row

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH)
