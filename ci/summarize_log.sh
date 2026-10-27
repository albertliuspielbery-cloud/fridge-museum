#!/usr/bin/env bash
# Prints the interesting lines of an xcodebuild log (errors, test results) and exits with xcodebuild's status.
# Usage: ci/summarize_log.sh <logfile> <status>
LOG="$1"
STATUS="${2:-0}"
grep -E "error:|Test (Suite|Case)|✔|✘|[Tt]est run with|passed|failed|Upload|\*\* " "$LOG" | head -n 400 || true
if [ "$STATUS" -ne 0 ]; then
  echo "::error::xcodebuild failed (exit $STATUS). Last 80 lines of the log:"
  tail -n 80 "$LOG"
  # Surface compiler errors as GitHub annotations.
  grep -E "^/.*:[0-9]+:[0-9]+: error:" "$LOG" | head -n 30 | while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1); ln=$(echo "$line" | cut -d: -f2); msg=$(echo "$line" | cut -d: -f5-)
    echo "::error file=${file#$GITHUB_WORKSPACE/},line=$ln::$msg"
  done
fi
exit "$STATUS"
