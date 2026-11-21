import os, subprocess, sys
from PIL import Image

AMBER = "#FFC107"
DARK1 = "#2B2218"
DARK2 = "#120E09"
SCREEN = "#1F1912"

# Composition (TV + sous-titres + ondes sonores), centrée sur (0,0).
def composition(mono=False):
    cx, cy = 549, 493
    stroke = "#FFFFFF" if mono else AMBER
    fill = "none" if mono else SCREEN
    bars = "#FFFFFF"
    return f'''
  <g transform="translate({-cx},{-cy})">
    <rect x="150" y="250" width="560" height="440" rx="64" fill="{fill}" stroke="{stroke}" stroke-width="44"/>
    <rect x="330" y="712" width="200" height="34" rx="17" fill="{stroke}"/>
    <rect x="222" y="508" width="416" height="52" rx="26" fill="{bars}"/>
    <rect x="292" y="584" width="276" height="52" rx="26" fill="{bars}"/>
    <g fill="none" stroke="{stroke}" stroke-width="44" stroke-linecap="round">
      <path d="M {720+95*0.766:.1f} {470-95*0.643:.1f} A 95 95 0 0 1 {720+95*0.766:.1f} {470+95*0.643:.1f}"/>
      <path d="M {720+175*0.766:.1f} {470-175*0.643:.1f} A 175 175 0 0 1 {720+175*0.766:.1f} {470+175*0.643:.1f}"/>
      <path d="M {720+255*0.766:.1f} {470-255*0.643:.1f} A 255 255 0 0 1 {720+255*0.766:.1f} {470+255*0.643:.1f}"/>
    </g>
  </g>'''

def svg(body, bg=None, rounded=False):
    defs = f'''<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{DARK1}"/><stop offset="1" stop-color="{DARK2}"/></linearGradient></defs>'''
    back = ""
    if bg == "full":
        back = '<rect width="1024" height="1024" fill="url(#g)"/>'
    elif bg == "rounded":
        back = '<rect x="32" y="32" width="960" height="960" rx="200" fill="url(#g)"/>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{defs}{back}{body}</svg>'

def group(scale, mono=False):
    return f'<g transform="translate(512,512) scale({scale})">{composition(mono)}</g>'

files = {
    "ios.svg": svg(group(0.92), bg="full"),                 # iOS : carré plein, sans transparence
    "legacy.svg": svg(group(0.86), bg="rounded"),           # Android < 8 : carré arrondi
    "foreground.svg": svg(group(0.72)),                     # Android 8+ : premier plan adaptatif
    "monochrome.svg": svg(group(0.72, mono=True)),          # Android 13+ : icône à thème
}
for name, content in files.items():
    open(name, "w").write(content)

def render(src, size, dst, opaque=False):
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    tmp = dst + ".tmp.png"
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), src, "-o", tmp], check=True)
    im = Image.open(tmp)
    if opaque:
        im = im.convert("RGB")
    im.save(dst, optimize=True)
    os.remove(tmp)

out = sys.argv[1]
# Android
dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
for d, f in dens.items():
    render("legacy.svg", int(48 * f), f"{out}/android/res/mipmap-{d}/ic_launcher.png")
    render("foreground.svg", int(108 * f), f"{out}/android/res/mipmap-{d}/ic_launcher_foreground.png")
    render("monochrome.svg", int(108 * f), f"{out}/android/res/mipmap-{d}/ic_launcher_monochrome.png")
os.makedirs(f"{out}/android/res/mipmap-anydpi-v26", exist_ok=True)
open(f"{out}/android/res/mipmap-anydpi-v26/ic_launcher.xml", "w").write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''')
os.makedirs(f"{out}/android/res/values", exist_ok=True)
open(f"{out}/android/res/values/ic_launcher_background.xml", "w").write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#1E1810</color>
</resources>
''')
# iOS : noms du modèle Flutter (AppIcon.appiconset)
ios = {
    "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
}
for name, size in ios.items():
    render("ios.svg", size, f"{out}/ios/AppIcon.appiconset/{name}", opaque=True)
# Aperçus
render("ios.svg", 512, "preview_ios.png", opaque=True)
render("legacy.svg", 512, "preview_legacy.png")
