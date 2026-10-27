"""印出一台可用 iPhone 模擬器的 UDID（選最新的 iOS 版本；Xcode 26 會是 iOS 26）。

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
            # 最新的 iOS 優先（App 最低支援 iOS 18，新版模擬器也能跑）。
            rank = (version, d["name"])
            candidates.append((rank, d["udid"], runtime, d["name"]))
if not candidates:
    sys.exit("::error::找不到可用的 iPhone 模擬器")
candidates.sort(reverse=True)
_, udid, runtime, name = candidates[0]
print(f"使用模擬器：{name}（{runtime}）", file=sys.stderr)
print(udid)
