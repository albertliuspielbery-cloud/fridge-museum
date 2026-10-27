"""Prints the UDID of an available iPhone simulator, preferring the newest iOS 18 runtime.

Usage: xcrun simctl list devices available -j | python3 ci/pick_simulator.py
"""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, items in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in items:
        if d.get("isAvailable", True) and d["name"].startswith("iPhone"):
            # Prefer iOS 18.x (matches Xcode 16), then anything newer, newest first.
            rank = (1 if version[0] == 18 else 0, version, d["name"])
            candidates.append((rank, d["udid"], runtime, d["name"]))
if not candidates:
    sys.exit("No iPhone simulator available")
candidates.sort(reverse=True)
_, udid, runtime, name = candidates[0]
print(f"Using {name} ({runtime})", file=sys.stderr)
print(udid)
