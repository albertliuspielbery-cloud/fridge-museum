#!/usr/bin/env python3
"""Subsets the two OFL CJK fonts to keep the app small.

Keeps: ASCII + Latin-1 + general/CJK punctuation + full-width forms, the 5,401 common Big5 hanzi (常用字),
Zhuyin, and every character used in the app's sources/string catalogs. Characters outside the subset
(rare names) fall back to the system font automatically (Core Text font cascade).
Chiron GoRound TC is a variable font (wght 200–900); we instance it to static 400 / 700.

Usage: python3 tools/subset_fonts.py <Huninn-Regular.ttf> <ChironGoRoundTC[wght].ttf> <out dir> <repo root>
"""
import os
import sys
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

huninn, chiron, out, repo = sys.argv[1:5]

chars = set(chr(c) for c in range(0x20, 0x7F))
chars |= set(chr(c) for c in range(0xA0, 0x100))
for lo, hi in [(0x2000, 0x206F), (0x2190, 0x21FF), (0x2460, 0x24FF), (0x25A0, 0x25FF), (0x2600, 0x26FF),
               (0x3000, 0x303F), (0x3100, 0x312F), (0xFF00, 0xFFEF)]:
    chars |= set(chr(c) for c in range(lo, hi + 1))
for hi in range(0xA4, 0xC7):          # Big5 level-1 hanzi: A440–C67E
    for lo in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
        if (hi, lo) < (0xA4, 0x40) or (hi, lo) > (0xC6, 0x7E):
            continue
        try:
            chars.add(bytes([hi, lo]).decode("big5"))
        except UnicodeDecodeError:
            pass
for root, _, files in os.walk(os.path.join(repo, "FridgeMuseum")):
    for f in files:
        if f.endswith((".swift", ".xcstrings", ".md")):
            with open(os.path.join(root, f), encoding="utf-8") as fh:
                chars |= set(fh.read())
text = "".join(sorted(c for c in chars if c.isprintable()))


def run(font, dst):
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = False
    opts.hinting = False
    sub = subset.Subsetter(opts)
    sub.populate(text=text)
    sub.subset(font)
    font.save(dst)
    print(f"{os.path.basename(dst)}: {os.path.getsize(dst) / 1e6:.2f} MB")


os.makedirs(out, exist_ok=True)
run(TTFont(huninn), os.path.join(out, "Huninn-Regular.ttf"))
for wght, style in [(400, "Regular"), (700, "Bold")]:
    f = instancer.instantiateVariableFont(TTFont(chiron), {"wght": wght}, updateFontNames=True)
    name = f["name"]
    family, ps = "Chiron GoRound TC", f"ChironGoRoundTC-{style}"
    for rec in list(name.names):
        if rec.nameID in (1, 16):
            rec.string = family
        elif rec.nameID in (2, 17):
            rec.string = style
        elif rec.nameID == 4:
            rec.string = f"{family} {style}"
        elif rec.nameID == 6:
            rec.string = ps
    f["OS/2"].usWeightClass = wght
    f["OS/2"].fsSelection = (f["OS/2"].fsSelection & ~0b1100001) | (0b100000 if wght == 700 else 0b1000000)
    f["head"].macStyle = 1 if wght == 700 else 0
    run(f, os.path.join(out, f"ChironGoRoundTC-{style}.ttf"))
