#!/usr/bin/env python3
"""Turns the web prototype's Bibi sprite (styles/bingbing-sprite.svg) into standalone SVG imagesets.

Xcode's SVG renderer (CoreSVG) supports plain shapes, paths, transforms and opacity, but not <use>/<symbol>,
CSS custom properties, filters or patterns. So this script:
  * inlines every <use> as a <g transform> (viewBox → translate/scale, preserveAspectRatio xMidYMid meet),
  * resolves style="fill:var(--bb-x,#default)" to plain fill/stroke attributes, once per palette (light + night),
  * drops the crayon/wobble filters (the app draws its own crayon texture),
  * expands the washi-tape patterns into explicit stripes/dots/checks clipped to the tape shape.

Usage: python3 tools/sprite_to_assets.py <sprite.svg> <Assets.xcassets/Art>
"""
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
XLINK = "{http://www.w3.org/1999/xlink}href"
ET.register_namespace("", SVG_NS)

LIGHT = {
    "bb-front": "#8ED3C0", "bb-side": "#5DB4A0", "bb-split": "#6CC0AC", "bb-hl": "#B9E7DA", "bb-handle": "#5DB4A0",
    "bb-feet": "#3F8E7C", "bb-hand": "#A6DFCF", "bb-eye": "#2F2522", "bb-cheek": "#F59C94", "bb-bow": "#F59C94",
    "bb-bow2": "#E9787A",
}
NIGHT = {
    "bb-front": "#3F8C86", "bb-side": "#2B6764", "bb-split": "#357A75", "bb-hl": "#5BA6A0", "bb-handle": "#2B6764",
    "bb-feet": "#1F4F4C", "bb-hand": "#5BA6A0", "bb-eye": "#14131C", "bb-cheek": "#D9868C", "bb-bow": "#C9787E",
    "bb-bow2": "#A85A62",
}

# asset name → symbol id
EXPORTS = {
    # Bibi poses (200 × 200)
    "bibi-idle": "bb-idle", "bibi-blink": "bb-blink", "bibi-wave": "bb-wave", "bibi-talk": "bb-talk",
    "bibi-cheer": "bb-cheer", "bibi-ticket": "bb-ticket-pose", "bibi-think": "bb-think", "bibi-oops": "bb-oops",
    "bibi-empty": "bb-empty", "bibi-sleep": "bb-sleep", "bibi-proud": "bb-proud",
    "bibi-mini": "bb-mini", "bibi-head": "bb-head", "bibi-34": "bb-34",
    # faces for the freezer door
    "bibi-face-smile": "bb-face-smile", "bibi-face-blink": "bb-face-blink", "bibi-face-talk": "bb-face-talk",
    "bibi-face-joy": "bb-face-joy", "bibi-face-think": "bb-face-think", "bibi-face-oops": "bb-face-oops",
    "bibi-face-hope": "bb-face-hope", "bibi-face-sleep": "bb-face-sleep", "bibi-face-proud": "bb-face-proud",
    "sparkle": "bb-sparkle", "ticket": "bb-ticket", "ticket-blank": "bb-ticket-blank",
    # kitchen props
    "cat-sit": "cat-sit", "cat-loaf": "cat-loaf", "cat-peek": "cat-peek", "prop-crayons": "prop-crayons",
    "mag-tomato": "mag-tomato", "mag-cloud": "mag-cloud", "mag-lemon": "mag-lemon", "mag-berry": "mag-berry",
}

TAPES = {
    "tape-stripe": ("stripes", "#FBD2C9", "#F27A6E", 45, 10, 5),
    "tape-mint": ("stripes", "#D6F2E2", "#7CCB9E", -45, 10, 4),
    "tape-dots": ("dots", "#F8C14A", "#FFF6DD", 0, 9, 2),
    "tape-check": ("check", "#CFE0FF", "#8FB1F2", 0, 10, 5),
}
TAPE_SHAPE = [(0, 0), (4, 4), (0, 8), (4, 13), (0, 18), (4, 22), (0, 26), (120, 26), (116, 22), (120, 18),
              (116, 13), (120, 8), (116, 4), (120, 0)]

VAR_RE = re.compile(r"var\(--([a-z0-9-]+)\s*,\s*([^)]+)\)")


def local(tag):
    return tag.split("}", 1)[-1]


