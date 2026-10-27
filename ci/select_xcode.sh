#!/usr/bin/env bash
# 選用 Xcode 26（App Store 規定要用 iOS 26 SDK 打包）。找不到就直接失敗並說明。
set -euo pipefail
ls -d /Applications/Xcode*.app || true
X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$X" ]; then
  echo "::error::這台雲端電腦沒有 Xcode 26（App Store 規定要用 iOS 26 SDK），請把 runs-on 換成有 Xcode 26 的 macOS 映像"
  exit 1
fi
sudo xcode-select -s "$X/Contents/Developer"
xcodebuild -version
# Xcode 26 起 Metal 編譯工具要另外下載；我們有 Core Image 的 Metal kernel（Kernels.metal），所以先確認裝好。
if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun metal -v >/dev/null 2>&1; then
  echo "下載 Metal 編譯工具（Metal Toolchain）…"
  xcodebuild -downloadComponent MetalToolchain || echo "::warning::Metal Toolchain 下載失敗，若編譯出現 metal 相關錯誤請重跑"
fi
