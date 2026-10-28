#!/usr/bin/env python3
"""Lists every Swift string literal that contains CJK text (candidate localization keys), with interpolations
normalised to {}; compares against Localizable.xcstrings. Usage: python3 tools/l10n_scan.py [--missing]"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ["FridgeMuseum/App", "FridgeMuseum/UI", "FridgeMuseum/ArchiveKit", "FridgeMuseum/CaptureKit", "FridgeMuseum/StoreKit"]
SKIP_FILES = {"AgeCalculator.swift", "PendingStoreStubs.swift"}
CJK = re.compile(r"[　-鿿＀-￯]")
LIT = re.compile(r'(?<![#\\])"((?:[^"\\\n]|\\.)*)"')


def norm(s):
    s = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "{}", s)
    s = re.sub(r"%(\d\$)?(lld|ld|d|@|lf|f)", "{}", s)
    return s.replace('\\"', '"').replace("\\n", "\n")


def scan():
    out = {}
    for d in DIRS:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for f in sorted(os.listdir(base)):
            if not f.endswith(".swift") or f in SKIP_FILES:
                continue
            for n, line in enumerate(open(os.path.join(base, f), encoding="utf-8"), 1):
                code = line.split("//")[0] if "//" in line and '"' not in line.split("//")[0][-1:] else line
                if code.strip().startswith("//") or code.strip().startswith("///"):
                    continue
                if "verbatim:" in code or "fatalError" in code or "nl10n" in line:
                    continue
                for m in LIT.finditer(code):
                    s = m.group(1)
                    if CJK.search(s):
                        out.setdefault(norm(s), []).append(f"{f}:{n}")
    return out


if __name__ == "__main__":
    found = scan()
    cat = json.load(open(os.path.join(ROOT, "FridgeMuseum/Resources/Localizable.xcstrings"))) if os.path.exists(
        os.path.join(ROOT, "FridgeMuseum/Resources/Localizable.xcstrings")) else {"strings": {}}
    keys = {norm(k): k for k in cat["strings"]}
    for k, locs in sorted(found.items(), key=lambda kv: kv[1][0]):
        if "--missing" in sys.argv and k in keys:
            continue
        print(f"{k!r:70} {locs[0]}{' +%d' % (len(locs) - 1) if len(locs) > 1 else ''}")
