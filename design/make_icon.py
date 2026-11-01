#!/usr/bin/env python3
"""Render the EWP app icon into the iOS asset catalogue.

Run: uv run --with 'Pillow>=11,<13' python3 design/make_icon.py

The mark is the product's name made literal: a wall of phones with one screen
awake. Everything is drawn at 4x and reduced once with LANCZOS, so the output
is deterministic and the same script reproduces the shipped artwork.
"""

from pathlib import Path
import math

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4
HI = SIZE * SCALE
ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / 'ios/EWP/Assets.xcassets/AppIcon.appiconset'
PREVIEW = ROOT / 'docs/design/app-icon.png'
LANCZOS = Image.Resampling.LANCZOS

# Three rows of 1:1.65 tiles leave even margins once the gutter is included.
ASPECT = 1.65
GUTTER_RATIO = 0.34
GRID_HEIGHT = SIZE * 0.68
TILE_WIDTH = GRID_HEIGHT / (3 * ASPECT + 2 * GUTTER_RATIO)
TILE_HEIGHT = ASPECT * TILE_WIDTH
GUTTER = GUTTER_RATIO * TILE_WIDTH
GRID_WIDTH = 3 * TILE_WIDTH + 2 * GUTTER
RADIUS = 0.28 * TILE_WIDTH

# Dormant tiles stay a step above the background so the grid reads at 40 px.
PALETTE = {
    'default': dict(dormant='#2C3349', highlight='#454E70',
                    awake=('#6E7BFF', '#4453E8'), glow='#5B6CFF'),
    'dark': dict(dormant='#39405A', highlight='#49527180'[:7],
                 awake=('#6E7BFF', '#4453E8'), glow='#5B6CFF'),
    'tinted': dict(dormant='#858585', highlight='#9C9C9C',
                   awake=('#F6F6F6', '#E5E5E5'), glow='#DDDDDD'),
}


def gradient(size, top, bottom):
    """A vertical RGB gradient without an array library."""
    width, height = size
    top = tuple(bytes.fromhex(top.lstrip('#')))
    bottom = tuple(bytes.fromhex(bottom.lstrip('#')))
    strip = Image.new('RGB', (1, height))
    strip.putdata([
        tuple(round(a + (b - a) * y / max(1, height - 1)) for a, b in zip(top, bottom))
        for y in range(height)
    ])
    return strip.resize((width, height), Image.Resampling.NEAREST)


def tile_box(row, col):
    x = (SIZE - GRID_WIDTH) / 2 + col * (TILE_WIDTH + GUTTER)
    y = (SIZE - GRID_HEIGHT) / 2 + row * (TILE_HEIGHT + GUTTER)
    return tuple(round(v * SCALE) for v in (x, y, x + TILE_WIDTH, y + TILE_HEIGHT))


def tile_mask(box):
    mask = Image.new('L', (HI, HI))
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=round(RADIUS * SCALE), fill=255)
    return mask


def background():
    base = gradient((HI, HI), '#161A26', '#07080D')
    lift = Image.new('L', (HI, HI))
    draw = ImageDraw.Draw(lift)
    extent = SIZE * 0.65 * SCALE
    for step in range(512, -1, -1):
        ratio = step / 512
        radius = extent * ratio
        draw.ellipse((HI / 2 - radius, HI / 2 - radius, HI / 2 + radius, HI / 2 + radius),
                     fill=round(255 * 0.20 * (1 - ratio * ratio) ** 2))
    return Image.composite(Image.new('RGB', (HI, HI), '#232942'), base, lift)


def render(appearance):
    colours = PALETTE[appearance]
    canvas = (background().convert('RGBA') if appearance == 'default'
              else Image.new('RGBA', (HI, HI), (0, 0, 0, 0)))

    for row in range(3):
        for col in range(3):
            if (row, col) == (1, 1):
                continue
            box = tile_box(row, col)
            canvas.paste(colours['dormant'], (0, 0), tile_mask(box))
            # A highlight confined to the top curve reads as glass, not a border.
            shine = Image.new('L', (HI, HI))
            inset = SCALE * 0.6
            inner = tuple(v + inset if i < 2 else v - inset for i, v in enumerate(box))
            ImageDraw.Draw(shine).rounded_rectangle(
                inner, radius=RADIUS * SCALE - inset, outline=255, width=round(SCALE * 1.2))
            band = shine.crop((box[0], box[1], box[2] + 1, round(box[1] + RADIUS * SCALE)))
            fade = Image.new('L', (1, band.height))
            fade.putdata([round(210 * (1 - y / max(1, band.height - 1)) ** 2)
                          for y in range(band.height)])
            band = Image.composite(band, Image.new('L', band.size), fade.resize(band.size))
            canvas.paste(colours['highlight'], (box[0], box[1]), band)

    centre = tile_box(1, 1)
    mask = tile_mask(centre)
    # The glow bleeds onto the neighbouring tiles: one screen is being watched.
    glow_mask = mask.filter(ImageFilter.GaussianBlur(46 * SCALE))
    glow_mask = glow_mask.point([round(v * 0.46) for v in range(256)])
    glow = Image.new('RGBA', (HI, HI), colours['glow'])
    glow.putalpha(glow_mask)
    canvas = Image.alpha_composite(canvas, glow)

    x0, y0, x1, y1 = centre
    awake = gradient((x1 - x0 + 1, y1 - y0 + 1), *colours['awake'])
    canvas.paste(awake, (x0, y0), mask.crop((x0, y0, x1 + 1, y1 + 1)))
    if appearance == 'default':
        canvas = canvas.convert('RGB')
    return canvas.resize((SIZE, SIZE), LANCZOS)


def squircle_mask():
    """An iOS-style superellipse, used only to judge the preview."""
    mask = Image.new('L', (HI, HI))
    centre = (HI - 1) / 2
    points = []
    for i in range(4096):
        theta = 2 * math.pi * i / 4096
        c, s = math.cos(theta), math.sin(theta)
        points.append((centre + centre * math.copysign(abs(c) ** 0.4, c),
                       centre + centre * math.copysign(abs(s) ** 0.4, s)))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def preview(icon):
    sizes = (1024, 180, 120, 80, 60, 40)
    padding, gap = 32, 24
    sheet = Image.new('RGB', (sum(sizes) + 2 * padding + gap * (len(sizes) - 1),
                              SIZE + 2 * padding), '#8A8A8E')
    mask = squircle_mask()
    x = padding
    for size in sizes:
        thumb = icon if size == SIZE else icon.resize((size, size), LANCZOS)
        sheet.paste(thumb, (x, padding + (SIZE - size) // 2), mask.resize((size, size), LANCZOS))
        x += size + gap
    return sheet


def main():
    ICONS.mkdir(parents=True, exist_ok=True)
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    for appearance, name in (('default', 'icon-1024.png'),
                             ('dark', 'icon-1024-dark.png'),
                             ('tinted', 'icon-1024-tinted.png')):
        icon = render(appearance)
        icon.save(ICONS / name)
        if appearance == 'default':
            preview(icon).save(PREVIEW)
        print(f'{name}: {icon.width}x{icon.height} {icon.mode}')
    print(f'{PREVIEW.relative_to(ROOT)}: contact sheet')


if __name__ == '__main__':
    main()
