# Susurro — spec

Always-on local transcription of everything you say and hear on macOS, toggled from
the menu bar. Personal prototype. Not shipped, not sandboxed, not signed for
distribution.

## Scope

**In:** mic capture, system-audio capture, local whisper.cpp transcription, menu bar
on/off toggle, append-only daily JSONL transcripts in `~/.susurro/transcripts`.

**Out:** search UI, audio retention, diarization beyond mic-vs-system, summarization,
sync, notifications, preferences window, launch-at-login, auto-update, tests beyond one
smoke check.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| System audio | Core Audio process taps (macOS 14.2+) | Native; no virtual device, no output rerouting |
| Mic | `AVAudioEngine` input node | Stdlib for this |
| App shell | SwiftUI `MenuBarExtra`, `LSUIElement` | Proper bundle → TCC prompts actually fire |
| Build | `swiftc` + `make`, **no SwiftPM, no Xcode project** | SwiftPM is broken in this CLT install — see Toolchain |
| ASR | whisper.cpp static `.a` libs, Core ML encoder | In-process C API; ANE encoder. No xcframework needed |
| Model | `ggml-large-v3-turbo` + prebuilt Core ML encoder | Multilingual (ES/EN mixing), fast on M-series |
| VAD | whisper.cpp built-in Silero v5.1.2 | Kills whisper's silence hallucinations |
| Storage | `~/.susurro/transcripts/YYYY-MM-DD.jsonl` | Append-only, greppable |
| Sandbox | **Off** | Sandboxed app can't write `~/.susurro` |

## Toolchain constraint

This machine has **CommandLineTools only, no Xcode.app**. Verified consequences:

- `xcodebuild` absent → `build-xcframework.sh` cannot run, and there is no Xcode GUI fallback
- `xcrun metal` absent → **`GGML_METAL=OFF`**; acceleration is Core ML (ANE) + Accelerate BLAS + NEON
- **SwiftPM is broken** — even `swift package init` output fails to build, because
  `libPackageDescription.dylib` exports only `SwiftLanguageMode` overloads while the
  shipped `.swiftmodule` references `SwiftVersion`

`swiftc` itself is fine. So: plain `cmake` for whisper's static libs, plain `swiftc` for
the app, hand-assembled bundle. All three verified working (see SETUP.md § Verified).

Measured on `jfk.wav` (11.0 s of audio), Metal off:

| Model | Load | Transcribe | Ratio |
|---|---|---|---|
| `tiny`, CPU fallback | 0.3 s | 0.15 s | 73× realtime |
| `large-v3-turbo`, **Core ML encoder on ANE** | 0.67 s warm / **36 s first ever** | 0.85 s | 13× realtime |

Metal's absence is not a bottleneck — the encoder runs on the ANE and turbo has only 4
decoder layers. 13× realtime means an always-on stream never falls behind.

The 36 s figure is the one-time Core ML → ANE compilation, cached by macOS afterwards. It
is why the model loads on a background queue (see Menu bar).

## Architecture

```
AVAudioEngine input ──┐                        ┌── stream "mic"
                      ├─► Segmenter (RMS gate) ┤
Core Audio tap     ───┘   16 kHz mono f32      └── stream "system"
(global, excl. self)                    │
                                        ▼
                            Transcriber (serial queue)
                            one whisper_context, VAD on
                                        │
                                        ▼
                          ~/.susurro/transcripts/<date>.jsonl
```

Two independent capture sources, one shared transcriber. A single `whisper_context` is
not reentrant, so both streams funnel through one serial `DispatchQueue`. Segments are
seconds long; queueing is fine and halves resident memory vs. two contexts.

### Capture

Both sources normalize to **16 kHz mono Float32** via `AVAudioConverter` before hitting
the segmenter — that is whisper's native input format, so no conversion downstream.

Measured tap output on this machine: **48000 Hz, 2 ch, `mFormatFlags = 9`** — i.e.
`kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked`, so **interleaved** Float32. Not
non-interleaved (that would set bit 32). The system path therefore needs downmix +
3:1 decimation; do not assume the tap hands you 16 kHz mono.

**Mic:** `AVAudioEngine.inputNode`, `installTap(onBus: 0, bufferSize: 4096)`.

**System:** verified sequence (from `insidegui/AudioCap`):

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [ourAudioObjectID])`,
   `muteBehavior = .unmuted` (you must still hear the audio), assign `uuid`
2. `AudioHardwareCreateProcessTap(desc, &tapID)`
3. Read `kAudioTapPropertyFormat` → `AudioStreamBasicDescription` → `AVAudioFormat`
4. `AudioHardwareCreateAggregateDevice` with the default output device as
   `kAudioAggregateDeviceMainSubDeviceKey` / sole sub-device, plus
   `kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
   kAudioSubTapDriftCompensationKey: true]]`, `kAudioAggregateDeviceIsPrivateKey: true`,
   `kAudioAggregateDeviceTapAutoStartKey: true`
5. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`
6. Teardown: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
   `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`

The aggregate device is private, so it does not appear in Sound preferences.

**The aggregate device is pinned to the output device UID captured at step 4.** Switching
output (Bluetooth headphones ↔ built-in speakers) leaves it pointing at a device that is
no longer default, and capture goes silent with no error. Register an
`AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultSystemOutputDevice`
and rebuild the tap + aggregate on change. This is not optional polish — this machine's
default output is a Bluetooth device (`…:output`), which disconnects routinely.

