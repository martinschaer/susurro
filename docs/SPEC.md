# Susurro — spec

Always-on local transcription of everything you say and hear on macOS, toggled from
the menu bar. Personal prototype, handed to beta testers as an ad-hoc-signed zip
(`make dist`, see docs/INSTALL.md). Not sandboxed, not notarised, not in any store.

## Scope

**In:** mic capture, system-audio capture, local whisper.cpp transcription, per-speaker
labels on the system stream that persist across days, menu bar on/off toggle, append-only
per-meeting JSONL transcripts in `~/.susurro/transcripts`.

**Out:** search UI, audio retention, splitting two speakers *inside* one segment,
summarization, sync, notifications, preferences window, launch-at-login, auto-update,
tests beyond one smoke check.

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
| Speakers | FluidAudio (pyannote community-1 + WeSpeaker) via Core ML | 256-d embeddings on the ANE; matching layer already tuned |
| Speaker identity | Cosine match against `~/.susurro/speakers.json` | Diarizers renumber every run; only a persisted embedding survives the night |
| Storage | `~/.susurro/transcripts/YYYY-MM-DD_HH-MM-SS.jsonl` | Append-only, greppable, one file per meeting |
| Sandbox | **Off** | Sandboxed app can't write `~/.susurro` |

## Toolchain constraint

This machine has **CommandLineTools only, no Xcode.app**. Verified consequences:

- `xcodebuild` absent → `build-xcframework.sh` cannot run, and there is no Xcode GUI fallback
- `xcrun metal` absent → **`GGML_METAL=OFF`**; acceleration is Core ML (ANE) + Accelerate BLAS + NEON
- **CommandLineTools' SwiftPM is broken** — even `swift package init` output fails to
  build, because `libPackageDescription.dylib` exports only `SwiftLanguageMode` overloads
  while the shipped `.swiftmodule` references `SwiftVersion`

A **swiftly** toolchain (`~/.swiftly/bin`) ships a working SwiftPM, which is how
`vendor/fluidaudio` becomes a static lib. It does not ship `metal` or `xcodebuild`, so the
other two constraints stand. The two `swiftc` binaries both claim 6.3.3 but are different
builds, and CLT's cannot read modules swiftly's SwiftPM produced — so the Makefile pins
swiftly's for everything.

So: `cmake` for whisper's libs, SwiftPM-out-of-tree for FluidAudio's, plain `swiftc` for
the app, hand-assembled bundle. No `Package.swift` in this project. All verified working
(see SETUP.md § Verified).

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
                          ┌─────────────┴──── source == "system"
                          │                            │
                          │                   SpeakerBook (embed + match)
                          │                   ~/.susurro/speakers.json
                          ▼                            │
                          └────────────┬───────────────┘
                                       ▼
                          ~/.susurro/transcripts/<date_time>.jsonl
```

Two independent capture sources, one shared transcriber. A single `whisper_context` is
not reentrant, so both streams funnel through one serial `DispatchQueue`. Segments are
seconds long; queueing is fine and halves resident memory vs. two contexts.

`SpeakerBook` hangs off the same queue, which is also what makes it thread-safe —
`SpeakerManager` is a struct mutated in place, with no lock anywhere.

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

### Speakers

`Segmenter` cuts on 700 ms of silence, and a conversational turn normally ends with a
pause — so an emitted segment is usually one person. That removes the expensive half of
diarization: embed the whole segment as a single speaker, no segmentation pass, no
clustering. `DiarizerManager.extractSpeakerEmbedding` does exactly this, feeding an
all-ones frame mask to WeSpeaker and returning a 256-d L2-normalized vector.

`SpeakerManager` then cosine-matches it against the gallery, mints `user-N` on a miss, and
refines the matched centroid by EMA. Defaults worth knowing:

```
speakerThreshold           = 0.35      // config.json; <0.3 is a confident match
embeddingThreshold         = 0.25      // config.json; above this a match does not
                                       //   refine the centroid, only its duration
