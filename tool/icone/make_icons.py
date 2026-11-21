"""Génère les icônes VoxLiso (logo retenu : piste B « Bulle-onde »).

Bulle de parole bleu nuit sur fond jaune, une ligne de sous-titre blanche
et une onde sonore jaune. Version détaillée (7 barres) pour les grandes
tailles, version simplifiée (4 barres épaisses) à 48 px et moins.

Usage : python3 make_icons.py <dossier de sortie>   (rsvg-convert + Pillow)
"""
import os
import subprocess
import sys

from PIL import Image

ACCENT = "#FFC93C"  # jaune
GROUND = "#12204A"  # bleu nuit
BUBBLE = "M28 18 H72 Q84 18 84 30 V58 Q84 70 72 70 H44 L30 82 V70 H28 Q16 70 16 58 V30 Q16 18 28 18 Z"

DETAILED = (
    '<rect x="27" y="30" width="46" height="5" rx="2.5" fill="{line}"/>'
    '<rect x="27" y="49" width="4" height="8" rx="2" fill="{bars}"/>'
    '<rect x="34" y="45" width="4" height="16" rx="2" fill="{bars}"/>'
    '<rect x="41" y="42" width="4" height="22" rx="2" fill="{bars}"/>'
    '<rect x="48" y="47" width="4" height="12" rx="2" fill="{bars}"/>'
    '<rect x="55" y="44" width="4" height="18" rx="2" fill="{bars}"/>'
    '<rect x="62" y="48" width="4" height="10" rx="2" fill="{bars}"/>'
    '<rect x="69" y="46" width="4" height="14" rx="2" fill="{bars}"/>'
)
SIMPLE = (
    '<rect x="27" y="28" width="46" height="7" rx="3.5" fill="{line}"/>'
    '<rect x="28" y="44" width="8" height="16" rx="4" fill="{bars}"/>'
    '<rect x="40" y="40" width="8" height="24" rx="4" fill="{bars}"/>'
    '<rect x="52" y="45" width="8" height="14" rx="4" fill="{bars}"/>'
    '<rect x="64" y="42" width="8" height="20" rx="4" fill="{bars}"/>'
)


def mark(simple=False):
    """Bulle + ligne + onde, dans un carré de 100 (sans le fond)."""
    inner = (SIMPLE if simple else DETAILED).format(line="#FFFFFF", bars=ACCENT)
    return f'<path d="{BUBBLE}" fill="{GROUND}"/>{inner}'


def mono_mark(simple=False):
    """Icône à thème (Android 13+) : bulle pleine, ligne et onde évidées."""
    holes = (SIMPLE if simple else DETAILED).format(line="#000000", bars="#000000")
    return (
        '<defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">'
        f'<path d="{BUBBLE}" fill="#FFFFFF"/>{holes}</mask></defs>'
        '<rect width="100" height="100" fill="#FFFFFF" mask="url(#m)"/>'
    )


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100">{body}</svg>'


def scaled(body, k):
    """Réduit le dessin autour du centre (zone sûre des icônes adaptatives)."""
    return f'<g transform="translate(50 50) scale({k}) translate(-50 -50)">{body}</g>'


VARIANTS = {
    # iPhone : carré plein sans transparence (iOS arrondit lui-même les coins).
    "ios.svg": svg(f'<rect width="100" height="100" fill="{ACCENT}"/>{mark()}'),
    # Android < 8 et planches : carré arrondi, comme sur la planche du logo.
    "legacy.svg": svg(f'<rect width="100" height="100" rx="22" fill="{ACCENT}"/>{mark()}'),
    "legacy_small.svg": svg(f'<rect width="100" height="100" rx="22" fill="{ACCENT}"/>{mark(True)}'),
    # Android 8+ : premier plan adaptatif (fond jaune fourni par la couleur de fond).
    # Le point le plus éloigné du dessin est à ~42 du centre ; zone sûre = 33/54 du canevas.
    "foreground.svg": svg(scaled(mark(), 0.72)),
    "monochrome.svg": svg(scaled(mono_mark(True), 0.72)),
}


def render(src, size, dst, opaque=False):
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    tmp = dst + ".tmp.png"
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), src, "-o", tmp], check=True)
    im = Image.open(tmp)
    if opaque:
        im = im.convert("RGB")
    im.save(dst, optimize=True)
    os.remove(tmp)


def main(out):
    here = os.path.dirname(os.path.abspath(__file__))
    for name, content in VARIANTS.items():
        with open(os.path.join(here, name), "w") as f:
            f.write(content)
    p = lambda n: os.path.join(here, n)

    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for d, f in dens.items():
        size = int(48 * f)
        render(p("legacy_small.svg" if size <= 48 else "legacy.svg"), size,
               f"{out}/android/res/mipmap-{d}/ic_launcher.png")
        render(p("foreground.svg"), int(108 * f), f"{out}/android/res/mipmap-{d}/ic_launcher_foreground.png")
        render(p("monochrome.svg"), int(108 * f), f"{out}/android/res/mipmap-{d}/ic_launcher_monochrome.png")

    os.makedirs(f"{out}/android/res/mipmap-anydpi-v26", exist_ok=True)
    with open(f"{out}/android/res/mipmap-anydpi-v26/ic_launcher.xml", "w") as f:
        f.write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''')
    os.makedirs(f"{out}/android/res/values", exist_ok=True)
    with open(f"{out}/android/res/values/ic_launcher_background.xml", "w") as f:
        f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{ACCENT}</color>
</resources>
''')

    # iPhone : noms du modèle Flutter (AppIcon.appiconset).
    ios = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
    }
    small_ios = svg(f'<rect width="100" height="100" fill="{ACCENT}"/>{mark(True)}')
    with open(p("ios_small.svg"), "w") as f:
        f.write(small_ios)
    for name, size in ios.items():
        render(p("ios_small.svg" if size <= 48 else "ios.svg"), size,
               f"{out}/ios/AppIcon.appiconset/{name}", opaque=True)


if __name__ == "__main__":
    main(sys.argv[1])
