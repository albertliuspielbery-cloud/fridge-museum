"""印出一台可用 iPhone 模擬器的 UDID（選最新的 iOS 版本；Xcode 26 會是 iOS 26）。

Usage: xcrun simctl list devices available -j | python3 ci/pick_simulator.py
"""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
# "--ipad" first: pick an iPad instead (1.4.0 iPad screenshots); prefer the 13-inch models App Store asks for.
args = sys.argv[1:]
family = "iPhone"
if args and args[0] == "--ipad":
    family, args = "iPad", args[1:]
candidates = []
for runtime, items in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in items:
        if d.get("isAvailable", True) and d["name"].startswith(family):
            # 最新的 iOS 優先（App 最低支援 iOS 18，新版模擬器也能跑）。
            rank = (version, "13-inch" in d["name"], d["name"])
            candidates.append((rank, d["udid"], runtime, d["name"]))
if not candidates:
    sys.exit(f"::error::找不到可用的 {family} 模擬器")
candidates.sort(reverse=True)
# Optional preferred model names (argv), e.g. "iPhone 17 Pro" "iPhone 16 Pro": first match on the newest runtime wins.
for want in args:
    match = [c for c in candidates if c[3] == want]
    if match:
        candidates = match
        break
_, udid, runtime, name = candidates[0]
print(f"使用模擬器：{name}（{runtime}）", file=sys.stderr)
print(udid)