Verified teardown order is clean (no leaked device, no crash): `AudioDeviceStop` →
`AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
`AudioHardwareDestroyProcessTap`.

### Segmenter

Per stream, ~30 lines. Frame = 20 ms.

- `speaking` when RMS > threshold (default `0.01`, tunable — see Calibration)
- flush the buffer when 700 ms of sub-threshold frames follow ≥ 300 ms of speech
- force-flush at 25 s to bound latency and stay under whisper's 30 s window
- prepend 300 ms of pre-roll so the segment doesn't clip the first phoneme
- drop segments < 300 ms

The RMS gate decides *when* to cut. Whisper's Silero VAD then decides whether the cut
contains speech at all. Two cheap layers beat one expensive one.

### Transcriber

One `whisper_context` loaded at first enable, freed on disable.

```
params.vad                 = true
params.vad_model_path      = ~/.susurro/models/ggml-silero-v5.1.2.bin
params.language            = nil          // auto-detect per segment
params.no_context          = true         // segments are independent; stops drift
params.print_realtime      = false
params.n_threads           = 4
```

`no_context = true` matters: with cross-segment context enabled, one bad transcription
poisons every subsequent one in an always-on run.

### Storage

`~/.susurro/transcripts/YYYY-MM-DD.jsonl` (local date), one line per segment, opened
`O_APPEND`, flushed per write:

```json
{"ts":"2026-08-10T14:32:07+02:00","source":"mic","dur":3.42,"lang":"es","text":"…"}
```

`source` is `"mic"` (you) or `"system"` (what you heard). Directory created `0700` at
launch. Empty-text results are not written.

## Menu bar

`MenuBarExtra` with SF Symbol `waveform` (enabled) / `waveform.slash` (disabled).

```
[✓] Listening          ⌘L      → toggles capture
    ─────────────────
    Open transcripts…          → NSWorkspace.activateFileViewerSelecting
    ─────────────────
    Quit Susurro       ⌘Q
```

**Default off, and deliberately not persisted** — an always-on recorder that silently
resumes on login is worse than one you switch on. Toggling off tears down both capture
graphs and frees the whisper context.

The model loads on a background queue, since the first ever load blocks ~36 s compiling
the Core ML encoder. The menu shows *Loading model…* meanwhile and the icon stays
`waveform.slash` until capture is actually live. A generation counter discards the
in-flight load if you toggle off before it finishes.

A failure in one source does not take the other down: if the mic is refused but the tap
works, you still get `system` lines, and the reason appears in the menu.

## Files

```
susurro/
  SPEC.md  SETUP.md  setup.sh  Makefile
  bridge.h              #include of whisper.h, via -import-objc-header
  Info.plist
  Sources/
    SusurroApp.swift    MenuBarExtra, enable/disable wiring
    Capture.swift       mic + system tap + segmenter
    Transcriber.swift   whisper context, serial queue, JSONL append
    smoke.swift         built separately, not part of the app
  vendor/whisper.cpp/   shallow clone + build-mac/
```

Three Swift files in the app. If a fourth appears, ask why.

`bridge.h` replaces a module map: `swiftc -import-objc-header bridge.h` exposes the whole
whisper C API with no wrapper target and no `import` statement.

## Calibration

The RMS threshold is hardware-dependent — a MacBook mic, a USB interface, and a
Bluetooth headset have different noise floors, and no fixed constant is right for all
three. Expose it as `~/.susurro/config.json`:

```json
{"rmsThreshold": 0.01, "silenceMs": 700, "maxSegmentSec": 25}
```

Read once at enable. No file → defaults. No UI, no watcher; toggle off/on to reload.

## Known limitations

Accepted for a prototype, listed so they are not rediscovered as bugs:

1. **Speaker echo.** On speakers, the mic hears system audio, so the same speech lands
   twice — once as `mic`, once as `system`. Use headphones. A time-overlap suppressor is
   the fix if it turns out to matter.
2. **TCC re-prompts.** With ad-hoc signing the cdhash changes on every rebuild and macOS
   may re-ask for permission. An Apple Development certificate makes it stable.
3. **Battery.** large-v3-turbo on the ANE for an 8-hour day is real power draw. Drop to
   `small` if it bites.
4. **Segment-boundary words.** A word split across a flush can be lost. Pre-roll covers
   the start, nothing covers the end.
5. **Language auto-detect per segment** can flip mid-conversation on short utterances.
   Pin `params.language` if the mixing is not actually needed.
6. **No crash recovery.** Buffered, un-flushed audio is lost on quit or crash.

## Verification

One check, `make smoke`: feed `samples/jfk.wav` (ships with whisper.cpp) through
`Transcriber` and assert the output contains `"country"`, plus a segmenter unit assert
that a synthetic tone-silence-tone buffer produces exactly 2 segments. Fails loudly if
either the model wiring or the gate logic breaks. No framework, no fixtures.

Both targets build with `-parse-as-library` and carry their own `@main`; `smoke.swift`
links `Capture.swift` + `Transcriber.swift` instead of `SusurroApp.swift`. Top-level code
is only legal in a file literally named `main.swift` once more than one file is being
compiled, so `@main` is the path of least resistance for both.

Manual acceptance: enable → say something → play a YouTube clip → confirm today's JSONL
has both a `mic` and a `system` line with sane text.
