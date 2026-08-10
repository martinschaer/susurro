# Susurro — setup

Every command below was executed on this machine (macOS 26.6 arm64, Swift 6.3.3,
CommandLineTools **without** Xcode.app) and is reported as it behaved.

## Toolchain reality

| Tool | State | Consequence |
|---|---|---|
| `swiftc` | works | app + smoke build directly, no build system |
| `cmake` + Accelerate + CoreML | works | whisper static libs build fine |
| `xcodebuild` | **absent** | `build-xcframework.sh` unusable; no Xcode GUI fallback |
| `xcrun metal` | **absent** | must build `-DGGML_METAL=OFF` |
| SwiftPM | **broken** | `swift package init` output does not build (see below) |

The SwiftPM failure is not caused by our manifest. `libPackageDescription.dylib` in this
CLT exports only `swiftLanguageModes:`/`swiftLanguageVersions: [SwiftLanguageMode]?`
overloads, while the shipped `PackageDescription.swiftmodule` references
`[SwiftVersion]?`, so every manifest fails to link:

```
Undefined symbols: PackageDescription.Package.__allocating_init(… swiftLanguageVersions: [SwiftVersion]? …)
```

**So: no `Package.swift` anywhere in this project.** Installing full Xcode would fix
SwiftPM, `xcodebuild`, and Metal — but nothing here needs it, so it stays optional.

## 1. Models

`setup.sh` fetches into `~/.susurro/models/`:

| File | From | Size |
|---|---|---|
| `ggml-large-v3-turbo.bin` | `ggerganov/whisper.cpp` | ~1.6 GB |
| `ggml-large-v3-turbo-encoder.mlmodelc` (unzip) | same repo, `.mlmodelc.zip` | ~600 MB |
| `ggml-silero-v5.1.2.bin` | `ggml-org/whisper-vad` | ~1 MB |
| `ggml-tiny.bin` | `ggerganov/whisper.cpp` | 74 MB — smoke test only |

The Core ML encoder **must** sit beside the `.bin` as `<model>-encoder.mlmodelc`;
whisper.cpp derives that path by string surgery and silently falls back to CPU when it is
missing or misnamed. With Metal off, that fallback is the whole ballgame — verify it.

Prebuilt encoders exist on HuggingFace, so no `coremltools`/`torch`.

## 2. whisper.cpp static libs

Verified working configure + build:

```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
cmake -B build-mac -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=OFF -DGGML_BLAS_DEFAULT=ON \
  -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
cmake --build build-mac -j
```

Configure reports `CoreML framework found`, `Found BLAS: Accelerate.framework`, and CPU
variant `+dotprod+i8mm`. Produces six libs we link (plus unused `libparakeet.a`):

```
build-mac/src/libwhisper.a          build-mac/ggml/src/libggml.a
build-mac/src/libwhisper.coreml.a   build-mac/ggml/src/libggml-base.a
                                    build-mac/ggml/src/libggml-cpu.a
                                    build-mac/ggml/src/ggml-blas/libggml-blas.a
```

> Homebrew's `whisper-cpp` bottle is unusable here: the formula sets
> `-DWHISPER_BUILD_SERVER=OFF` and installs CLI binaries, not linkable libraries.

## 3. Build the app

No project file. Link line, verified end to end:

```bash
swiftc -O -parse-as-library -target arm64-apple-macosx14.2 \
  -import-objc-header bridge.h -I vendor/whisper.cpp/ggml/include \
  Sources/SusurroApp.swift Sources/Capture.swift Sources/Transcriber.swift \
  -Lvendor/whisper.cpp/build-mac/src \
  -Lvendor/whisper.cpp/build-mac/ggml/src \
  -Lvendor/whisper.cpp/build-mac/ggml/src/ggml-blas \
  -lwhisper -lwhisper.coreml -lggml -lggml-base -lggml-cpu -lggml-blas \
  -framework Accelerate -framework CoreML -framework SwiftUI -lc++ \
  -o Susurro.app/Contents/MacOS/Susurro
```

`-parse-as-library` is required — `@main` cannot coexist with top-level code. `smoke.swift`
is top-level, so it compiles **without** the flag, as a second invocation.

## 4. Bundle + sign

`make app` assembles the bundle by hand (verified to launch with a live menu bar item):

```
Susurro.app/Contents/Info.plist
Susurro.app/Contents/MacOS/Susurro
```

Static libs mean nothing to embed — no `Frameworks/`, no rpath.

Required `Info.plist` keys:

