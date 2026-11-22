#!/usr/bin/env python3
"""Draws Doddy, the mascot, and writes the app icon set and the extension icons."""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2                     # supersampling
W = 1024 * S

def sc(v): return int(round(v * S))

def gradient(size, stops, angle_deg=135):
    h, w = size
    ys, xs = np.mgrid[0:h, 0:w]
    a = math.radians(angle_deg)
    t = (xs * math.cos(a) + ys * math.sin(a))
    t = (t - t.min()) / (t.max() - t.min())
    out = np.zeros((h, w, 3))
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]; t1, c1 = stops[i + 1]
        m = (t >= t0) & (t <= t1)
        k = ((t - t0) / (t1 - t0))[m][:, None]
        out[m] = np.array(c0) * (1 - k) + np.array(c1) * k
    return Image.fromarray(out.astype('uint8'), 'RGB')

def ell(d, cx, cy, rx, ry, fill, outline=None, width=0):
    d.ellipse([sc(cx - rx), sc(cy - ry), sc(cx + rx), sc(cy + ry)], fill=fill, outline=outline, width=width)

def rotated_ellipse(img, cx, cy, rx, ry, angle, fill):
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse([sc(cx - rx), sc(cy - ry), sc(cx + rx), sc(cy + ry)], fill=fill)
    layer = layer.rotate(angle, center=(sc(cx), sc(cy)), resample=Image.BICUBIC)
    img.alpha_composite(layer)

def draw(flat=False, bleed=False, layer=False):
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    # background squircle
    O, L = (0, 1024) if bleed else (100, 824)
    bg = gradient((sc(L), sc(L)),
                  [(0, (24, 205, 245)), (0.5, (110, 100, 255)), (1, (255, 95, 165))], 120).convert('RGBA')
    mask = Image.new('L', (sc(L), sc(L)), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sc(L) - 1, sc(L) - 1], radius=0 if bleed else sc(190), fill=255)
    if not flat and not bleed:
        shadow = Image.new('RGBA', img.size, (0, 0, 0, 0))
        sm = Image.new('L', img.size, 0)
        ImageDraw.Draw(sm).rounded_rectangle([sc(100), sc(116), sc(924), sc(940)], radius=sc(190), fill=110)
        shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(sc(14))))
        img.alpha_composite(shadow)
    if not layer:
        img.paste(bg, (sc(O), sc(O)), mask)

    # soft glow
    glow = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ell(ImageDraw.Draw(glow), 420, 300, 330, 260, (255, 255, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(sc(60)))
    clipped = Image.new('RGBA', img.size, (0, 0, 0, 0))
    clipped.paste(glow, (0, 0), Image.new('L', img.size, 0))
    gm = Image.new('L', img.size, 0)
    gm.paste(mask, (sc(O), sc(O)))
    glow.putalpha(Image.composite(glow.getchannel('A'), Image.new('L', img.size, 0), gm))
    if not layer:
        img.alpha_composite(glow)

    # pixel-art download badge, centred
    d = ImageDraw.Draw(img)
    N, cell = 26, (16 if bleed else 14)
    ox = oy = 512 - (N * cell) // 2
    def pix(x, y, color):
        d.rectangle([sc(ox + x * cell), sc(oy + y * cell), sc(ox + (x + 1) * cell) - 1, sc(oy + (y + 1) * cell) - 1], fill=color)
    def inside(x, y, shift=0.0):
        return math.hypot(x + 0.5 - 13 - shift, y + 0.5 - 13 - shift) <= 12.6
    # disc: white rim, shaded green body
    for y in range(N):
        for x in range(N):
            r = math.hypot(x + 0.5 - 13, y + 0.5 - 13)
            if r > 12.6:
                continue
            if r > 11.6:
                pix(x, y, (255, 255, 255, 255))
            elif r > 9.4 and x + y < 15:
                pix(x, y, (112, 240, 172, 255))
            elif r > 9.4 and x + y > 36:
                pix(x, y, (28, 160, 96, 255))
            else:
                pix(x, y, (52, 214, 132, 255))
    # arrow: shaft, head, tray (with a one-pixel shade)
    cells = []
    for y in range(6, 14):
        for x in range(11, 15):
            cells.append((x, y))
    for i, y in enumerate(range(14, 20)):
        for x in range(7 + i, 19 - i):
            cells.append((x, y))
    for (x, y) in cells:
        pix(x + 1, y + 1, (20, 130, 80, 255))
    for (x, y) in cells:
        pix(x, y, (255, 255, 255, 255))
    # little pixel sparkles
    def spark(cx, cy, color):
        for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
            d.rectangle([sc(cx + dx * 14), sc(cy + dy * 14), sc(cx + dx * 14 + 13), sc(cy + dy * 14 + 13)], fill=color)
    spark(238, 262, (255, 255, 255, 235))
    spark(790, 300, (255, 224, 90, 255))
    spark(770, 770, (255, 255, 255, 220))
    return img.resize((1024, 1024), Image.LANCZOS)

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    full = draw(False, True)
    full.save(os.path.join(root, 'docs', 'icon.png'))
    setdir = os.path.join(root, 'Assets.xcassets', 'AppIcon.appiconset')
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            full.resize((px, px), Image.LANCZOS).save(os.path.join(setdir, f'icon_{pt}@{scale}x.png'))
    flat = draw(True).crop((100, 100, 924, 924))
    ext = os.path.join(root, 'extension', 'icons')
    os.makedirs(ext, exist_ok=True)
    for px in (16, 32, 48, 128):
        flat.resize((px, px), Image.LANCZOS).save(os.path.join(ext, f'icon{px}.png'))
    lay = os.path.join(root, 'IconComposer', 'Doddy.icon', 'Assets')
    os.makedirs(lay, exist_ok=True)
    draw(True, True, True).save(os.path.join(lay, 'badge.png'))
    gradient((1024, 1024), [(0, (24, 205, 245)), (0.5, (110, 100, 255)), (1, (255, 95, 165))], 120).save(os.path.join(lay, 'background.png'))
    print('icons written')

main()
