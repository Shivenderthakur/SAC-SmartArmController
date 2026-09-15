#!/usr/bin/env python3
"""Rebuild every platform's app icon from assets/icon/app_icon.png. Needs Pillow."""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/icon/app_icon.png"

# The arm is white and its glow blue, so it needs a dark ground to read at all.
BG_CENTER = (22, 40, 86, 255)
BG_EDGE = (6, 11, 28, 255)

# How far the art may reach from the centre, as a fraction of the icon's side.
FILL = 0.46                 # inside the inscribed circle: safe under iOS and Play masks
MASKABLE = 0.40             # W3C maskable safe zone
ADAPTIVE = 33 / 108         # Android adaptive icons: 66dp circle on a 108dp layer

ANDROID = ROOT / "android/app/src/main/res"
IOS = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
MACOS = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
WEB = ROOT / "web"
WINDOWS_ICO = ROOT / "windows/runner/resources/app_icon.ico"
PLAY_STORE = ROOT / "assets/icon/play_store_512.png"


def load():
    src = Image.open(SOURCE).convert("RGBA")
    if src.width != src.height or src.width < 1024:
        raise SystemExit(f"{SOURCE} is {src.size}; it must be square and at least 1024x1024")

    mono = src.getchannel("A").point(lambda v: 255 if v > 128 else 0)
    # Opening drops stray glow specks so they don't shrink the art when it is measured.
    body = mono.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5))
    box = body.getbbox()
    art, body, mono = src.crop(box), body.crop(box), mono.crop(box)

    w, cx, cy = art.width, art.width / 2, art.height / 2
    reach = max(
        math.hypot(i % w + 0.5 - cx, i // w + 0.5 - cy)
        for i, v in enumerate(body.getdata())
        if v
    )

    silhouette = Image.new("RGBA", art.size, (255, 255, 255, 0))
    silhouette.putalpha(mono)
    return art, silhouette, reach


ART, SILHOUETTE, REACH = load()


def place(n, fill, art=ART, canvas=None):
    scale = fill * n / REACH
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    canvas = canvas or Image.new("RGBA", (n, n), (0, 0, 0, 0))
    canvas.alpha_composite(
        art.resize(size, Image.LANCZOS),
        (round((n - size[0]) / 2), round((n - size[1]) / 2)),
    )
    return canvas


def plate(n):
    falloff = Image.radial_gradient("L").resize((n, n), Image.BILINEAR)
    return Image.composite(
        Image.new("RGBA", (n, n), BG_EDGE), Image.new("RGBA", (n, n), BG_CENTER), falloff
    )


def tile(n, fill=FILL):
    return place(n, fill, canvas=plate(n))


def rounded(n, margin, corner, fill=FILL):
    side = n - 2 * round(n * margin)
    inner = tile(side, fill)
    big = side * 4
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), radius=corner * big, fill=255)
    inner.putalpha(mask.resize((side, side), Image.LANCZOS))
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.alpha_composite(inner, ((n - side) // 2, (n - side) // 2))
    return out


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    print(f"{img.width:>5}x{img.height:<5} {path.relative_to(ROOT)}")


def android():
    for density, k in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        out = ANDROID / f"mipmap-{density}"
        save(rounded(round(48 * k), 0.04, 0.22), out / "ic_launcher.png")
        n = round(108 * k)
        save(plate(n), out / "ic_launcher_background.png")
        save(place(n, ADAPTIVE), out / "ic_launcher_foreground.png")
        save(place(n, ADAPTIVE, SILHOUETTE), out / "ic_launcher_monochrome.png")

    xml = ANDROID / "mipmap-anydpi-v26/ic_launcher.xml"
    xml.parent.mkdir(exist_ok=True)
    xml.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
        "</adaptive-icon>\n"
    )
    print(f"{'xml':>11} {xml.relative_to(ROOT)}")


def ios():
    # Names carry the size: Icon-App-83.5x83.5@2x.png is 167 px. App Store icons may not have alpha.
    for path in sorted(IOS.glob("Icon-App-*.png")):
        points, scale = path.stem.removeprefix("Icon-App-").split("@")
        save(tile(round(float(points.split("x")[0]) * int(scale[0]))).convert("RGB"), path)


def macos():
    # macOS does not mask icons, so the rounded plate and its margin are drawn in.
    for path in sorted(MACOS.glob("app_icon_*.png")):
        save(rounded(int(path.stem.split("_")[-1]), 100 / 1024, 0.225), path)


def web():
    save(rounded(32, 0, 0.22), WEB / "favicon.png")
    for n in (192, 512):
        save(tile(n), WEB / f"icons/Icon-{n}.png")
        save(tile(n, MASKABLE), WEB / f"icons/Icon-maskable-{n}.png")


def windows():
    sizes = [256, 128, 64, 48, 32, 24, 16]
    frames = [rounded(n, 0.02, 0.22) for n in sizes]
    frames[0].save(WINDOWS_ICO, format="ICO", sizes=[(n, n) for n in sizes], append_images=frames[1:])
    print(f"{'ico':>11} {WINDOWS_ICO.relative_to(ROOT)}  {sizes}")


if __name__ == "__main__":
    print(f"source {SOURCE.relative_to(ROOT)} {ART.size} cropped, reach {REACH:.0f} px")
    android()
    ios()
    macos()
    web()
    windows()
    save(tile(512), PLAY_STORE)
