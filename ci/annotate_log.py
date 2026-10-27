"""把 xcodebuild 紀錄裡「全部」的錯誤／測試失敗／警告整理成少數幾個多行 GitHub 註記。

GitHub 每個步驟最多只顯示 10 個錯誤註記，所以把所有錯誤合併成幾則多行訊息（API 也讀得到）。
Usage: python3 ci/annotate_log.py <log> <stage> <failed:0|1>
"""
import os
import re
import sys

log_path, stage, failed = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
ws = os.environ.get("GITHUB_WORKSPACE", "")


def clean(line: str) -> str:
    line = line.rstrip("\n")
    if ws:
        line = line.replace(ws + "/", "")
    return line.strip()[:600]


def esc(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


errors, tests, warnings = [], [], []
seen = set()
with open(log_path, errors="replace") as f:
    for raw in f:
        line = clean(raw)
        if not line or line in seen:
            continue
        # Runtime log noise from the app under test (e.g. CoreData creating the store on first launch).
        if "CoreData:" in line or re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+[+-]\d{4} ", line):
            continue
        if re.search(r"\berror:", line) or "fatal error" in line:
            seen.add(line); errors.append(line)
        elif "✘" in line or "recorded an issue" in line or re.search(r"Test Case .* failed", line):
            seen.add(line); tests.append(line)
        elif re.search(r"^[^ ]+\.(swift|metal|m|h):\d+:\d+: warning:", line):
            seen.add(line); warnings.append(line)


def emit(kind: str, title: str, lines: list, per: int, max_chunks: int):
    if not lines:
        return
    chunks = [lines[i:i + per] for i in range(0, len(lines), per)][:max_chunks]
    for n, chunk in enumerate(chunks, 1):
        head = f"{title}（{n}/{len(chunks)}，共 {len(lines)} 則）"
        print(f"::{kind} title={head}::{esc(chr(10).join(chunk))}")


if failed:
    emit("error", f"{stage}：全部錯誤", errors, 40, 5)
    emit("error", f"{stage}：測試失敗", tests, 40, 2)
emit("warning", f"{stage}：編譯警告", warnings, 50, 3)
