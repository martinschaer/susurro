#!/usr/bin/env bash
# Fetches the ~2.8 GB of models into ~/.susurro/models. Idempotent: safe to re-run,
# skips whatever is already there and resumes whatever was half-done.
#
# Standalone on purpose. setup.sh calls it as its model step, and the Makefile copies it
# into Susurro.app/Contents/Resources so the app can run it when a tester has no repo.
# Nothing here may reference the build (vendor/, swiftly, cmake).
#
# stdout is one line per file, quiet enough to show in a menu; curl's progress bar goes
# to stderr. The app relies on that split.
set -euo pipefail

M="$HOME/.susurro/models"
HF=https://huggingface.co
mkdir -p "$M" "$HOME/.susurro/transcripts"
chmod 700 "$HOME/.susurro" "$HOME/.susurro/transcripts"

fetch() {  # url dest
  [ -s "$2" ] && { echo "have $(basename "$2")"; return; }
  echo "fetching $(basename "$2")"
  # -C - resumes a .part left by a killed run: 1.5 GB is a long way to fall back down.
  curl -fL -C - --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}

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

# Speaker embedding models. FluidAudio would fetch these itself on first use, but an
# always-on recorder must not block on the network mid-session, so pull them up front.
# .mlmodelc is a directory, hence the inner loop.
for m in pyannote_segmentation wespeaker_v2; do
  mkdir -p "$M/$m.mlmodelc/analytics" "$M/$m.mlmodelc/weights"
  for f in analytics/coremldata.bin coremldata.bin metadata.json model.mil weights/weight.bin; do
    fetch "$HF/FluidInference/speaker-diarization-coreml/resolve/main/$m.mlmodelc/$f" \
          "$M/$m.mlmodelc/$f"
  done
done

echo "models ready"
