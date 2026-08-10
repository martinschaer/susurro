# Diarization beyond mic-vs-system

Research notes, 2026-08-10. No code changed. Verified against this machine's toolchain
and the vendored whisper.cpp; model specs pulled from the actual model metadata, not from
blog posts.

## The short version

**Recommendation: skip tinydiarize. Download two CoreML models (~35 MB) from
`FluidInference/speaker-diarization-coreml`, load them with plain `MLModel` from
`Transcriber.swift`, and cosine-match a 256-d embedding per segment against a JSON gallery
on disk.** That is one new Swift file, no package manager, no Python, no new C library — and
because the gallery is a file, cross-day identity comes along for free rather than as a
second project.

Two things you asked about are actually two different problems, and conflating them is the
main trap here:

| | What it answers | Gives you cross-day identity? |
|---|---|---|
| **Diarization** | "the speaker changed here", "these turns are the same person *within this recording*" | **No.** Labels are session-local and arbitrary. |
| **Speaker recognition** | "this voice is the same one I heard on Tuesday" | Yes — it *is* the definition. |

Off-the-shelf diarization gives you `speaker_0 … speaker_N` per recording, renumbered every
time. To carry `user-1` across days you need the *embeddings* the diarizer computes
internally, persisted and matched. So: not out of the box, but also not a new project — it's
~40 lines on top, provided you pick a stack that exposes the embedding vector.

That last clause is the whole selection criterion. **Anything that hands you only labels is a
dead end for your second question.** tinydiarize is exactly that dead end.

## Why susurro makes this unusually easy

Normal diarization pipelines have to solve "where are the speaker boundaries in this 45-minute
file". Susurro already did most of that: `Segmenter` (`Sources/Capture.swift:39`) cuts on 700 ms
of sub-threshold RMS after ≥300 ms of speech. In a conversation, a turn usually *ends* with a
pause, so **most emitted segments are already one speaker**.

Which means the lazy version doesn't need a diarizer at all:

```
segment (already single-speaker, mostly)
   └─► embedding model ──► 256-d vector ──► cosine match vs. gallery ──► "user-2"
```

You skip the segmentation model, the powerset decoding, and the clustering pipeline. Add them
later only if interruption-heavy calls turn out to actually be a problem (see step 3).

`source:"mic"` stays what it is — that's *you*, and it's more reliable than any embedding.
Only the `system` stream needs speaker labels.

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

1. **It marks turn boundaries, not speakers.** The upstream project says so directly: *"Only
   local diarization (segmentation into speaker turns) is handled so far. Extension with global
   diarization (speaker clustering) is planned for later"* — and that was written in 2023 and
   never shipped. With 3 remote participants you learn *that* the voice changed, never *which*
   of the three it is. You cannot even reliably alternate A/B/A/B, because you don't know
   whether turn 3 is person A returning or person C arriving.
2. **No embeddings.** So your cross-day question is not just unanswered, it's unanswerable on
   this path.
3. **It's a different model.** `-tdrz` only works with `small.en-tdrz`
   (`models/download-ggml-model.sh:48`). You'd be trading `large-v3-turbo` for `small` **and**
   multilingual for **English-only** — which kills the ES/EN mixing that SPEC.md names as the
   reason for the current model choice. Running both means a second `whisper_context`, i.e.
   double the resident model and double the ANE work per segment, for boundary marks.
4. **It's an abandoned prototype.** Upstream describes it as "an early functional prototype
   done for the small.en models". No successor exists.

Also worth knowing so nobody suggests it: whisper.cpp's other flag, `--diarize` / `-di`, is
**stereo channel separation** — it labels by left/right channel of a 2-channel file. Useful for
an interview recorded on two mics. Useless for a downmixed conference call.

**Verdict: dead end for both questions.** Costs a model downgrade to buy nothing you need.

### B. pyannote community-1 CoreML models, driven directly — **recommended**

`FluidInference/speaker-diarization-coreml` on HuggingFace publishes the pyannote
community-1 pipeline pre-converted to CoreML `.mlmodelc` bundles. These are just files. You do
not need their SDK to use them — `MLModel(contentsOf:)` from plain Swift loads a `.mlmodelc`
directly, with no package manager involved. That matters a lot here (see option C).