settled                    = 20        // EMA updates, then the voiceprint is frozen
minSpeechDuration          = 1.0 s     // below this: match, never enroll
minEmbeddingUpdateDuration = 2.0 s     // below this: match, never update the centroid
```

Those two floors are the guard against gallery rot. A sub-second grunt makes a bad
centroid, and a bad centroid mismatches everything after it.

`embeddingThreshold` is the guard against the slower rot, and FluidAudio's 0.45 default is
wrong for a gallery that lives for weeks. Every match under it EMA-blends the segment into
the stored voiceprint at `alpha: 0.9`. Measured p50 distance on real calls is 0.23, so at
0.45 nearly every segment rewrites the centroid: it walks toward whoever is speaking now,
converges on the average voice in the room, and from then on sits within `speakerThreshold`
of everybody — so `assignSpeaker` never takes the create branch again. Five days of real
meetings produced two entries whose own stored exemplars were further apart (p50 0.449)
than the two entries were from each other (0.423). Offline clustering of those same
exemplars finds six to eleven voices. Keep the blend rare and the voiceprint stays the
person who enrolled it.

`embeddingThreshold` caps one hop, and nothing caps their sum — which is the rot it does
*not* stop. The hops compound in one direction, so a voiceprint keeps sliding at 0.25 the
way it sprinted at 0.45, just slower. Measured on a real gallery: 50 hops moved a centroid
0.23 from where it started, and one entry's own exemplars ran from 0.09 to 0.43 of its
first — a step, dated a week later, where a second person arrived and was absorbed. So a
voiceprint is frozen after `settled` updates. At `alpha: 0.9` the mean is 88% converged by
then; every hop after that is chasing the room, not learning the person.

`speakerThreshold` was 0.45, and that was too loose. Scoring a real gallery — same-speaker
exemplar pairs against different-speaker pairs — the two distributions separate cleanly,
same-speaker at p95 0.33 and different-speaker at p05 0.41. 0.45 sits inside the
different-speaker distribution: about 10% of pairs drawn from two different people fall
under it, which is how strangers end up sharing a `user-N`. 0.35 sits in the gap.

**Clips are hard-capped at 10 s** before they reach the extractor. That is not a
preference: the extractor copies its input into a `[3, 160000]` batch buffer with no
clamp, so a longer clip writes over the neighbouring batch slots. Only slot 0 is read
back, so trimming loses nothing.

The gallery is written on new-speaker creation and on `close()` — never per segment.
Losing a little centroid drift to a crash is cheap; losing a speaker is not.

Missing speaker models degrade to `speaker:"unknown"` and a menu-bar note. They never cost
you the transcript.

### Storage

`~/.susurro/transcripts/YYYY-MM-DD_HH-MM-SS.jsonl` (local time of the file's first line),
one line per segment, appended, `fsync`ed per write:

```json
{"ts":"2026-08-10T14:32:07+02:00","source":"system","speaker":"user-2","dist":0.31,"dur":3.42,"lang":"es","text":"…"}
```

`source` is `"mic"` (you) or `"system"` (what you heard). `speaker` is `"me"` for the mic
stream — no embedding beats knowing which microphone it came from — and `user-N`,
a name from `speakers.json`, or `"unknown"` for the system stream.

`dist` is the cosine distance to the matched speaker, and it is written **so that a bad
day is re-clusterable offline** rather than baked into the transcript. It is absent when
nothing matched, which is also a hard requirement: a miss reports `.infinity`, and
`JSONEncoder` throws on non-finite doubles, which would silently drop the line.

Directory created `0700` at launch. Empty-text results are not written.

One file is one meeting, not one day. A new file starts when Listening is toggled on, and
whenever neither stream produced speech for longer than `sessionGapMin` (default 5). The
split needs no timer: nothing runs during silence, so the gap between one written line and
the next *is* the measurement. A meeting that crosses midnight stays in one file — the
file is named for its first line, and `ts` carries the real date of every line. Files are
created on first write, so a session where nobody spoke leaves nothing behind.

## Menu bar

`MenuBarExtra` with SF Symbol `waveform` (enabled) / `waveform.slash` (disabled).

```
[✓] Listening          ⌘L      → toggles capture
    ─────────────────
    Open transcripts…          → NSWorkspace.activateFileViewerSelecting
    Name speakers…             → one Window scene: roster, then one voice at a time
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
    Speaker.swift       embedding + persisted gallery
    smoke.swift         built separately, not part of the app
  vendor/whisper.cpp/   shallow clone + build-mac/
  vendor/fluidaudio/    shallow clone at v0.15.5 + .build/ (SwiftPM -> one .a)
