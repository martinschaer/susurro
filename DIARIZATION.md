# Diarization beyond mic-vs-system

Research notes, 2026-08-10. No app code changed. Verified against this machine's toolchain
and the vendored whisper.cpp; model specs read from the models' own metadata, not from blog
posts.

**Revised after swiftly was installed** — that flips the recommendation from B to C. The
original reasoning and the reversal are both kept below, since the *reason* B was
recommended was a toolchain accident, not a technical judgement about the libraries.

> **Status: steps 0 and 1 are implemented** on option C — see SPEC.md § Speakers.
> `speaker` and `dist` are in the JSONL, the gallery lives at `~/.susurro/speakers.json`,
> and `make smoke` covers minting, matching, reload, and discrimination. Steps 2 (naming)
> and 3 (splitting a segment) are not built; step 2 is already usable by hand-editing
> `name` in `speakers.json`.

## The short version

**Recommendation: use the FluidAudio SDK (option C).** With swiftly installed, SwiftPM works,
and FluidAudio's `extractSpeakerEmbedding(from:)` + `SpeakerManager` is exactly the pipeline
I was otherwise going to hand-write — already tuned, already tested, and `Speaker: Codable`
so the cross-day gallery is one `JSONEncoder` call.

Crucially, **this does not force SwiftPM into susurro's build.** SwiftPM is used once, out of
tree, to produce a static `.a`; the app still builds with plain `swiftc`. That's structurally
identical to what SPEC.md already does with cmake and whisper's libs. Verified end to end
today — see *Integration, verified* below.

**Skip tinydiarize.** It answers neither of your questions and costs a model downgrade.

Two things you asked about are actually two different problems, and conflating them is the
main trap here:

| | What it answers | Gives you cross-day identity? |
|---|---|---|
| **Diarization** | "the speaker changed here", "these turns are the same person *within this recording*" | **No.** Labels are session-local and arbitrary. |
| **Speaker recognition** | "this voice is the same one I heard on Tuesday" | Yes — it *is* the definition. |

Off-the-shelf diarization gives you `speaker_0 … speaker_N` per recording, renumbered every
time. To carry `user-1` across days you need the *embeddings* the diarizer computes
internally, persisted and matched. So: not out of the box, but also not a new project.

That is the whole selection criterion. **Anything that hands you only labels is a dead end for
your second question.** tinydiarize is exactly that dead end.

## Why susurro makes this unusually easy

Normal diarization pipelines have to solve "where are the speaker boundaries in this 45-minute
file". Susurro already did most of that: `Segmenter` (`Sources/Capture.swift:39`) cuts on 700 ms
of sub-threshold RMS after ≥300 ms of speech. In a conversation, a turn usually *ends* with a
pause, so **most emitted segments are already one speaker**.

So the lazy version doesn't need a diarizer at all:

```
segment (already single-speaker, mostly)
   └─► embedding model ──► 256-d vector ──► cosine match vs. gallery ──► "user-2"
```

No segmentation model, no powerset decoding, no clustering pipeline. Add them later only if
interruption-heavy calls turn out to actually be a problem (step 3).

`source:"mic"` stays what it is — that's *you*, and more reliable than any embedding. Only the
`system` stream needs speaker labels.

---

## Options

### A. tinydiarize (`-tdrz`) — **no**

You asked to consider it. I did; it doesn't fit, for four independent reasons, any one of
which is fatal.

The C API is present in the vendored tree (`vendor/whisper.cpp/include/whisper.h:518`,
`:647`), so wiring it up would be trivial:

```c
bool tdrz_enable;                                            // whisper.h:518
bool whisper_full_get_segment_speaker_turn_next(ctx, i);     // whisper.h:647
```

But:

1. **It marks turn boundaries, not speakers.** Upstream says so directly: *"Only local
   diarization (segmentation into speaker turns) is handled so far. Extension with global
   diarization (speaker clustering) is planned for later"* — written in 2023, never shipped.
   With 3 remote participants you learn *that* the voice changed, never *which* of the three
   it is. You cannot even reliably alternate A/B/A/B, because you don't know whether turn 3 is
   person A returning or person C arriving.
2. **No embeddings.** Your cross-day question isn't just unanswered on this path, it's
   unanswerable.
3. **It's a different model.** `-tdrz` only works with `small.en-tdrz`
   (`models/download-ggml-model.sh:48`). You'd trade `large-v3-turbo` for `small` **and**
   multilingual for **English-only** — killing the ES/EN mixing that SPEC.md names as the
   reason for the current model choice. Running both means a second `whisper_context`: double
   the resident model and double the ANE work per segment, for boundary marks.