Verified from the models' own `metadata.json`:

| Model | Size | Input | Output |
|---|---|---|---|
| `FBank.mlmodelc` | 1.8 MB | `[1…32, 1, 160000]` f32 — **exactly 10 s @ 16 kHz** | `[N, 1, 80, 998]` fbank |
| `Embedding.mlmodelc` | 13.5 MB | fbank `[N,1,80,998]` + `weights [N,589]` | `embedding` — 256-d |
| `Segmentation.mlmodelc` | 6.0 MB | `[1…32, 1, 160000]` f32 | `log_probs` (powerset, 589 frames) |

Notes that will save you an afternoon:

- **10 s windows are mandatory.** The FBank input shape is fixed at 160000 samples. Segments
  shorter than that get zero-padded; longer ones (susurro allows up to 25 s) get chunked into
  10 s windows with the embeddings averaged. Batch dim goes to 32, so a 25 s segment is one
  batched call, not three.
- **The `weights [589]` input is the per-frame speaker mask** from the segmentation model — it
  weights the pooling so the embedding covers only that speaker's frames. For step 1, where
  you're assuming one speaker per segment, **feed all-ones**. That's what makes step 1 a
  two-model pipeline instead of a five-model one.
- **Input is 16 kHz mono Float32** — byte-identical to what `Segmenter.emit` already hands
  `Transcriber.submit`. No conversion, no resampler, nothing.
- **Language-independent.** The model card: *"Models are trained on acoustic signatures so it
  supports any language."* Your ES/EN mixing is a non-issue.
- **Not gated.** The upstream `pyannote/speaker-diarization-community-1` repo requires an HF
  login and accepting terms; I hit that wall while researching this. The FluidInference
  conversion downloads anonymously. Model licence is `cc-by-4.0` (attribution — fine for a
  personal prototype, worth remembering if this ever ships).
- **Accuracy.** pyannote 3.1 sits around 12–14 % DER on AMI (meeting audio, the closest public
  proxy for a video call); community-1 improves speaker confusion specifically, which is the
  error type you care about. The CoreML port reports staying within ~1 % DER of the PyTorch
  original, at ~10× the CPU speed on ANE.

Cost: ~35 MB of models, one new Swift file, ~100 lines including the gallery.

### C. FluidAudio SDK — **blocked on this machine**

FluidAudio is the Swift SDK that ships those models, and its `SpeakerManager` is precisely the
component you'd otherwise write yourself: cosine matching, EMA embedding refinement, named
enrollment. Documented API:

```swift
SpeakerManager(speakerThreshold: 0.65,          // max cosine distance to match
               embeddingThreshold: 0.45,
               minSpeechDuration: 1.0,          // min seconds to mint a new speaker
               minEmbeddingUpdateDuration: 2.0)
let speaker = speakerManager.assignSpeaker(embedding, speechDuration: 3.0)
speaker?.name = "Alice"
speakerManager.initializeKnownSpeakers([alice, bob], mode: .overwrite)
```

**It's SwiftPM-only, and SwiftPM is still broken in this CLT-only install.** I re-tested it
today rather than trusting SPEC.md — it's still broken, and the failure is at the ABI level, so
it isn't about the template:

```
Undefined symbols for architecture arm64:
  "PackageDescription.Package.__allocating_init(name:…swiftLanguageVersions:…)"
```

The shipped `.swiftmodule` declares an initialiser that `libPackageDescription.dylib` doesn't
export. *Every* `Package.swift` fails, including a hand-written four-line one. And FluidAudio
can't be hand-compiled around it either: it pulls a remote `.xcframework` binary target, two C
wrapper targets, and `.process(...)` resource bundles — reproducing that with bare `swiftc` is
more work than writing the 40 lines yourself.

**Unblocking it** means installing a real toolchain — a swift.org toolchain via `swiftly`, or
Xcode.app — which also fixes `xcrun metal` and would let you turn `GGML_METAL=ON`. That's a
genuinely reasonable thing to do independently. But it's a much bigger yak than this feature
needs.

Useful anyway: **their thresholds are free calibration data.** Cosine distance < 0.3 = same
speaker, high confidence; 0.5–0.7 = medium; > 0.9 = different. Recommended match threshold
0.65, raised to 0.7–0.8 for noisy audio. Start there instead of guessing.

