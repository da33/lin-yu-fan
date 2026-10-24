#!/usr/bin/env bash
# 下載小呆呆的喚醒詞模型（sherpa-onnx 中文關鍵詞偵測，壓縮檔約 36 MB，留下約 5 MB）
set -euo pipefail
cd "$(dirname "$0")"

NAME=sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/$NAME.tar.bz2"
SHA256=b2f7c89690dc8ce4c6ed6afeab7cd800c36ad1421fb6b6302b4a4b194cf7f35f

if [[ -s Model/encoder.int8.onnx && -s Model/decoder.int8.onnx && -s Model/joiner.int8.onnx && -s Model/tokens.txt ]]; then
  echo "✔ 喚醒詞模型已經在了"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "↓ 下載喚醒詞模型（約 36 MB）…"
curl -fL --retry 3 -o "$tmp/model.tar.bz2" "$URL"
actual="$(shasum -a 256 "$tmp/model.tar.bz2" | cut -d' ' -f1)"
[[ "$actual" == "$SHA256" ]] || { echo "✖ 模型檔案驗證失敗（下載不完整？）再跑一次" >&2; exit 1; }
tar xjf "$tmp/model.tar.bz2" -C "$tmp"
mkdir -p Model
cp "$tmp/$NAME/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" Model/encoder.int8.onnx
cp "$tmp/$NAME/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" Model/decoder.int8.onnx
cp "$tmp/$NAME/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" Model/joiner.int8.onnx
cp "$tmp/$NAME/tokens.txt" Model/tokens.txt
echo "✔ 喚醒詞模型好了"
