"""iPad wording (1.4.0): every string that says 手機 / phone gets a String Catalog "device" variation for iPad.

On iPad, 「存到手機」 becomes 「存到照片」, 「這支手機」 becomes 「這台 iPad」, "this phone" becomes "this iPad", and so on.
iPhone keeps the original text ("other"). Idempotent: strings that already vary by device are left alone.

Usage: python3 tools/ipad_strings.py FridgeMuseum/Resources/Localizable.xcstrings [more .xcstrings]
"""
import json
import re
import sys

ZH = [
    ("已存到手機", "已存到照片"),
    ("存到手機", "存到照片"),
    ("iPhone「設定」", "iPad「設定」"),
    ("這支手機", "這台 iPad"),
    ("這台手機", "這台 iPad"),
    ("家人手機上", "家人裝置上"),
    ("換手機", "換裝置"),
    ("手機換了", "裝置換了"),
    ("手機", "iPad"),
]
EN = [
    (r"the iPhone’s Settings", "the iPad’s Settings"),
    (r"\bon a new phone\b", "on a new device"),
    (r"\bphones\b", "devices"),
    (r"\bphone\b", "iPad"),
]


def zh_ipad(text):
    for a, b in ZH:
        text = text.replace(a, b)
    # Chinese typesetting: a space between Han characters and "iPad", none next to full-width punctuation.
    text = re.sub(r"(?<=[一-鿿])iPad", " iPad", text)
    text = re.sub(r"iPad(?=[一-鿿])", "iPad ", text)
    return text


def en_ipad(text):
    for a, b in EN:
        text = re.sub(a, b, text)
    return text


def mentions_phone(key, en_values):
    return "手機" in key or any(re.search(r"\bphones?\b|iPhone’s Settings", v) for v in en_values)


def string_values(loc):
    """All stringUnit values inside a localization (plain or with variations)."""
    out = []
    if "stringUnit" in loc:
        out.append(loc["stringUnit"].get("value", ""))
    for var in loc.get("variations", {}).values():
        for case in var.values():
            out.extend(string_values(case))
    return out


def transform(loc, fn):
    """A deep copy of a localization with every stringUnit value passed through fn."""
    loc = json.loads(json.dumps(loc))

    def walk(node):
        if "stringUnit" in node:
            node["stringUnit"]["value"] = fn(node["stringUnit"]["value"])
        for var in node.get("variations", {}).values():
            for case in var.values():
                walk(case)
    walk(loc)
    return loc


def plain(loc):
    """The fallback ("other") can't vary further: a plural localization falls back to its "other" case."""
    if "stringUnit" in loc:
        return loc
    for var in loc.get("variations", {}).values():
        return plain(var.get("other") or next(iter(var.values())))
    return loc


def by_device(loc, ipad):
    if "variations" in loc:  # e.g. plural: vary per device, and keep a plain fallback
        return {"variations": {"device": {"iphone": loc, "ipad": ipad, "other": plain(loc)}}}
    return {"variations": {"device": {"ipad": ipad, "other": loc}}}


def main(path):
    data = json.load(open(path, encoding="utf-8"))
    source = data.get("sourceLanguage", "zh-Hant")
    changed = 0
    for key, entry in data["strings"].items():
        locs = entry.setdefault("localizations", {})
        en = locs.get("en")
        if not mentions_phone(key, string_values(en) if en else []):
            continue
        if any("device" in l.get("variations", {}) for l in locs.values()):
            continue
        # Source language: the key itself is the text unless a localization already exists.
        src = locs.get(source) or {"stringUnit": {"state": "translated", "value": key}}
        if zh_ipad(json.dumps(src, ensure_ascii=False)) != json.dumps(src, ensure_ascii=False):
            locs[source] = by_device(src, transform(src, zh_ipad))
        if en is not None:
            ipad = transform(en, en_ipad)
            if ipad != en:
                locs["en"] = by_device(en, ipad)
        changed += 1
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")
    print(f"{path}: {changed} strings vary by device")


for p in sys.argv[1:]:
    main(p)
