"""把 xcresult 匯出的截圖附件改名成 <lang>-<look>-<scenario>.png（模擬器無法直接寫檔時的備案）。

Usage: python3 ci/collect_shots.py <exported attachments dir> <shots dir>
"""
import json
import os
import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
manifest = os.path.join(src, "manifest.json")
count = 0
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for att in test.get("attachments", []):
            name = att.get("suggestedHumanReadableName") or att.get("exportedFileName")
            base = name.rsplit("_", 3)[0] if name.count("_") >= 3 else os.path.splitext(name)[0]
            shutil.copy(os.path.join(src, att["exportedFileName"]), os.path.join(dst, base + ".png"))
            count += 1
print(f"collected {count} screenshots")
