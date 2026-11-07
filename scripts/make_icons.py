#!/usr/bin/env python3
"""Draw Carrel's app icons (iPhone, Apple TV layered icon, top shelf) into the asset catalogs.

The mark: a study carrel (an arched booth on a desk) with a play button inside, in Carrel amber
on near-black. Run from the repo root:  python3 scripts/make_icons.py   (needs Pillow)
"""
import json
import os
import sys
from PIL import Image, ImageDraw, ImageFont

AMBER = (242, 181, 68, 255)
CREAM = (255, 244, 220, 255)
TOP, BOTTOM = (31, 35, 44), (12, 13, 17)
SS = 4  # supersampling

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf",
    "/Library/Fonts/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf", "/usr/share/fonts/opentype/inter/Inter-Bold.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def gradient(w, h):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        for x in range(w):
            px[x, y] = c
    return img


def draw_booth(d, cx, cy, s):
    """Arched booth + desk, centred on (cx, cy), `s` = mark height in px."""
    w = s * 0.86            # booth outer width
    r = w / 2               # arch radius
    stroke = s * 0.105
    top = cy - s / 2
    desk_y = cy + s * 0.36
    left, right = cx - w / 2, cx + w / 2
    # Arch: thick ring top half + two legs.
    d.arc([left, top, right, top + w], 180, 360, fill=AMBER, width=int(stroke))
    d.rectangle([left, top + r, left + stroke, desk_y], fill=AMBER)
    d.rectangle([right - stroke, top + r, right, desk_y], fill=AMBER)
    # Desk: wider rounded bar.
    dw = s * 1.12
    dh = s * 0.11
    d.rounded_rectangle([cx - dw / 2, desk_y - dh * 0.15, cx + dw / 2, desk_y + dh], radius=dh / 2, fill=AMBER)


def draw_play(d, cx, cy, s):
    """Play triangle inside the booth; `s` = mark height."""
    h = s * 0.36
    ox = cx + s * 0.025      # optical centring
    oy = cy + s * 0.07
    pts = [(ox - h * 0.42, oy - h / 2), (ox - h * 0.42, oy + h / 2), (ox + h * 0.5, oy)]
    d.polygon(pts, fill=CREAM)


def render(w, h, layers=("back", "booth", "play"), mark=0.62, mark_cx=None):
    W, H = w * SS, h * SS
    img = gradient(W, H) if "back" in layers else Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = H * mark
    cx = (mark_cx if mark_cx is not None else 0.5) * W
    cy = H * 0.5
    if "booth" in layers:
        draw_booth(d, cx, cy, s)
    if "play" in layers:
        draw_play(d, cx, cy, s)
    return img.resize((w, h), Image.LANCZOS)


def font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def top_shelf(w, h):
    mark_cx = (h * 0.62) / w        # mark centred a mark-width in from the left
    img = render(w, h, mark=0.5, mark_cx=mark_cx)
    W, H = img.size
    big = img.resize((W * SS, H * SS), Image.LANCZOS)
    d = ImageDraw.Draw(big)
    x = int(mark_cx * W * SS + H * SS * 0.45)
    title = font(int(H * SS * 0.2))
    sub = font(int(H * SS * 0.075))
    d.text((x, H * SS * 0.30), "Carrel", font=title, fill=CREAM)
    d.text((x, H * SS * 0.56), "LBRY, on the big screen", font=sub, fill=AMBER)
    return big.resize((W, H), Image.LANCZOS)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


INFO = {"author": "xcode", "version": 1}


def ios():
    cat = os.path.join(ROOT, "Carrel", "Assets.xcassets")
    write_json(os.path.join(cat, "Contents.json"), {"info": INFO})
    icon = os.path.join(cat, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    render(1024, 1024, mark=0.54).convert("RGB").save(os.path.join(icon, "AppIcon-1024.png"))
    write_json(os.path.join(icon, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": INFO,
    })
    accent = os.path.join(cat, "AccentColor.colorset")
    write_json(os.path.join(accent, "Contents.json"), {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.949", "green": "0.710", "blue": "0.267", "alpha": "1.000"}}}],
        "info": INFO,
    })


def tv():
    cat = os.path.join(ROOT, "CarrelTV", "Assets.xcassets")
    write_json(os.path.join(cat, "Contents.json"), {"info": INFO})
    brand = os.path.join(cat, "App Icon & Top Shelf Image.brandassets")
    stacks = [("App Icon.imagestack", "primary-app-icon", "400x240", [(400, 240, "1x"), (800, 480, "2x")]),
              ("App Icon - App Store.imagestack", "primary-app-icon", "1280x768", [(1280, 768, "1x")])]
    assets = []
    for folder, role, size, scales in stacks:
        stack = os.path.join(brand, folder)
        layers = [("Front", ("play",)), ("Middle", ("booth",)), ("Back", ("back",))]
        write_json(os.path.join(stack, "Contents.json"), {
            "layers": [{"filename": f"{name}.imagestacklayer"} for name, _ in layers], "info": INFO})
        for name, parts in layers:
            layer = os.path.join(stack, f"{name}.imagestacklayer")
            write_json(os.path.join(layer, "Contents.json"), {"info": INFO})
            content = os.path.join(layer, "Content.imageset")
            os.makedirs(content, exist_ok=True)
            images = []
            for w, h, scale in scales:
                fn = f"{name.lower()}-{w}x{h}.png"
                img = render(w, h, layers=parts, mark=0.6)
                (img.convert("RGB") if name == "Back" else img).save(os.path.join(content, fn))
                images.append({"filename": fn, "idiom": "tv", "scale": scale})
            write_json(os.path.join(content, "Contents.json"), {"images": images, "info": INFO})
        assets.append({"filename": folder, "idiom": "tv", "role": role, "size": size})
    for folder, role, (w, h) in [("Top Shelf Image.imageset", "top-shelf-image", (1920, 720)),
                                 ("Top Shelf Image Wide.imageset", "top-shelf-image-wide", (2320, 720))]:
        shelf = os.path.join(brand, folder)
        os.makedirs(shelf, exist_ok=True)
        images = []
        for scale, k in [("1x", 1), ("2x", 2)]:
            fn = f"top-shelf-{w * k}x{h * k}.png"
            top_shelf(w * k, h * k).convert("RGB").save(os.path.join(shelf, fn))
            images.append({"filename": fn, "idiom": "tv", "scale": scale})
        write_json(os.path.join(shelf, "Contents.json"), {"images": images, "info": INFO})
        assets.append({"filename": folder, "idiom": "tv", "role": role, "size": f"{w}x{h}"})
    write_json(os.path.join(brand, "Contents.json"), {"assets": assets, "info": INFO})
    accent = os.path.join(cat, "AccentColor.colorset")
    write_json(os.path.join(accent, "Contents.json"), {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.949", "green": "0.710", "blue": "0.267", "alpha": "1.000"}}}],
        "info": INFO,
    })


if __name__ == "__main__":
    ios()
    tv()
    print("wrote Carrel/Assets.xcassets and CarrelTV/Assets.xcassets", file=sys.stderr)
