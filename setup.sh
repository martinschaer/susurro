#!/usr/bin/env bash
# Idempotent: safe to re-run, skips whatever is already in place.
set -euo pipefail
cd "$(dirname "$0")"

W=vendor/whisper.cpp
FA=vendor/fluidaudio
FA_TAG=v0.15.5
FA_REL="$FA/.build/arm64-apple-macosx/release"
SWIFT="$HOME/.swiftly/bin/swift"

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

# 3. FluidAudio, for speaker embeddings.
# SwiftPM is used here and nowhere else — purely to produce a static lib, exactly like
# cmake does for whisper above. The app itself still builds with plain swiftc.
# It needs a swift.org toolchain: the CommandLineTools SwiftPM cannot link its own
# manifests (see SETUP.md), so bare `swift` is not good enough.
if [ ! -d "$FA" ]; then
  echo "cloning FluidAudio $FA_TAG"
  git clone --depth 1 --branch "$FA_TAG" https://github.com/FluidInference/FluidAudio "$FA"
fi

if [ ! -f "$FA_REL/libFluidAudio.a" ]; then
  [ -x "$SWIFT" ] || {
    echo "missing $SWIFT — install swiftly; CommandLineTools' SwiftPM cannot build this"
    exit 1
  }
  echo "building FluidAudio"
  (cd "$FA" && "$SWIFT" build -c release --product FluidAudio)
  # SwiftPM emits loose objects for a library product, never an archive. Roll them up
  # with the two C wrapper targets so the Makefile links one file.
  libtool -static -o "$FA_REL/libFluidAudio.a" \
    "$FA_REL"/FluidAudio.build/*.o \
    "$FA_REL"/FastClusterWrapper.build/*.o \
    "$FA_REL"/MachTaskSelfWrapper.build/*.o
fi

# 4. models — the only part a distributed app also needs.
./models.sh

echo
echo "done. next: make smoke && make run"