### D. sherpa-onnx — the toolchain-compatible fallback

Full offline diarization (pyannote segmentation + 3D-Speaker/NeMo embeddings + clustering)
with a **C API** and a **CMake** build. CMake already works here — it's how whisper's static
libs get built — so this is the option that fits the existing constraints without new
tooling, and it exposes a standalone speaker-embedding extractor for the gallery.

The cost is a second vendored C++ dependency plus an ONNX Runtime static lib, against
option B's "download two files". Take this only if you want the full pipeline *and* refuse to
install a Swift toolchain.

### E. pyannote.audio in a Python sidecar — best quality, worst fit

The reference implementation, best DER, real clustering. But it means a Python venv + PyTorch
alongside an always-on menu-bar app, an IPC hop per segment, an HF token, and a second thing
that can be broken by an OS update. Against SPEC.md's whole posture. Useful for **offline
calibration** — e.g. batch-relabel a day's audio to check how well the live path did — not for
the live path.

### F. Apple SpeechAnalyzer (macOS 26) — not applicable

You're on macOS 26.6, so it's available. It has no diarization. Apps that want both pair
SpeechAnalyzer for ASR with FluidAudio for diarization. It doesn't help here.

### G. Real names instead of `user-N` — separate axis, worth knowing about

No audio model can ever output "Ana". If you want real names rather than `user-2`, the name
has to come from the screen:

- **Vision OCR over the call window** (ScreenCaptureKit + `VNRecognizeTextRequest`), reading
  the active-speaker name badge. Existing macOS projects do exactly this.
- **Accessibility API** on the participants list (`AXUIElement`) — cleaner where it works,
  breaks on Electron apps that don't populate the tree.

Both are per-app brittle and will break on redesigns. But note they **compose** with option B
rather than competing: the embedding gallery gives you a stable cluster, OCR only has to name
it *once*, and every future day inherits the name by voice. That's a much better division of
labour than OCR-per-utterance.

Also, since it looks tempting and isn't: **per-process Core Audio taps don't help.** You can
tap a single PID, which separates Slack from Chrome — but all four call participants come out
of one process. It's an app splitter, not a people splitter.

---

## Cross-day identity: the direct answer

**Not free from diarization, but nearly free from the embedding.** Concretely:

1. A diarizer labels within a recording. Run it on Monday and Tuesday and you get two
   independent `speaker_0` labels that may well be different humans. That's not a bug — it has
   no memory by construction.
2. What carries across is the **256-d L2-normalized embedding**. Persist a running centroid per
   speaker to `~/.susurro/speakers.json`, cosine-match new segments against it, mint a new
   `user-N` when nothing is within threshold. That's the whole mechanism. FluidAudio's
   `SpeakerManager` does exactly this in memory and — per its own docs — has **no disk
   persistence**, so you'd be writing the same 40 lines either way. Its threshold values
   above are the useful part.

Honest accuracy expectations, because this is where it will disappoint you if oversold:

- **Same call, same day: good.** This is the easy case and the one diarization benchmarks
  measure.
- **Across days: workable, degrades.** Conference audio is the adversary — Opus at low
  bitrate, aggressive noise suppression, and AGC all distort exactly the spectral detail
  speaker embeddings key on. The *same person* on Zoom vs. on Meet vs. in the room can land
  further apart than two different people on the same platform.
- **The gallery decays over time.** With 5–10 recurring colleagues it should hold. At 50+
  accumulated strangers, false merges become routine — similar voices of the same
  pitch/gender collide, and each false merge poisons the centroid, which causes the next one.
- **Mitigations, in order of laziness:** never enroll from segments < 1 s (that's what
  `minSpeechDuration: 1.0` is for); only update a centroid from segments ≥ 2 s; mark speakers
  you've manually named as permanent so they can't drift; cap the gallery and evict entries
  not seen in N days.
- **Design for it being wrong.** Write `speaker` *and* the match distance to the JSONL. Then a
  bad day's labels are re-clusterable offline from the stored embeddings, instead of being
  baked into the transcript forever.

One privacy note, stated once and not moralised: `speakers.json` is a persistent voiceprint
database of people who consented (at most) to being in a meeting. It belongs under the same
`0700` as the transcripts, and it should be as easy to delete as removing one file.