def fmt(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def resolve(value, palette):
    def sub(m):
        return palette.get(m.group(1), m.group(2).strip())
    return VAR_RE.sub(sub, value)


class Flattener:
    def __init__(self, root):
        self.symbols = {s.get("id"): s for s in root.iter(f"{{{SVG_NS}}}symbol")}

    def symbol_children(self, sid, palette):
        sym = self.symbols[sid]
        out = []
        for child in sym:
            out.extend(self.flatten(child, palette))
        return out

    def flatten(self, el, palette):
        tag = local(el.tag)
        if tag in ("title", "desc", "defs") or not isinstance(el.tag, str):
            return []
        if tag == "use":
            href = (el.get("href") or el.get(XLINK) or "").lstrip("#")
            sym = self.symbols[href]
            vx, vy, vw, vh = [float(t) for t in sym.get("viewBox").split()]
            x, y = float(el.get("x", 0)), float(el.get("y", 0))
            w, h = float(el.get("width", vw)), float(el.get("height", vh))
            s = min(w / vw, h / vh)
            ox, oy = x + (w - vw * s) / 2, y + (h - vh * s) / 2
            g = ET.Element(f"{{{SVG_NS}}}g")
            g.set("transform", f"translate({fmt(ox)} {fmt(oy)}) scale({fmt(s)}) translate({fmt(-vx)} {fmt(-vy)})")
            for c in self.symbol_children(href, palette):
                g.append(c)
            return [g]
        new = ET.Element(f"{{{SVG_NS}}}{tag}")
        for k, v in el.attrib.items():
            if k in ("filter", "class", "aria-hidden") or k.startswith("{"):
                continue
            if k == "style":
                for decl in v.split(";"):
                    if ":" not in decl:
                        continue
                    p, val = [t.strip() for t in decl.split(":", 1)]
                    new.set(p, resolve(val, palette))
                continue
            new.set(k, resolve(v, palette))
        if (new.get("fill") or "").startswith("url("):
            raise ValueError(f"pattern fill left in {tag}")
        new.text = el.text if el.text and el.text.strip() else None
        for c in el:
            for f in self.flatten(c, palette):
                new.append(f)
        return [new]


def svg_doc(viewbox, children):
    vx, vy, vw, vh = [float(t) for t in viewbox.split()]
    root = ET.Element(f"{{{SVG_NS}}}svg")
    root.set("viewBox", viewbox)
    root.set("width", fmt(vw))
    root.set("height", fmt(vh))
    for c in children:
        root.append(c)
    return ET.tostring(root, encoding="unicode")


# ---------- washi tape geometry ----------

def clip(poly, a, b, c):
    """Keeps the part of polygon where a*x + b*y <= c (Sutherland–Hodgman, one half-plane)."""
    out = []
    n = len(poly)
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        pin = a * p[0] + b * p[1] <= c + 1e-9
        qin = a * q[0] + b * q[1] <= c + 1e-9
        if pin:
            out.append(p)
        if pin != qin:
            dp = a * p[0] + b * p[1] - c
            dq = a * q[0] + b * q[1] - c
            t = dp / (dp - dq)
            out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    return out


def poly_path(poly):
    return "M" + " L".join(f"{fmt(x)} {fmt(y)}" for x, y in poly) + "Z"


def tape_svg(kind, base, ink, angle, period, width):
    shape = poly_path(TAPE_SHAPE)
    parts = [f'<path d="{shape}" fill="{base}" opacity=".9"/>']
    if kind == "stripes":
        th = math.radians(angle)
        a, b = math.cos(th), math.sin(th)  # band coordinate u = a*x + b*y
        us = [a * x + b * y for x, y in TAPE_SHAPE]
        k0, k1 = math.floor(min(us) / period) - 1, math.ceil(max(us) / period) + 1
        for k in range(k0, k1):
            lo, hi = k * period, k * period + width
            p = clip(TAPE_SHAPE, a, b, hi)
            p = clip(p, -a, -b, -lo)
            if len(p) >= 3:
                parts.append(f'<path d="{poly_path(p)}" fill="{ink}" opacity=".9"/>')
    elif kind == "dots":
        for i in range(0, 14):
            for j in range(0, 3):
                cx, cy = i * period + period / 2, j * period + period / 2
                if 6 <= cx <= 114 and cy + width <= 26:
                    parts.append(f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(width)}" fill="{ink}" opacity=".9"/>')
    elif kind == "check":
        for i in range(0, 24):
            for j in range(0, 6):
                if (i + j) % 2:
                    continue
                x0, y0 = i * width, j * width
                sq = [(x0, y0), (x0 + width, y0), (x0 + width, y0 + width), (x0, y0 + width)]
                p = TAPE_SHAPE
                p = clip(p, 1, 0, x0 + width)
                p = clip(p, -1, 0, -x0)
                p = clip(p, 0, 1, y0 + width)
                p = clip(p, 0, -1, -y0)
                if len(p) >= 3:
                    parts.append(f'<path d="{poly_path(p)}" fill="{ink}" opacity=".9"/>')
    return f'<svg xmlns="{SVG_NS}" viewBox="0 0 120 26" width="120" height="26">' + "".join(parts) + "</svg>"


# ---------- kitchen window + fridge bow (inline art from kidart.html) ----------

def mix(c1, c2, t):
    """CSS color-mix(in srgb, c1 t, c2)."""
    a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x * t + y * (1 - t)):02X}" for x, y in zip(a, b))