4. **It's an abandoned prototype.** Upstream calls it "an early functional prototype done for
   the small.en models". No successor exists.

Also worth knowing so nobody re-suggests it: whisper.cpp's other flag, `--diarize` / `-di`, is
**stereo channel separation** — it labels by left/right channel. Fine for an interview recorded
on two mics, useless for a downmixed conference call.

**Verdict: dead end for both questions.**

### C. FluidAudio SDK — **recommended** (was blocked, now isn't)

FluidAudio ships the pyannote community-1 models as CoreML plus the Swift layer around them.
The relevant API is almost suspiciously on-target — its own doc comment describes your use
case:

```swift
/// Extract a 256-dimensional speaker embedding from audio samples.
/// Use this to build a `Speaker` for `initializeKnownSpeakers()` from a recording
/// of a single known speaker.
/// - Parameter audio: Audio samples (16kHz mono) of a single speaker
/// - Returns: L2-normalized 256-dimensional embedding
public func extractSpeakerEmbedding<C>(from audio: C) throws -> [Float]
```

Internally that builds an **all-ones frame mask** and runs the embedding model — which is
precisely the "assume one speaker per segment" shortcut I'd designed for option B, except
already written. Then:

```swift
SpeakerManager(speakerThreshold: 0.65,          // max cosine distance to match
               embeddingThreshold: 0.45,
               minSpeechDuration: 1.0,          // min seconds to mint a new speaker
               minEmbeddingUpdateDuration: 2.0)
let speaker = speakerManager.assignSpeaker(embedding, speechDuration: 3.0)
speaker?.name = "Alice"
speakerManager.initializeKnownSpeakers([alice, bob], mode: .overwrite)
```

`SpeakerManager` also does EMA centroid refinement and keeps up to 50 raw embeddings per
speaker for recomputation — both things I'd have skipped in a hand-rolled version and then
missed later.

**`Speaker` is `Codable`.** So the cross-day gallery, the part that isn't in any of these
libraries, is:

```swift
try JSONEncoder().encode(Array(speakerManager.getAllSpeakers().values))
```

Measured at ~3.9 KB per speaker with embedding history included.

Licence: SDK Apache 2.0, models `cc-by-4.0` (attribution).

#### Integration, verified

The concern that made me recommend B — "SwiftPM-only, and SwiftPM is broken" — is gone, and
the follow-on concern that adopting it would drag susurro's whole build into SwiftPM turns out
to be false. Tested today, all of it:

