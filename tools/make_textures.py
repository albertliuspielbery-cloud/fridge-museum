#!/usr/bin/env python3
"""Crayon grain texture (tileable alpha noise), the native stand-in for the web's feTurbulence crayon filter.
Usage: python3 tools/make_textures.py <Assets.xcassets/Art>"""
import json, os, random, sys
from PIL import Image, ImageFilter

out = sys.argv[1]
random.seed(5)
S = 192
noise = Image.new("L", (S, S))
noise.putdata([random.randint(0, 255) for _ in range(S * S)])
# Tile 3×3, blur, take the centre → a seamless, slightly soft grain.
big = Image.new("L", (S * 3, S * 3))
for i in range(3):
    for j in range(3):
        big.paste(noise, (i * S, j * S))
big = big.filter(ImageFilter.GaussianBlur(0.7)).crop((S, S, 2 * S, 2 * S))
# Same transfer as the web filter: alpha = 4.2·n − 2.55 (+ contrast for the blur), mostly opaque with flecks.
alpha = big.point(lambda v: max(0, min(255, int((4.2 * (v / 255) * 1.0 - 1.45) * 255))))
img = Image.merge("RGBA", (Image.new("L", (S, S), 255),) * 3 + (alpha,))
d = os.path.join(out, "crayon-grain.imageset")
os.makedirs(d, exist_ok=True)
img.save(os.path.join(d, "crayon-grain.png"))
json.dump({"images": [{"filename": "crayon-grain.png", "idiom": "universal"}],
           "info": {"author": "xcode", "version": 1}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
print("ok")
