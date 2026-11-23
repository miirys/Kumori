#!/usr/bin/env python3
"""Builds the Apple TV app icon layers and Top Shelf images from the existing Kumori art.

Nothing here is new artwork. The icon's picture is the bitmap inside assets/kumori-icon.svg,
its clouds are that file's own circles, and the name is assets/kumori-wordmark.svg. They are
split into layers so tvOS can move them apart when the icon is focused:

  Back    the face, opaque, as Apple requires of a background layer
  Middle  the pink row of clouds
  Front   the white row of clouds

Apple's guidance (Human Interface Guidelines, App icons, Layered images, Top Shelf): two to
five rectangular layers, unmasked (the system rounds the corners), an opaque back layer, no
baked-in shadows, glows or highlights, important content kept in from the edges because
focus crops foreground layers more than background ones, and no app name in the icon when
it shows beside it anyway. Top Shelf's static image is 2320 x 720 (4640 x 1440 at 2x).

Run from anywhere: python3 tvos/scripts/make-brand-assets.py
"""
import base64
import io
import os
import re

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ART = os.path.join(ROOT, "assets")
OUT = os.path.join(ROOT, "tvos", "Kumori", "Assets.xcassets", "App Icon & Top Shelf Image.brandassets")

INK = (0x1E, 0x17, 0x24)
PINK = (0xF7, 0xC4, 0xD6)
CREAM = (0xFF, 0xF3, 0xF7)
NIGHT = (0x16, 0x11, 0x1B)
SS = 4  # supersampling for the vector parts

ICON_SVG = open(os.path.join(ART, "kumori-icon.svg")).read()
FACE = Image.open(io.BytesIO(base64.b64decode(re.search(r"base64,([A-Za-z0-9+/=]+)", ICON_SVG).group(1)))).convert("RGB")


def clouds():
    """The icon's two cloud rows, in its 512-unit space: (back circles, back rect, front circles, front rect).
    Each circle is (cx, cy, r, colour)."""
    inner = ICON_SVG.split('viewBox="0 0 512 220">', 1)[1]
    y0 = 344
    shapes = []
    for m in re.finditer(r'<(circle|rect)([^>]*)/>', inner):
        a = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2)))
        fill = tuple(int(a["fill"][i:i + 2], 16) for i in (1, 3, 5))
        if m.group(1) == "circle":
            shapes.append(("c", float(a["cx"]), float(a["cy"]) + y0, float(a["r"]), fill))
        else:
            shapes.append(("r", float(a["x"]), float(a["y"]) + y0, float(a["width"]), float(a["height"]), fill))
    # The file draws: back outlines, back fills, front outlines, front rect, front fills, front rect.
    back = shapes[:8]
    front = shapes[8:]
    return back, front


def draw_shapes(size, shapes, scale, ox, oy, extend=0):
    """Draws circles and rects into a transparent layer. `scale` maps icon units to pixels,
    (ox, oy) is the icon point at the layer's top left. Rects are widened by `extend` units
    each side so the cloud bank runs past both edges."""
    w, h = size
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    k = scale * SS
    for s in shapes:
        if s[0] == "c":
            _, cx, cy, r, fill = s
            x, y = (cx - ox) * k, (cy - oy) * k
            d.ellipse([x - r * k, y - r * k, x + r * k, y + r * k], fill=fill + (255,))
        else:
            _, x, y, rw, rh, fill = s
            d.rectangle([(x - extend - ox) * k, (y - oy) * k, (x + rw + extend - ox) * k, (y + rh + 400 - oy) * k], fill=fill + (255,))
    return im.resize(size, Image.LANCZOS)