---

## Suggested path

Each step is independently shippable. Stop wherever it's good enough.

**Step 0 — schema first, no models.** Add `"speaker"` to the JSONL line, hardcode `"me"` for
`mic` and `"unknown"` for `system`. Ten minutes, and every later step becomes a pure addition
rather than a migration of existing transcripts.

```json
{"ts":"…","source":"system","speaker":"user-2","dist":0.31,"dur":3.42,"lang":"es","text":"…"}
```

**Step 1 — embedding + gallery.** The recommendation. FBank + Embedding CoreML models, one
embedding per `system` segment (all-ones weights), cosine match against
`~/.susurro/speakers.json`, mint `user-N` on miss. Threshold in `config.json` next to
`rmsThreshold` — it's hardware- and platform-dependent for the same reason the RMS gate is,
and SPEC.md already argues that case.

This gets you: stable `user-N` within a call, the same `user-N` tomorrow, and the ES/EN mixing
untouched. It does **not** handle two people inside one segment.

**Step 2 — naming.** `{"user-2": "Ana"}` in the same file, hand-edited once. Deliberately not a
UI. If it turns out you retype names constantly, *then* look at option G.

**Step 3 — only if step 1 visibly fails.** Add `Segmentation.mlmodelc`: run it on the segment,
and if it reports 2+ speakers, split the segment and embed each part with its real `weights`
mask instead of all-ones. This is the interruption/crosstalk fix. It doubles the pipeline's
complexity, so gate it on evidence: grep a week of transcripts for lines where one `user-N`
segment obviously contains two voices. If that's rare, never build it.

### What it touches

- `Sources/Transcriber.swift` — `submit(_:source:)` already carries `source`; add the speaker
  lookup before `append`, and two fields on `struct Line`.
- **A fourth Swift file** (`Sources/Speaker.swift`) — SPEC.md says "if a fourth appears, ask
  why". The why: CoreML model loading + a persisted gallery is a distinct lifecycle from the
  whisper context, and inlining ~100 lines into `Transcriber.swift` would blur the one thing
  that file currently does well.
- `Config` (`Sources/Capture.swift:12`) — one `speakerThreshold` field, same pattern as the
  existing ones.
- SPEC.md — "diarization beyond mic-vs-system" currently sits under **Out**. It'd move.

### Open questions

1. **Is the gallery global or per-day?** Global is the point of the exercise, but it's also
   what accumulates false merges. Per-day is trivially correct and answers nothing you asked.
   I'd go global with eviction — but it's your call, and it's the one decision that's annoying
   to reverse.
2. **Headphones or speakers?** SPEC.md's known limitation #1 (mic hears system audio, so the
   same speech lands twice) gets worse with speaker labels, not better: on speakers, *your own
   voice* will also enroll as a `system` speaker. Step 1 assumes headphones; if you're on
   speakers, a time-overlap suppressor stops being optional polish.
3. **Do you want the raw embeddings written to the JSONL** (256 floats ≈ 3 KB/segment, so
   maybe 10–30 MB/day) so a day is re-clusterable offline? I'd say no by default, yes while
   calibrating the threshold.

---

## Sources

- [whisper.cpp tinydiarize PR #1058](https://github.com/ggml-org/whisper.cpp/pull/1058) · [akashmjn/tinydiarize](https://github.com/akashmjn/tinydiarize) — turn segmentation only, clustering "planned for later"
- [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) — the CoreML models; shapes above read from their `metadata.json`
- [FluidAudio](https://github.com/FluidInference/FluidAudio) · [SpeakerManager docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/SpeakerManager.md) — thresholds, 256-d embeddings, no disk persistence
- [pyannote community-1](https://www.pyannote.ai/blog/community-1) — improved speaker confusion vs 3.1 (upstream HF repo is gated)
- [sherpa-onnx speaker diarization](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html) — C API + CMake fallback
- [WeSpeaker](https://github.com/wenet-e2e/wespeaker) — the embedding model, cosine-optimised via AAM-softmax
- [ambient-voice](https://github.com/Marvinngg/ambient-voice) — precedent for SpeechAnalyzer + Vision OCR + FluidAudio on macOS
