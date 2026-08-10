#!/usr/bin/env bash
# Idempotent: safe to re-run, skips whatever is already in place.
set -euo pipefail
cd "$(dirname "$0")"

W=vendor/whisper.cpp
M="$HOME/.susurro/models"
HF=https://huggingface.co
mkdir -p "$M" "$HOME/.susurro/transcripts"
chmod 700 "$HOME/.susurro" "$HOME/.susurro/transcripts"

fetch() {  # url dest
  [ -s "$2" ] && { echo "have $(basename "$2")"; return; }
  echo "fetching $(basename "$2")"
  curl -fL --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}

# 1. whisper.cpp source
if [ ! -d "$W" ]; then
  echo "cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$W"
fi

# 2. static libs.
# GGML_METAL=OFF because the `metal` compiler ships with Xcode.app, not CommandLineTools.
# Acceleration comes from the Core ML encoder (ANE) + Accelerate BLAS + NEON instead.
if [ ! -f "$W/build-mac/src/libwhisper.a" ]; then
  echo "building whisper static libs"
  cmake -S "$W" -B "$W/build-mac" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=OFF -DGGML_BLAS_DEFAULT=ON \
    -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 >/dev/null
  cmake --build "$W/build-mac" -j
fi

# 3. models
fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" "$M/ggml-tiny.bin"
fetch "$HF/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" "$M/ggml-silero-v5.1.2.bin"
fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" "$M/ggml-large-v3-turbo.bin"

# Core ML encoder must sit beside the .bin as <model>-encoder.mlmodelc — whisper.cpp
# derives that path by string surgery and silently falls back to CPU if it is missing.
if [ ! -d "$M/ggml-large-v3-turbo-encoder.mlmodelc" ]; then
  fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip" \
        "$M/turbo-encoder.zip"
  echo "unzipping Core ML encoder"
  unzip -q -o "$M/turbo-encoder.zip" -d "$M" && rm -rf "$M/turbo-encoder.zip" "$M/__MACOSX"
fi

echo
echo "done. next: make smoke && make run"