```xml
<key>CFBundleExecutable</key><string>Susurro</string>
<key>CFBundleIdentifier</key><string>dev.susurro</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>                       <!-- no Dock icon -->
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSMicrophoneUsageDescription</key><string>Susurro transcribes what you say.</string>
<key>NSAudioCaptureUsageDescription</key><string>Susurro transcribes what you hear.</string>
```

`NSAudioCaptureUsageDescription` is its own TCC category, separate from microphone, and
Xcode does not list it in its dropdown. Without it the tap fails with no prompt and no
useful error.

**No `.entitlements`, no app sandbox** — sandboxing would redirect `~/.susurro/transcripts`
into the app container.

```bash
codesign --force --sign - --identifier dev.susurro Susurro.app   # verified: Signature=adhoc
```

Ad-hoc works, but the cdhash changes on every rebuild, so macOS may re-prompt for
permission each time. An Apple Development certificate makes the TCC grant stable; it
needs an Apple ID, not full Xcode.

An **unsigned** bundle launches and then never receives the audio-capture prompt.

## 5. First run

```bash
make app && open Susurro.app
```

Click the `waveform.slash` menu bar icon → **Listening**. Two prompts (mic, then system
audio). Later fixable in System Settings ▸ Privacy & Security ▸ Microphone and ▸ Screen &
System Audio Recording.

```bash
tail -f ~/.susurro/transcripts/$(date +%F).jsonl
```

## Commands

| | |
|---|---|
| `./setup.sh` | clone + cmake build + models (idempotent) |
| `make app` | swiftc, bundle, ad-hoc sign |
| `make smoke` | jfk.wav through the transcriber + segmenter assert |
| `make clean` | drop build output and `Susurro.app`; leaves `~/.susurro` alone |

## Verified

- static libs build under CLT with Metal off — 7 `.a` files
- `swiftc -import-objc-header` exposes the whisper C API with no module map
- `MenuBarExtra` compiles with `-parse-as-library`; hand-assembled ad-hoc-signed bundle
  launches with a live menu bar item
- `make smoke` passes: segmenter cuts 2 utterances from tone/silence/tone, emits nothing
  on silence, and `jfk.wav` round-trips through `Transcriber` to JSONL on disk
- language auto-detect works (`auto-detected language: en (p = 0.977611)`)
- Core ML fallback is real: with no `-encoder.mlmodelc` present, whisper logs
  `failed to load Core ML model` and continues on CPU
- `large-v3-turbo` **loads the ANE encoder** (`Core ML model loaded`) and runs
  **0.85 s per 11.0 s of audio = 13× realtime**; warm load 0.67 s, first ever load 36 s

System audio tap probed end to end with an **ad-hoc-signed, non-sandboxed** bundle
(`NSAudioCaptureUsageDescription`, `LSUIElement`, no entitlements):

```
output device #86 uid=F8-73-DF-1F-EF-25:output
AudioHardwareCreateProcessTap        -> err=0 tapID=134
tap format: 48000.0 Hz, 2 ch, flags=9        (Float32, packed, interleaved)
AudioHardwareCreateAggregateDevice   -> err=0 aggID=135
AudioDeviceCreateIOProcIDWithBlock   -> err=0
AudioDeviceStart                     -> err=0
callbacks=981 frames=1004544 peak=0.5442513
RESULT: PASS — system audio captured
torn down cleanly
```

So ad-hoc signing is sufficient for tap creation, and the teardown order leaks nothing.

**Still unconfirmed:** whether that run consumed a *fresh* TCC prompt or inherited an
existing grant. `TCC.db` is unreadable without Full Disk Access and the `com.apple.TCC`
subsystem logged nothing. If the grant was inherited via the launching Terminal, a launch
from Finder — or on another machine — may prompt where this run did not. Not a blocker;
the failure mode is a visible dialog, not silent breakage.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Tap error, no permission prompt | unsigned bundle, or missing `NSAudioCaptureUsageDescription` |
| Transcription far slower than expected | `-encoder.mlmodelc` missing/misnamed → CPU fallback, and Metal is off |
| `@main` attribute cannot be used… | missing `-parse-as-library` |
| Manifest link error re `SwiftVersion` | you reintroduced a `Package.swift`; don't |
| Every utterance duplicated as `mic` + `system` | speakers, not headphones — expected |
| Plausible sentences during silence | VAD not wired; check `vad_model_path` resolves |
| Transcripts written but folder empty | app got sandboxed; check for a stray `.entitlements` |
