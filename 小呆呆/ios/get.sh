#!/usr/bin/env bash
# 把小呆呆 App 的程式下載到 ~/代碼程式/小呆呆/ios，然後準備好 Xcode 專案
# 用法：curl -fsSL https://raw.githubusercontent.com/da33/lin-yu-fan/main/%E5%B0%8F%E5%91%86%E5%91%86/ios/get.sh | bash
set -euo pipefail

TMP_DIR=""
trap '[[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT

main() {
  local dest="$HOME/代碼程式/小呆呆/ios"
  TMP_DIR="$(mktemp -d)"
  echo "↓ 下載小呆呆程式…"
  curl -fsSL https://codeload.github.com/da33/lin-yu-fan/tar.gz/refs/heads/main | tar xz -C "$TMP_DIR"
  mkdir -p "$dest"
  # 更新程式，但保留已下載的模型和你選過的 Apple ID
  rsync -a --exclude 'Model/*.onnx' --exclude 'Model/tokens.txt' --exclude 'Local.xcconfig' \
    "$TMP_DIR/lin-yu-fan-main/小呆呆/ios/" "$dest/"
  echo "✔ 程式在 $dest"
  bash "$dest/setup-mac.sh"
}

# 整支包在 main 裡：用 curl | bash 執行時，bash 會先讀完整支才開始跑
main "$@"