def window_svg(night):
    wall = "#1E2340" if night else "#FCEBD2"
    frame = mix(wall, "#A8702F", 0.82)
    frame2 = "#D9D2C4" if night else "#FFFDF8"
    sill = mix(wall, "#A8702F", 0.70)
    if night:
        sky = ('<rect x="11" y="11" width="74" height="56" rx="5" fill="#2B3466"/>'
               '<path d="M66 18a11 11 0 1 0 8 17 9 9 0 0 1-8-17z" fill="#FFE7A3"/>'
               '<circle cx="24" cy="22" r="1.4" fill="#FFE7A3"/><circle cx="36" cy="44" r="1.1" fill="#FFE7A3"/>'
               '<circle cx="20" cy="54" r="1.2" fill="#FFE7A3"/><circle cx="50" cy="26" r="1" fill="#FFE7A3"/>')
    else:
        sky = ('<rect x="11" y="11" width="74" height="56" rx="5" fill="#BFE5F1"/>'
               '<circle cx="64" cy="27" r="9.5" fill="#F8C14A"/>'
               '<path d="M19 52a6.5 6.5 0 0 1 9.5-6.5 7.5 7.5 0 0 1 14 2 5.5 5.5 0 0 1 1.5 10.5h-23a4.5 4.5 0 0 1-2-6z" fill="#FFFFFF"/>')
    return (f'<svg xmlns="{SVG_NS}" viewBox="-2 0 100 86" width="100" height="86">'
            f'<rect x="0" y="0" width="96" height="78" rx="12" fill="{frame}"/>'
            f'<rect x="6" y="6" width="84" height="66" rx="8" fill="{frame2}"/>{sky}'
            f'<rect x="45.5" y="11" width="5" height="56" fill="{frame2}"/><rect x="11" y="37" width="74" height="5" fill="{frame2}"/>'
            f'<rect x="-2" y="74" width="100" height="9" rx="4.5" fill="{sill}"/>'
            '<path d="M78 74c-7-10-5-19 0-24 1 9 2 16 2 24zm2 0c3-10 9-14 14-14-4 4-8 9-12 14z" fill="#56B37A"/>'
            '<path d="M70 66h20l-2 10h-16z" fill="#E5543C"/></svg>')


def bow_svg(p):
    return (f'<svg xmlns="{SVG_NS}" viewBox="-17 -15 34 28" width="34" height="28">'
            f'<path d="M0 0C-14-12-16 4-12 8-8 12-2 6 0 2 2 6 8 12 12 8 16 4 14-12 0 0Z" fill="{p["bb-bow"]}"/>'
            f'<circle cx="0" cy="2" r="3.6" fill="{p["bb-bow2"]}"/></svg>')


def write_imageset(out_dir, name, light_svg, dark_svg=None):
    d = os.path.join(out_dir, f"{name}.imageset")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    images = [{"filename": f"{name}.svg", "idiom": "universal"}]
    with open(os.path.join(d, f"{name}.svg"), "w") as f:
        f.write(light_svg)
    if dark_svg and dark_svg != light_svg:
        images.append({"appearances": [{"appearance": "luminosity", "value": "dark"}],
                       "filename": f"{name}-dark.svg", "idiom": "universal"})
        with open(os.path.join(d, f"{name}-dark.svg"), "w") as f:
            f.write(dark_svg)
    contents = {"images": images, "info": {"author": "xcode", "version": 1},
                "properties": {"preserves-vector-representation": True}}
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


def main():
    sprite, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(sprite) as f:
        text = re.sub(r"<!--.*?-->", "", f.read(), flags=re.S)  # comments contain "--" (invalid XML)
    root = ET.fromstring(text)
    fl = Flattener(root)
    for name, sid in EXPORTS.items():
        vb = fl.symbols[sid].get("viewBox")
        light = svg_doc(vb, fl.symbol_children(sid, LIGHT))
        dark = svg_doc(vb, fl.symbol_children(sid, NIGHT))
        write_imageset(out_dir, name, light, dark)
    for name, spec in TAPES.items():
        write_imageset(out_dir, name, tape_svg(*spec))
    write_imageset(out_dir, "kitchen-window", window_svg(False), window_svg(True))
    write_imageset(out_dir, "fridge-bow", bow_svg(LIGHT), bow_svg(NIGHT))
    print(f"wrote {len(EXPORTS) + len(TAPES) + 2} imagesets to {out_dir}")


if __name__ == "__main__":
    main()
