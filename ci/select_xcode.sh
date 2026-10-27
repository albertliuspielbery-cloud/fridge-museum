#!/usr/bin/env bash
# Selects Xcode 16.x on the GitHub macOS runner (newest installed 16.x), or XCODE_PATH if set.
set -euo pipefail
if [[ -n "${XCODE_PATH:-}" ]]; then
  XC="$XCODE_PATH"
else
  XC=$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1 || true)
fi
if [[ -z "$XC" ]]; then
  echo "::warning::No Xcode 16.x found; using the runner default."
else
  sudo xcode-select -s "$XC/Contents/Developer"
fi
xcodebuild -version
