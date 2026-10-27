#!/usr/bin/env bash
# 整理 xcodebuild 紀錄：印出重點；失敗時把錯誤列成 GitHub 註記（Actions 頁面上直接看得到），並以 xcodebuild 的結果結束。
# 用法：ci/summarize_log.sh <紀錄檔> <xcodebuild 結束碼> <階段名稱>
LOG="$1"
STATUS="${2:-0}"
STAGE="${3:-xcodebuild}"
grep -E "error:|Test (Suite|Case)|✔|✘|[Tt]est run with|passed|failed|Upload|\*\* " "$LOG" | head -n 300 || true
# 全部錯誤／測試失敗／警告合併成多行註記（GitHub 每步驟只顯示 10 個錯誤註記）
python3 "$(dirname "$0")/annotate_log.py" "$LOG" "$STAGE" "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" || true
if [ "$STATUS" -ne 0 ]; then
  echo "----- 紀錄最後 80 行 -----"
  tail -n 80 "$LOG"
  # 編譯錯誤：附上檔案與行號
  grep -E "^/.*:[0-9]+:[0-9]+: error:" "$LOG" | sort -u | head -n 30 | while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1); ln=$(echo "$line" | cut -d: -f2); msg=$(echo "$line" | cut -d: -f5-)
    echo "::error file=${file#"$GITHUB_WORKSPACE"/},line=$ln::$STAGE:$msg"
  done
  # 簽名／上傳錯誤
  grep -E "error:|Error Domain|No profiles|No Account|requires a provisioning|Signing for" "$LOG" \
    | grep -vE "^/.*:[0-9]+:[0-9]+: error:" | grep -v "^note:" | sort -u | head -n 9 \
    | while IFS= read -r l; do echo "::error::$STAGE: ${l:0:900}"; done
fi
exit "$STATUS"