```

Four Swift files in the app. The fourth is `Speaker.swift`, and the why is that model
loading plus a persisted gallery is a different lifecycle from the whisper context —
inlining it would blur the one thing `Transcriber.swift` currently does well. If a fifth
appears, ask why.

`bridge.h` replaces a module map: `swiftc -import-objc-header bridge.h` exposes the whole
whisper C API with no wrapper target and no `import` statement.

## Calibration

The RMS threshold is hardware-dependent — a MacBook mic, a USB interface, and a
Bluetooth headset have different noise floors, and no fixed constant is right for all
three. Expose it as `~/.susurro/config.json`:

```json
{"rmsThreshold": 0.01, "silenceMs": 700, "maxSegmentSec": 25, "speakerThreshold": 0.35,
 "embeddingThreshold": 0.25, "sessionGapMin": 5}
```

`speakerThreshold` is calibration for the same reason: what a conferencing codec does to a
voice varies by platform. FluidAudio suggests 0.6–0.8, but that is tuned for clustering one
recording; a gallery that has to still be right next month wants tighter. Raise it if one
person keeps splitting into two `user-N`; lower it if two people keep merging. Splitting is
the better failure — type the same name into both entries and they read as one person,
whereas nothing recovers a transcript that filed two people under one.

`embeddingThreshold` should stay well under it, for the reason above.

`sessionGapMin` is where a transcript file ends: minutes of silence on both streams before
the next line goes to a new file. Too low and one meeting with a long lull becomes two
files; too high and two back-to-back meetings become one.

Read once at enable. No file → defaults. No UI, no watcher; toggle off/on to reload.

Naming is not: *Name speakers…* lists the gallery read-only — a `user-N` and either its
name or `unnamed` — because a bare id is unnamable; nobody remembers which id was Ana.
Clicking a row opens that one voice: a name field, and 10 lines sampled at random from the
transcripts where it appears, with a button for another 10. Clicking a line expands it to
the turn either side, labelled with who said it — `me` on both sides means this voice was
answering you, which places it faster than the line alone does. Neighbours come from the
same file, so never across meetings; segments are cut on silence, so "the line before" is
sometimes the same person's previous segment rather than somebody else's turn. That is the
identification — you recognise what somebody said, and who they said it to. From the rename on, every later line says `Ana`. Lines
already written keep the old label, so the sample matches both `user-N` and the current
name. Hand-editing `name` in `~/.susurro/speakers.json` still works and is the same
operation — the window is only a read-modify-write of that file, which is why it needs no
models loaded and works with Listening off. Reading the snippets is the same trick applied
to the transcripts: a directory scan and a JSONL decode, no whisper context. `SpeakerBook` re-reads the names before it writes, so a rename survives the
running session flushing its drifted centroids; it reaches the live labels at that flush,
not the instant you click Save. The transcripts are append-only; nothing rewrites a label
that is already on disk.

## Known limitations

Accepted for a prototype, listed so they are not rediscovered as bugs:

1. **Speaker echo.** On speakers, the mic hears system audio, so the same speech lands
   twice — once as `mic`, once as `system`. Use headphones. A time-overlap suppressor is
   the fix if it turns out to matter. Speaker labels make this worse, not better: on
   speakers your own voice also enrolls in the gallery as a `system` speaker.
2. **TCC re-prompts.** With ad-hoc signing the cdhash changes on every rebuild and macOS
   may re-ask for permission. An Apple Development certificate makes it stable.
3. **Battery.** large-v3-turbo on the ANE for an 8-hour day is real power draw. Drop to
   `small` if it bites.
4. **Segment-boundary words.** A word split across a flush can be lost. Pre-roll covers
   the start, nothing covers the end.
5. **Language auto-detect per segment** can flip mid-conversation on short utterances.
   Pin `params.language` if the mixing is not actually needed.
6. **No crash recovery.** Buffered, un-flushed audio is lost on quit or crash, along
   with centroid drift since the last new speaker.
7. **Two speakers in one segment** get one label — whoever the averaged embedding lands
   nearest. The RMS gate cuts on silence, and interruptions do not have any. The fix is to
   run `pyannote_segmentation` on the segment and split it, roughly doubling the pipeline;
   gate that on evidence from real transcripts, not on principle.
8. **Cross-day identity degrades.** Same call, same day is the easy case. Across days,
   low-bitrate Opus, noise suppression and AGC distort exactly the spectral detail the
   embedding keys on — the same person on Zoom vs. in the room can land further apart than
   two different people on one platform. Expect it to hold for 5–10 recurring colleagues
   and to start false-merging as strangers accumulate, since each false merge poisons a
   centroid and causes the next. `dist` in the JSONL is there so a bad stretch can be
   re-clustered offline.
9. **A voice renamed twice loses its middle-era snippets.** The transcripts record the
   label as it was at write time, and only the current name plus `user-N` are searched, so
   the lines written under a discarded name are not sampled. Renaming once — the normal
   case — is unaffected.
10. **`speakers.json` is a voiceprint database** of people who agreed to be in a meeting,
   not to this. It lives at `0700`/`0600` beside the transcripts, and deleting the file
   forgets everyone.

## Verification

One check, `make smoke`: feed `samples/jfk.wav` (ships with whisper.cpp) through
`Transcriber` and assert the output contains `"country"`, plus a segmenter unit assert
that a synthetic tone-silence-tone buffer produces exactly 2 segments. Fails loudly if
either the model wiring or the gate logic breaks. No framework, no fixtures.

The same audio also goes down the `system` stream twice, asserting `me` / `user-1` /
`user-1` — minting and matching are different branches — that the gallery survives a
reopen, and that a decimated (~1.2× pitch) copy becomes `user-2`. That last one is the
only check that catches an embedder returning a constant vector, which would collapse
everyone into `user-1` while every other assertion still passed.

The snippet checks need no models at all. Two hand-written JSONL fixtures assert that an
unnamed voice matches only its `user-N` lines and a renamed one both its name and its
`user-N` lines, that both files are scanned, and that context is the genuinely adjacent
line: a match at a file boundary reports no neighbour, and one next to an undecodable line
reports no neighbour rather than the next readable line along. That last one is the whole
reason the decode keeps `[Line?]` instead of compacting — with `compactMap` it fails,
quoting the wrong speaker.

Both targets build with `-parse-as-library` and carry their own `@main`; `smoke.swift`
links `Capture.swift` + `Transcriber.swift` instead of `SusurroApp.swift`. Top-level code
is only legal in a file literally named `main.swift` once more than one file is being
compiled, so `@main` is the path of least resistance for both.

Manual acceptance: enable → say something → play a YouTube clip → confirm the newest JSONL
has both a `mic` and a `system` line with sane text, the mic lines say `me`, and the clip's
voices got `user-N`. Then join a call with two other people and check the two of them do
not collapse into one `user-N` — if they do, lower `speakerThreshold`, and check
`embeddingThreshold` is not letting the centroids wander. A gallery already collapsed
cannot be tuned back out of it: a centroid that has become the room's average voice stays
within any usable threshold of everybody, so delete `~/.susurro/speakers.json` and let it
re-enrol.

That collapse is not reproducible in `smoke.swift`: it needs hundreds of genuinely
different voices, and one `jfk.wav` pitch-shifted cannot fake them. The smoke check covers
the knob (at 0 no match may touch a stored voiceprint, at 1 every match must); the
behaviour itself is checked against `speakers.json` after a real call.