def widen(shapes, width_units, period=512):
    """Repeats a cloud row sideways so it covers `width_units` (for the wide Top Shelf)."""
    out = []
    reps = int(width_units // period) + 2
    # Shape by shape, so every outline is drawn before any fill over it, across all copies.
    for s in shapes:
        for i in range(-1, reps):
            if s[0] == "c":
                out.append(("c", s[1] + i * period, s[2], s[3], s[4]))
            elif i == 0:
                out.append(("r", -period, s[2], width_units + 2 * period, s[4], s[5]))
    return out


def face_layer(size, scale, ox, oy, fill=CREAM):
    """The face bitmap placed with the same mapping as the clouds, on an opaque fill."""
    w, h = size
    im = Image.new("RGB", size, fill)
    px = 512 * scale
    face = FACE.resize((round(px), round(px)), Image.LANCZOS)
    im.paste(face, (round(-ox * scale), round(-oy * scale)))
    return im


# Icon: the face fills the width; its eyes sit just above the middle, where the focus crop
# never reaches. The clouds come up a little higher than in the square icon so the 5:3
# frame still ends on them.
ICON_TOP = 96       # icon units at the top edge
CLOUD_LIFT = 36      # how far the clouds rise, in icon units


def icon(w, h):
    scale = w / 512
    back, front = clouds()
    lift = lambda shapes: [(s[0], s[1], s[2] - CLOUD_LIFT) + s[3:] if s[0] == "c" else (s[0], s[1], s[2] - CLOUD_LIFT) + s[3:] for s in shapes]
    face = face_layer((w, h), scale, 0, ICON_TOP)
    middle = draw_shapes((w, h), lift(back), scale, 0, ICON_TOP, extend=60)
    top = draw_shapes((w, h), lift(front), scale, 0, ICON_TOP, extend=60)
    return face, middle, top


def wordmark(height_px):
    """The wordmark SVG, drawn from its own outlines (M, Q and Z only)."""
    svg = open(os.path.join(ART, "kumori-wordmark.svg")).read()
    vw, vh = [float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups()]
    k = height_px / vh * SS
    im = Image.new("RGBA", (round(vw * k), round(vh * k)), (0, 0, 0, 0))
    for m in re.finditer(r'<path fill="(#[0-9A-Fa-f]{6})"[^>]*stroke-width="([\d.]+)"[^>]*d="([^"]+)"', svg):
        colour = tuple(int(m.group(1)[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
        stroke = float(m.group(2)) * k
        mask = Image.new("L", im.size, 0)
        tokens = re.findall(r"[MQZ]|-?[\d.]+", m.group(3))
        polys, cur, i, pos = [], [], 0, (0.0, 0.0)
        while i < len(tokens):
            t = tokens[i]
            if t == "M":
                if cur: polys.append(cur)
                pos = (float(tokens[i + 1]), float(tokens[i + 2])); cur = [pos]; i += 3
            elif t == "Q":
                c = (float(tokens[i + 1]), float(tokens[i + 2])); e = (float(tokens[i + 3]), float(tokens[i + 4]))
                for n in range(1, 9):
                    u = n / 8
                    cur.append(((1 - u) ** 2 * pos[0] + 2 * (1 - u) * u * c[0] + u * u * e[0],
                                (1 - u) ** 2 * pos[1] + 2 * (1 - u) * u * c[1] + u * u * e[1]))
                pos = e; i += 5
            elif t == "Z":
                if cur: polys.append(cur); cur = []
                i += 1
            else:
                i += 1
        if cur: polys.append(cur)
        for p in polys:
            pts = [(x * k, y * k) for x, y in p]
            layer = Image.new("L", im.size, 0)
            ImageDraw.Draw(layer).polygon(pts, fill=255)
            mask = Image.fromarray(__import__("numpy").bitwise_xor(__import__("numpy").array(mask), __import__("numpy").array(layer)))
            ImageDraw.Draw(mask).line(pts + [pts[0]], fill=255, width=max(1, round(stroke)), joint="curve")
            for x, y in pts[::4]:
                r = stroke / 2
                ImageDraw.Draw(mask).ellipse([x - r, y - r, x + r, y + r], fill=255)
        im.paste(Image.new("RGBA", im.size, colour), (0, 0), mask)
    return im.resize((round(vw * height_px / vh), height_px), Image.LANCZOS)


def square_icon(px):
    """The Kumori icon itself, as in assets/kumori-icon.svg: the face over its two cloud rows,
    with the rounded corners the icon has everywhere else."""
    scale = px / 512
    im = face_layer((px, px), scale, 0, 0).convert("RGBA")
    back, front = clouds()
    for row in (back, front):
        layer = draw_shapes((px, px), row, scale, 0, 0)
        im.paste(layer, (0, 0), layer)
    mask = Image.new("L", (px * SS, px * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * SS - 1, px * SS - 1], radius=round(px * SS * 0.225), fill=255)
    im.putalpha(mask.resize((px, px), Image.LANCZOS))
    return im


def top_shelf(w, h):
    """Apple's own Top Shelf images are one calm picture with the app's mark: here the
    icon's colours, blurred into light the way tvOS blurs a show's art behind its page, and
    the icon beside the name, centred inside the middle 1920 x 720 that every screen shows."""
    import numpy as np
    unit = h / 720

    # The face, enlarged and blurred into a field of the icon's own pinks, then dimmed
    # towards the edges so the mark carries the picture.
    glow = FACE.resize((w, w), Image.LANCZOS).crop((0, round(w * 0.18), w, round(w * 0.18) + h))
    glow = glow.filter(ImageFilter.GaussianBlur(90 * unit))
    g = np.asarray(glow, np.float32)
    night = np.array(NIGHT, np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - w / 2) / (w * 0.62)) ** 2 + ((yy - h * 0.5) / (h * 0.95)) ** 2)
    keep = np.clip(1 - d, 0, 1) ** 1.1 * 0.8
    plum = np.array((0x7A, 0x35, 0x62), np.float32)
    tinted = g * 0.45 + plum * 0.55
    sky = night + (tinted - night) * keep[..., None]
    # A soft darkening along the bottom, where tvOS draws the row of apps' titles.
    shade = np.clip((yy / h - 0.55) / 0.45, 0, 1) ** 2 * 0.45
    sky = sky * (1 - shade[..., None]) + night * shade[..., None]
    im = Image.fromarray(np.clip(sky, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

    # The lockup: icon, then the name, centred together.
    tile = square_icon(round(300 * unit))
    mark = wordmark(round(150 * unit))
    gap = round(64 * unit)
    total = tile.width + gap + mark.width
    x0 = round(w / 2 - total / 2)
    ty = round(h * 0.47 - tile.height / 2)
    shadow = Image.new("RGBA", (tile.width + round(160 * unit), tile.height + round(160 * unit)), (0, 0, 0, 0))
    sm = Image.new("L", shadow.size, 0)
    o = round(80 * unit)
    ImageDraw.Draw(sm).rounded_rectangle([o, o + round(18 * unit), o + tile.width, o + tile.height + round(18 * unit)],
                                         radius=round(tile.width * 0.225), fill=150)
    sm = sm.filter(ImageFilter.GaussianBlur(34 * unit))
    shadow.putalpha(sm)
    im.alpha_composite(shadow, (x0 - o, ty - o))
    im.alpha_composite(tile, (x0, ty))
    im.alpha_composite(mark, (x0 + tile.width + gap, round(h * 0.47 - mark.height / 2)))
    return im.convert("RGB")


def save(img, *parts):
    path = os.path.join(OUT, *parts)
    img.save(path, optimize=True)
    print("wrote", os.path.relpath(path, ROOT), img.size)


if __name__ == "__main__":
    # The app icon is the original Kumori icon (the tile beside the name on a dark ground),
    # kept as drawn and split into layers: ground at the back, the tile in the middle, the
    # name in front, so the name is what lifts most when the icon is focused. Pass --icon to
    # draw the older full-bleed face version instead.
    import sys
    if "--icon" in sys.argv:
        for stack, sizes in (("App Icon.imagestack", [(400, 240, "@1x"), (800, 480, "@2x")]),
                             ("App Icon - App Store.imagestack", [(1280, 768, "@1x")])):
            for w, h, suffix in sizes:
                back, middle, front = icon(w, h)
                save(back, stack, "Back.imagestacklayer", "Content.imageset", f"back{suffix}.png")
                save(middle, stack, "Middle.imagestacklayer", "Content.imageset", f"middle{suffix}.png")
                save(front, stack, "Front.imagestacklayer", "Content.imageset", f"front{suffix}.png")
    for name, w in (("Top Shelf Image Wide.imageset", 2320), ("Top Shelf Image.imageset", 1920)):
        save(top_shelf(w, 720), name, "shelf@1x.png")
        save(top_shelf(w * 2, 1440), name, "shelf@2x.png")