- `swiftly` 1.1.3 with Swift 6.3.3-RELEASE. `swift build` on a fresh package **succeeds**
  (CLT's SwiftPM still fails at the ABI level; see the correction below).
- FluidAudio builds clean from `main`: 260 modules, 67 s debug / 136 s release.
- `libtool -static` over `FluidAudio.build/*.o` + the two C wrapper targets +
  `libtext_processing_rs.a` → one 90 MB archive.
- Plain `swiftc` then links against it with four `-I` paths and `-lc++` — **`-lc++` is already
  in the Makefile's `LINK`**. Ran the result; `assignSpeaker` returned, gallery round-tripped
  through `Codable`.

So the build shape stays exactly as SPEC.md describes it: `setup.sh` gains a `swift build`
step next to the existing cmake step, `Makefile` gains include paths and one `.a`. No
`Package.swift` for susurro, no Xcode project.

**Two gotchas, both one-liners, both confusing if you hit them cold:**

1. **CLT's `swiftc` cannot read swiftly-built modules.** `/usr/bin/swiftc` and
   `~/.swiftly/bin/swiftc` are both "6.3.3" but different builds, and the module format
   rejects the mismatch:
   ```
   error: compiled module was created by an older version of the compiler;
          rebuild 'FluidAudio' and try again
   ```
   The Makefile calls bare `swiftc`, which today resolves to `/usr/bin/swiftc` in a
   non-interactive shell. Pin it: `SWIFTC := $(HOME)/.swiftly/bin/swiftc …` or ensure
   `~/.swiftly/bin` leads `PATH` for `make`.
2. **Models download at runtime.** `DiarizerModels.download(to:)` fetches from HuggingFace on
   first use, unlike `setup.sh`'s up-front model fetch. Call it from `setup.sh` so an
   always-on recorder never blocks on the network mid-session.

#### Correction to the earlier note

I previously wrote that installing a Swift toolchain "also fixes `xcrun metal` and would let
you turn `GGML_METAL=ON`". **That's wrong.** swiftly ships a Swift toolchain, not the Metal
developer tools:

```
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
xcrun: error: unable to find utility "xcodebuild", not a developer tool or in PATH
```

`GGML_METAL=OFF` still stands, and still doesn't matter — SPEC.md's own measurements show the
ANE encoder path at 13× realtime.

### B. Driving the CoreML models directly — **good fallback, no longer the default**

`FluidInference/speaker-diarization-coreml` publishes the same models as plain `.mlmodelc`
bundles. These are just files; `MLModel(contentsOf:)` loads them from bare Swift with no
package manager at all. Verified from their `metadata.json`:

| Model | Size | Input | Output |
|---|---|---|---|
| `FBank.mlmodelc` | 1.8 MB | `[1…32, 1, 160000]` f32 — **exactly 10 s @ 16 kHz** | `[N, 1, 80, 998]` fbank |
| `Embedding.mlmodelc` | 13.5 MB | fbank `[N,1,80,998]` + `weights [N,589]` | `embedding` — 256-d |
| `Segmentation.mlmodelc` | 6.0 MB | `[1…32, 1, 160000]` f32 | `log_probs` (powerset, 589 frames) |

Things that will cost you an afternoon if you take this route:

- **10 s windows are mandatory.** FBank's input shape is fixed at 160000 samples. Shorter
  segments zero-pad; longer ones (susurro allows 25 s) chunk into 10 s windows with embeddings
  averaged. Batch dim goes to 32, so a 25 s segment is one batched call.
- **The `weights [589]` input is the per-frame speaker mask.** Feed all-ones to treat the whole
  clip as one speaker. (This is verbatim what FluidAudio's `extractSpeakerEmbedding` does.)
- **Input is 16 kHz mono Float32** — byte-identical to what `Segmenter.emit` already hands
  `Transcriber.submit`.
- **Language-independent** — "trained on acoustic signatures", so ES/EN mixing is a non-issue.
- **Not gated.** Upstream `pyannote/speaker-diarization-community-1` needs an HF login and
  accepted terms; I hit that wall while researching. The FluidInference conversion downloads
  anonymously.
- **Accuracy.** pyannote 3.1 sits around 12–14 % DER on AMI (meeting audio — closest public
  proxy for a video call); community-1 specifically improves speaker confusion, the error type
  you care about. The CoreML port claims within ~1 % DER of PyTorch at ~10× CPU speed on ANE.

Same models, same accuracy, ~35 MB. What you give up versus C is the tuned matching layer —
you'd write the cosine matching, the EMA refinement, the min-duration guards, and the
threshold defaults yourself. Roughly 100 lines instead of roughly 30, plus the tuning.

### D. sherpa-onnx — the third path

Full offline diarization (pyannote segmentation + 3D-Speaker/NeMo embeddings + clustering)
with a **C API** and a **CMake** build, exposing a standalone speaker-embedding extractor.
Its selling point was fitting the pre-swiftly constraints without new tooling; with swiftly
installed that advantage is gone, and the cost — a second vendored C++ dependency plus ONNX
Runtime — remains. Skip unless you want ONNX for unrelated reasons.

### E. pyannote.audio in a Python sidecar — best quality, worst fit

The reference implementation: best DER, real clustering. Also a Python venv + PyTorch beside
an always-on menu-bar app, an IPC hop per segment, an HF token, and a second thing an OS
update can break. Against SPEC.md's whole posture. Genuinely useful for **offline
calibration** — batch-relabel a day's audio to grade the live path — not for the live path.

### F. Apple SpeechAnalyzer (macOS 26) — not applicable

Available on your 26.6, but it has no diarization. Apps wanting both pair SpeechAnalyzer for
ASR with FluidAudio for diarization.

### G. Real names instead of `user-N` — separate axis

No audio model can output "Ana". Real names have to come from the screen:

- **Vision OCR over the call window** (ScreenCaptureKit + `VNRecognizeTextRequest`), reading
  the active-speaker name badge. Existing macOS projects do exactly this.
- **Accessibility API** on the participants list (`AXUIElement`) — cleaner where it works,
  breaks on Electron apps that don't populate the tree.

Both are per-app brittle. But they **compose** with the embedding gallery rather than
competing: the gallery gives you a stable cluster, OCR only has to name it *once*, and every
future day inherits the name by voice. Much better division of labour than OCR-per-utterance.

And since it looks tempting and isn't: **per-process Core Audio taps don't help.** You can tap
a single PID, which separates Slack from Chrome — but all four call participants come out of
one process. App splitter, not people splitter.

---

## B vs C, head to head

Same models, same accuracy, same ANE. The whole decision is *whose code does the matching* and
*what you carry to get it*.

| | **C — FluidAudio SDK** | **B — CoreML models direct** |
|---|---|---|
| Your code | ~30 lines: extract, assign, persist | ~100 lines: fbank→embed plumbing, 10 s windowing, cosine match, EMA, guards |
| Matching logic | Tuned defaults, EMA refinement, 50-embedding history, min-duration guards | Yours to write and tune |
| Cross-day gallery | `Speaker: Codable` → one `JSONEncoder` call | Same, but over your own struct |
| Models | Auto-downloaded at runtime (~35 MB) | You fetch in `setup.sh` (~35 MB) |
| Binary cost | +17 MB (measured on a `SpeakerManager`-only probe) | ~0 |
| Build inputs | 90 MB vendored `.a`, 4 `-I` paths, `swift build` in `setup.sh` | 2 model dirs |
| New toolchain dep | swiftly must stay installed and lead `PATH` | none |
| Dependency surface | Whole SDK: ASR (parakeet), TTS (kokoro, supertonic), VAD, a Rust FST lib | 2 `MLModel` handles |
| Upgrade path to step 3 | `performCompleteDiarization` already there | Wire `Segmentation.mlmodelc` yourself |
| Failure mode | Upstream churn; 260 modules you don't read | Your bug, your afternoon |

**Take C.** The matching layer is the part with non-obvious tuning in it — thresholds, when to
enroll, when to update a centroid — and it's the part that quietly produces bad labels rather
than crashing. Buying it tested is worth 17 MB and a pinned `swiftc`.

**Take B if** any of these bite: you don't want swiftly to become load-bearing for the build;
17 MB and 260 unread modules for a 3-file app offends you (defensible — SPEC.md's "if a fourth
file appears, ask why" is the same instinct); or you want susurro to keep building on a machine
with nothing but CLT. The 100 lines are not hard, and B is a clean fallback if C's dependency
weight sours later — nothing about step 0 or the JSONL schema depends on which you pick.

One thing that is *not* a differentiator, despite looking like one: quality. Both run the same
pyannote community-1 weights on the same ANE. Choosing B costs you tuned matching, not
accuracy.

---

## Cross-day identity: the direct answer

**Not free from diarization, but nearly free from the embedding.**

1. A diarizer labels within a recording. Run it Monday and Tuesday and you get two independent
   `speaker_0` labels that may well be different humans. Not a bug — it has no memory by
   construction.
2. What carries across is the **256-d L2-normalized embedding**. Persist a running centroid per
   speaker, cosine-match new segments against it, mint a new `user-N` when nothing is within
   threshold. That's the whole mechanism. FluidAudio's `SpeakerManager` does exactly this in
   memory and — per its own docs — has **no disk persistence**, so the file is yours to write
   either way. With `Speaker: Codable` that's one line rather than a struct.

Useful calibration from FluidAudio's docs: cosine distance < 0.3 = same speaker, high
confidence; 0.5–0.7 = medium; > 0.9 = different. Match threshold 0.65 default, 0.7–0.8 for
noisy audio.

Honest accuracy expectations, because this is where it disappoints if oversold:

- **Same call, same day: good.** The easy case, and the one benchmarks measure.
- **Across days: workable, degrades.** Conference audio is the adversary — low-bitrate Opus,
  aggressive noise suppression and AGC all distort exactly the spectral detail speaker
  embeddings key on. The *same person* on Zoom vs. Meet vs. in the room can land further apart
  than two different people on the same platform.
- **The gallery decays.** With 5–10 recurring colleagues it holds. At 50+ accumulated
  strangers, false merges become routine — similar voices of the same pitch/gender collide,
  and each false merge poisons the centroid, which causes the next one.
- **Mitigations, in order of laziness:** never enroll from segments < 1 s (`minSpeechDuration`);
  only update a centroid from segments ≥ 2 s; mark manually-named speakers permanent so they
  can't drift; cap the gallery and evict entries unseen for N days.
- **Design for being wrong.** Write `speaker` *and* the match distance to the JSONL. Then a bad
  day is re-clusterable offline instead of baked into the transcript forever.

One privacy note, stated once: `speakers.json` is a persistent voiceprint database of people
who consented (at most) to being in a meeting. Same `0700` as the transcripts, and as easy to
delete as removing one file.

---

## Suggested path

Each step independently shippable. Stop wherever it's good enough.

**Step 0 — schema first, no models.** Add `"speaker"` to the JSONL line, hardcode `"me"` for
`mic` and `"unknown"` for `system`. Ten minutes, and every later step becomes a pure addition
rather than a migration of existing transcripts. Independent of the B/C choice.

```json
{"ts":"…","source":"system","speaker":"user-2","dist":0.31,"dur":3.42,"lang":"es","text":"…"}
```

**Step 1 — embedding + gallery.** `extractSpeakerEmbedding` per `system` segment →
`assignSpeaker` → persist `getAllSpeakers()` to `~/.susurro/speakers.json`. Threshold in
`config.json` next to `rmsThreshold` — it's platform- and hardware-dependent for the same
reason the RMS gate is, and SPEC.md already argues that case.

Gets you stable `user-N` within a call, the same `user-N` tomorrow, ES/EN untouched. Does
**not** handle two people inside one segment.

**Step 2 — naming.** `speaker?.name = "Ana"`, hand-edited into the same file once.
Deliberately not a UI. If you find yourself retyping names constantly, *then* look at option G.

**Step 3 — only if step 1 visibly fails.** Switch to `performCompleteDiarization` on the
segment so 2+ speakers inside one flush get split and embedded with real masks. This is the
interruption/crosstalk fix; it roughly doubles pipeline complexity, so gate it on evidence —
grep a week of transcripts for lines where one `user-N` segment obviously holds two voices. If
that's rare, never build it.

### What it touches

- `setup.sh` — a `swift build -c release --product FluidAudio` step + `libtool -static`, next
  to the existing cmake step; plus a `DiarizerModels.download` call so first run is offline.
- `Makefile` — pin `SWIFTC` to `~/.swiftly/bin/swiftc`, add four `-I` paths and one `.a` to
  `LINK`. `-lc++` is already there.
- `Sources/Transcriber.swift` — `submit(_:source:)` already carries `source`; add the speaker
  lookup before `append`, and two fields on `struct Line`.
- **A fourth Swift file** (`Sources/Speaker.swift`) — SPEC.md says "if a fourth appears, ask
  why". The why: model loading plus a persisted gallery is a distinct lifecycle from the
  whisper context, and inlining it would blur the one thing `Transcriber.swift` currently does
  well.
- `Config` (`Sources/Capture.swift:12`) — one `speakerThreshold` field, same pattern as the rest.
- SPEC.md — "diarization beyond mic-vs-system" currently sits under **Out**; the toolchain
  section's "SwiftPM is broken" is now conditional on which `swiftc` you're holding. Both need
  a rewrite.

### Open questions

1. **Global gallery or per-day?** Global is the point of the exercise and also what accumulates
   false merges. Per-day is trivially correct and answers nothing you asked. I'd go global with
   eviction — your call, and the one decision that's annoying to reverse.
2. **Headphones or speakers?** SPEC.md's known limitation #1 (mic hears system audio, same
   speech lands twice) gets *worse* with speaker labels: on speakers, your own voice also
   enrolls as a `system` speaker. Step 1 assumes headphones; otherwise a time-overlap
   suppressor stops being optional polish.
3. **Raw embeddings in the JSONL?** 256 floats ≈ 3 KB/segment, maybe 10–30 MB/day, and it makes
   a day re-clusterable offline. No by default, yes while calibrating the threshold.

---

## Sources

- [whisper.cpp tinydiarize PR #1058](https://github.com/ggml-org/whisper.cpp/pull/1058) · [akashmjn/tinydiarize](https://github.com/akashmjn/tinydiarize) — turn segmentation only, clustering "planned for later"
- [FluidAudio](https://github.com/FluidInference/FluidAudio) · [SpeakerManager docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/SpeakerManager.md) — thresholds, 256-d embeddings, no disk persistence
- [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) — the models; shapes above read from their `metadata.json`
- [pyannote community-1](https://www.pyannote.ai/blog/community-1) — improved speaker confusion vs 3.1 (upstream HF repo is gated)
- [sherpa-onnx speaker diarization](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html) — C API + CMake alternative
- [WeSpeaker](https://github.com/wenet-e2e/wespeaker) — the embedding model, cosine-optimised via AAM-softmax
- [ambient-voice](https://github.com/Marvinngg/ambient-voice) — precedent for SpeechAnalyzer + Vision OCR + FluidAudio on macOS
