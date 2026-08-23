#!/usr/bin/env python3
"""Paints gridlock's art. Committed output, committed script — the bundle is
hermetic and nothing is downloaded at build time.

  python3 scripts/art/make_art.py client/art

Everything here is painted rather than stood in for: the asphalt is a seamless
cool-grey tile with enough noise that the congestion heat ramp reads against
it, the intersection is a painted box with lane markings, the city blocks are
park / rooftop tiles keyed off the cityspec `scenery` list, each depot is a
warehouse with a visible dock door tinted to its fleet hue.

The vans are NOT painted here any more: van.png and van_loaded.png are
nano-banana renders of a Softmax cog driving a grey cargo cart, produced by
scripts/art/split_van_sheet.py from scripts/art/source/vans_sheet.png. The
viewer tints the grey cart per depot at load. make_van stays only as the
historical 8 px fallback and is no longer called.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

FLEETS = {
    "carbon": (224, 122, 63),
    "oxygen": (74, 143, 231),
    "germanium": (95, 191, 106),
    "silicon": (242, 193, 78),
}


def noise_tile(size, base, spread, seed):
    rng = random.Random(seed)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            n = rng.randint(-spread, spread)
            px[x, y] = tuple(max(0, min(255, c + n)) for c in base)
    return img.filter(ImageFilter.SMOOTH)


def make_asphalt(out):
    tile = noise_tile(128, (52, 57, 64), 9, 17)
    draw = ImageDraw.Draw(tile)
    rng = random.Random(23)
    for _ in range(120):
        x = rng.randrange(128)
        y = rng.randrange(128)
        draw.point((x, y), fill=(70, 75, 84))
    for _ in range(40):
        x = rng.randrange(128)
        y = rng.randrange(128)
        draw.line((x, y, x + rng.randint(-6, 6), y + rng.randint(-3, 3)),
                  fill=(44, 48, 55))
    tile.save(os.path.join(out, "asphalt.jpg"), quality=92)


def make_intersection(out):
    size = 24
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((1, 1, size - 2, size - 2), radius=3,
                           fill=(60, 65, 73, 255), outline=(84, 90, 100, 255))
    for i in range(3, size - 3, 5):
        draw.line((i, 2, i, 4), fill=(196, 200, 208, 190))
        draw.line((i, size - 5, i, size - 3), fill=(196, 200, 208, 190))
        draw.line((2, i, 4, i), fill=(196, 200, 208, 190))
        draw.line((size - 5, i, size - 3, i), fill=(196, 200, 208, 190))
    img.save(os.path.join(out, "intersection.png"))


def make_block(out, name, ground, accents, accent_colour):
    size = 56
    img = noise_tile(size, ground, 7, hash(name) & 0xFFFF).convert("RGBA")
    draw = ImageDraw.Draw(img)
    rng = random.Random(hash(name) & 0xFF)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=6,
                           outline=(30, 34, 40, 255))
    for _ in range(accents):
        x = rng.randrange(6, size - 14)
        y = rng.randrange(6, size - 14)
        w = rng.randrange(6, 14)
        h = rng.randrange(6, 14)
        draw.rounded_rectangle((x, y, x + w, y + h), radius=2,
                               fill=accent_colour)
    img.save(os.path.join(out, name + ".png"))


def make_plaza(out):
    size = 60
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse((0, 0, size - 1, size - 1), fill=(96, 92, 84, 255),
                 outline=(120, 116, 106, 255))
    draw.ellipse((10, 10, size - 11, size - 11), fill=(112, 108, 98, 255))
    for k in range(8):
        a = k * math.pi / 4.0
        cx = size / 2.0
        draw.line((cx, cx, cx + math.cos(a) * 26, cx + math.sin(a) * 26),
                  fill=(128, 124, 114, 180))
    draw.ellipse((24, 24, 35, 35), fill=(78, 120, 92, 255))
    img.save(os.path.join(out, "plaza.png"))


def make_depot(out, name, tint):
    size = 32
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    body = tuple(int(c * 0.55) for c in tint)
    draw.rounded_rectangle((2, 8, size - 3, size - 3), radius=3,
                           fill=body + (255,), outline=tint + (255,))
    draw.polygon([(1, 9), (size / 2, 1), (size - 2, 9)], fill=tint + (255,))
    draw.rectangle((10, 17, 21, size - 5), fill=(28, 30, 34, 255))
    for y in range(18, size - 5, 3):
        draw.line((10, y, 21, y), fill=(52, 56, 62, 255))
    draw.rectangle((4, 12, 7, 15), fill=(230, 235, 245, 210))
    draw.rectangle((size - 8, 12, size - 5, 15), fill=(230, 235, 245, 210))
    img.save(os.path.join(out, "depot_" + name + ".png"))


def make_van(out, name, loaded):
    size = 8
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((0, 1, 7, 6), radius=2, fill=(235, 238, 244, 255),
                           outline=(40, 44, 50, 255))
    draw.rectangle((1, 2, 3, 5), fill=(200, 206, 216, 255))
    if loaded:
        draw.rectangle((4, 2, 6, 4), fill=(250, 250, 250, 255))
        draw.line((4, 3, 6, 3), fill=(196, 150, 80, 255))
    img.save(os.path.join(out, name + ".png"))


def make_parcel_pin(out):
    size = 12
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse((1, 0, 10, 9), fill=(246, 246, 242, 255),
                 outline=(60, 64, 70, 255))
    draw.polygon([(4, 8), (8, 8), (6, 11)], fill=(246, 246, 242, 255))
    draw.rectangle((4, 3, 7, 6), fill=(196, 150, 80, 255))
    img.save(os.path.join(out, "parcel_pin.png"))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "client/art"
    os.makedirs(out, exist_ok=True)
    make_asphalt(out)
    make_intersection(out)
    make_block(out, "block_park", (58, 74, 58), 5, (74, 104, 70, 255))
    make_block(out, "block_roof", (72, 70, 76), 6, (96, 92, 100, 255))
    make_plaza(out)
    for name, tint in FLEETS.items():
        make_depot(out, name, tint)
    # van.png / van_loaded.png are owned by split_van_sheet.py (see docstring)
    make_parcel_pin(out)
    print("wrote gridlock art to", out)


if __name__ == "__main__":
    main()
