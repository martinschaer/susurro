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
| Speaker identity | Per meeting, clustered when it ends | A window matched against a weeks-old gallery is the hardest form of the question on the least evidence; within one meeting the room and codec are constant |
| Speaker names | On the transcript's own lines, per transcript | A `user-N` is a voiceprint cluster, not a person: across days clusters merge people, so one global name is wrong somewhere |
| Live transcript | Written in `~/.susurro/live`, moved out when the meeting ends | Naming rewrites the whole file; the engine holds an open handle at a cached offset, so the file it is appending to must be somewhere nothing else touches |
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
                          │                   VoicePrints (embed only)
                          │                   <meeting>.emb, clustered at close
                          ▼                            │
                          └────────────┬───────────────┘
                                       ▼
                          ~/.susurro/transcripts/<date_time>.jsonl
```

Two independent capture sources, one shared transcriber. A single `whisper_context` is
not reentrant, so both streams funnel through one serial `DispatchQueue`. Segments are
seconds long; queueing is fine and halves resident memory vs. two contexts.

`VoicePrints` hangs off the same queue, which is also what makes it thread-safe —
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
pause — so an emitted segment is usually one person. `DiarizerManager.extractSpeakerEmbedding`
turns each one into a 256-d WeSpeaker vector, feeding an all-ones frame mask, and that is
all that happens while the meeting is running. The vector is appended to a `.emb` file and
the line is written `speaker:"unknown"`.

**Who spoke is decided when the meeting ends, from every segment at once.** That is the
whole design, and it is the opposite of what this did before.

The previous version answered the question per segment, as each arrived, by cosine-matching
one 10-second window against a gallery of voiceprints accumulated across weeks. Measured on
this machine after a few months: 139 speakers minted across 23 meetings, **41% of which
spoke exactly one line**, those lines running to a median of 2.4 s against 10.1 s for
voices that spoke more than once. One 56-line meeting held 17 distinct "speakers". The
gallery reached 67 entries whose median nearest-neighbour distance was **0.354** against a
0.35 cutoff — at which point it could no longer separate anybody from anybody, and no
threshold value would have fixed it.

Three things were wrong and each made the others worse: identity was decided per segment,
on the least evidence available; it was decided at write time, irreversibly, before the
rest of the meeting existed; and it was decided against a cross-day gallery, which is the
hardest form of the comparison. Within one meeting the same embeddings work well — the
room, the microphone and the codec are held constant, and each speaker is judged on all of
their audio. On 187 real segment embeddings from this machine, within-speaker pairs run to
a median of 0.235 and between-speaker pairs to 0.558.

So `Cluster.speakers` runs at `publish`: agglomerative, average linkage, cosine, merging
the closest pair until nothing is within `clusterThreshold`. The number of speakers is
never asked for or guessed — the threshold decides it. Clusters are ranked by how much was
said, so `s1` is whoever talked most, and a cluster holding less than `minSpeakerSec` of
speech is `unknown` rather than a person: a cough, a "yeah", crosstalk. **The labels are
meeting-local.** `s1` here and `s1` in another transcript are not a claim about the same
person, and nothing persists between meetings.

Average linkage, not single. Single linkage chains: one borderline segment sitting between
two people merges with the first, then reports its own small distance to the second and
welds all three into one speaker. Nothing recovers a transcript that filed two people as
one, whereas naming both halves of a split the same thing reads correctly.

```
clusterThreshold = 0.40     // config.json; max average cosine distance to merge
minSpeakerSec    = 3.0      // config.json; below this a cluster is `unknown`
```

`clusterThreshold` is measured rather than taken from the library's suggestion. Clustering
the five most-spoken voices, 20 segments each, recovers all five cleanly at 0.35 and 0.40,
collapses them to three at 0.45 and to one at 0.55. FluidAudio suggests 0.6–0.8 for a
single recording; on these embeddings 0.6 merges everybody. The grouping those segments
came from was itself made at 0.35, so "recovers all five" is partly circular — the collapse
above 0.45 is not, and that is what fixes the ceiling. Raise it if one person splits in
two; lower it if two people merge.

Cost is 128 ms for a 600-segment meeting, once, at close.

`extractSpeakerEmbedding` does **not** return unit vectors, whatever the library's
clustering does with them afterwards; a raw pair can have a dot product above 1, which
reads as a negative cosine distance. `VoicePrints.embed` normalises before anything stores
or compares them.

**Clips are hard-capped at 10 s** before they reach the extractor. That is not a
preference: the extractor copies its input into a `[3, 160000]` batch buffer with no
clamp, so a longer clip writes over the neighbouring batch slots. Only slot 0 is read
back, so trimming loses nothing.

Missing speaker models degrade to `speaker:"unknown"` throughout and a menu-bar note. They
never cost you the transcript.

There is no cross-day speaker identity, by design. Recognising a voice from a previous
meeting is a *suggestion* problem, and the material for it now exists in a far better
form — a centroid built from everything one person said in a meeting, rather than one
window against a drifted mean — but it must never write a label.

### Storage

`~/.susurro/transcripts/YYYY-MM-DD_HH-MM-SS.jsonl` (local time of the file's first line),
one line per segment, appended, `fsync`ed per write:

```json
{"ts":"2026-08-10T14:32:07+02:00","source":"system","speaker":"user-2","dist":0.31,"dur":3.42,"lang":"es","text":"…"}
```

`source` is `"mic"` (you) or `"system"` (what you heard). `speaker` is `"me"` for the mic
stream — no embedding beats knowing which microphone it came from — and `user-N` or
`"unknown"` for the system stream.

`speaker` is never a *global* name. A name is an opinion about one recording; a single
name per gallery entry applies it retroactively to every other meeting the same cluster
appears in, which is the thing that is wrong. The name for this meeting goes in its own
field, added afterwards by the naming window:

```json
{"ts":"…","source":"system","speaker":"s2","name":"Ana","dur":3.42,"lang":"es","seg":41,"text":"…"}
```

`name` is absent until somebody says. In the line and not in a sidecar so the transcript is
self-describing: whatever reads it next — a script, an agent — gets the name without being
told where else to look. Transcripts written before the field existed carry a name in
`speaker` instead; they still read, as a voice whose label happens to be `Ana`. No
migration, beyond one-shot adoption of the `.names.json` sidecars an earlier build wrote.

Naming rewrites the whole file, which is only safe because **a transcript being appended to
is not in this directory**. `Transcriber` writes to `~/.susurro/live/<stamp>.jsonl` and
moves the file to `~/.susurro/transcripts/` when the meeting ends — on the session-gap
rotation, at `close()`, and, for anything a crash stranded, at the next launch. The handle
keeps a cached offset from `seekToEndOfFile()` and does not reopen per line, so a rewrite
underneath it would land the next append in the middle of the file. Segregating by
directory makes that impossible rather than unlikely, and means the naming window needs no
reference to the engine to know what is live. A sibling directory and not a subdirectory,
so a recursive scan of the transcripts cannot find the one file that is still moving.

The rewrite is atomic, returns lines it cannot decode byte for byte, and is 13 ms on the
largest transcript here — which is why the window writes on commit rather than per
keystroke. `JSONEncoder` does not emit keys in declaration order, so a rewritten line is
reordered; same object, different byte layout.

`seg` is the index of this segment's voiceprint in the `.emb` file beside the transcript —
a flat wall of `Float32`, 256 per segment. On the line rather than implied by position, so
that re-clustering years later cannot mis-align whatever happened to the file in between.

The voiceprints are kept after the meeting is clustered, not deleted. That is what makes
every future improvement to clustering a re-run over old meetings instead of something that
only helps from today onward — the thing the old `dist` field claimed to enable and could
not, because a distance is not a vector. At 1 KB a segment it is 570 KB for the longest
meeting here; as JSON on the line it would have grown a 100 KB transcript past 1.5 MB.

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
    Name speakers…             → one Window scene: meetings, then the voices in one
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
    SusurroApp.swift    MenuBarExtra, enable/disable wiring, the naming window
    Capture.swift       mic + system tap + segmenter
    Transcriber.swift   whisper context, serial queue, JSONL append
    Speaker.swift       embedding + persisted gallery + per-transcript names
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
{"rmsThreshold": 0.01, "silenceMs": 700, "maxSegmentSec": 25, "clusterThreshold": 0.4,
 "minSpeakerSec": 3, "sessionGapMin": 5}
```

`clusterThreshold` is calibration for the same reason: what a conferencing codec does to a
voice varies by platform, and the right cutoff depends on the room. The measurement behind
the 0.40 default, and how to move it, is in § Speakers.

`minSpeakerSec` is the floor under which a cluster is noise rather than a person. Lower it
if someone who genuinely only said one sentence keeps coming back `unknown`.

`sessionGapMin` is where a transcript file ends: minutes of silence on both streams before
the next line goes to a new file. Too low and one meeting with a long lull becomes two
files; too high and two back-to-back meetings become one.

Read once at enable. No file → defaults. No UI, no watcher; toggle off/on to reload.

Naming is not, and it is per transcript. *Name speakers…* opens the list of meetings —
date, how many voices, how many are still unnamed — because the meeting is what makes a
`user-N` answerable: nobody remembers which FluidAudio id was Ana, but everybody remembers
who was in Tuesday's call.

Clicking a meeting lists its voices: `user-N`, a name field, a suggestions button, and the
longest line that voice said, which identifies far better than its first ("yeah"). A name is
written on Return, on picking a suggestion, and on leaving the view — the last of those
because a name typed and then navigated away from used to be dropped silently, which reads
exactly like naming being broken. Not per keystroke: each write rewrites the transcript. A
blank field **clears** the name: getting one wrong is the normal case here, and there would
otherwise be no way to take it back.

The meeting in progress is not in the list, because it is not in the directory yet. That is
the same fact that makes the rewrite safe.

The stack is driven by an explicit `NavigationPath`, not by `NavigationLink`s. A link inside
a `List` row hands the whole row to navigation, and it ate every click meant for the name
field and the suggestions menu sitting in that row.

The suggestions are the record of speakers, and the only reason the gallery still matters
to a human. A voice you called Ana in four meetings offers `Ana (4)`; ties break
alphabetically; the meeting being named never votes for itself. That is a hint and never
an assignment — nothing is written until you type or pick and press Save, so a cluster that
quietly merged two people cannot rename one of them into the other behind your back.

Clicking a voice's sample line opens everything it said in that meeting, in order, each
line expandable to the turn either side, labelled with who said it — `me` on both sides
means this voice was answering you, which places it faster than the line alone does.
Complete and chronological rather than a random sample, because one meeting is a bounded
amount of text and read in order it is a conversation. Neighbours come from the same file,
so never across meetings; segments are cut on silence, so "the line before" is sometimes
the same person's previous segment rather than somebody else's turn.

Hand-editing a `name` field is the same operation and still works — the window is only a
read-modify-write of that file, which is why it needs no models loaded and works with
Listening off. Reading the lines is the same trick applied to the transcripts: a directory
scan and a JSONL decode, no whisper context. The transcripts are append-only once
published; nothing rewrites a label that is already on disk.

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
8. **No cross-day identity at all.** A voice recognised in Tuesday's meeting is not
   recognised in Friday's; `s1` in one transcript says nothing about `s1` in another. This
   is deliberate — the previous attempt at it is what made speaker labels unusable — but it
   means naming is per meeting, every meeting, with only the suggestions to help. Matching
   a meeting's clusters against previously named ones is the obvious next feature and has
   not been built.
9. **A meeting is only as good as its clustering**, and the clustering is not shown to you.
   If `clusterThreshold` is wrong for your room you get two `s` numbers for one person, or
   worse, one for two. The lines are there to read, and re-running the clustering over the
   kept `.emb` file is cheap, but nothing in the UI does it yet.
10. **The voiceprints are a biometric.** `<meeting>.emb` is a set of speaker embeddings for
   people who agreed to be in a meeting, not to this. They live at `0700`/`0600` beside the
   transcripts, and deleting them loses the ability to re-cluster, nothing else.

## Verification

One check, `make smoke`: feed `samples/jfk.wav` (ships with whisper.cpp) through
`Transcriber` and assert the output contains `"country"`, plus a segmenter unit assert
that a synthetic tone-silence-tone buffer produces exactly 2 segments. Fails loudly if
either the model wiring or the gate logic breaks. No framework, no fixtures.

The same audio also goes down the `system` stream twice and must come back as one speaker,
`s1`, clustered after `close` rather than during the run — with both lines carrying a `seg`
index and the `.emb` file travelling with the published transcript. A decimated (~1.2×
pitch) copy must embed more than `clusterThreshold` away from the original; that is the only
check that catches an embedder returning a constant vector, which would collapse everyone
into one speaker while every other assertion still passed.

The clustering itself is checked without models, on hand-built vectors, because cosine is
arithmetic: segments of one voice land in one cluster, whoever talked most is `s1`, a
two-second cluster is dropped as noise, a segment with no voiceprint keeps its slot, and a
borderline segment between two people does **not** chain them into one — the assertion that
fails if average linkage is ever swapped for single. Then end to end, still without models:
a hand-written `.emb` plus a transcript whose `seg` indices skip a mic line in the middle,
asserting the labels land on the right lines, the mic line is untouched, and not a word of
the text moved.

The transcript-reading checks need no models at all. Three hand-written JSONL fixtures
assert the roster (meetings newest first, `me` excluded from the voices, the sample being
the longest line and not the first, only decodable lines counted), and that context is the
genuinely adjacent line: a line at a file boundary reports no neighbour, and one next to
an undecodable line reports no neighbour rather than the next readable line along. That
last one is the whole reason the decode keeps `[Line?]` instead of compacting — with
`compactMap` it fails, quoting the wrong speaker.

The naming checks are the ones that matter most, because the bug they guard is silent. The
same `user-1` is named `Ana` in one fixture and `Bruno` in another, and each transcript
must read back its own — that assertion fails the moment a name leaks across transcripts
again. Alongside it: the name lands on the line itself, a rewrite returns an undecodable
line byte for byte and loses none of the readable ones, a blank names nobody, clearing
removes one name and leaves its neighbour alone, an old `.names.json` is folded in and
deleted, and `suggestions` tallies `Ana (2), Bruno (1)` without the meeting being named
voting for itself.

With models loaded: an open transcript is in the live directory and nowhere else, `close`
publishes it and only then, a file stranded in `live` is published at the next launch, and
a clustered meeting still names the way an unclustered one does.

Both targets build with `-parse-as-library` and carry their own `@main`; `smoke.swift`
links `Capture.swift` + `Transcriber.swift` instead of `SusurroApp.swift`. Top-level code
is only legal in a file literally named `main.swift` once more than one file is being
compiled, so `@main` is the path of least resistance for both.

Manual acceptance: enable → say something → play a YouTube clip → confirm the newest JSONL
has both a `mic` and a `system` line with sane text, the mic lines say `me`, and the clip's
voices got `user-N`. Then join a call with two other people and check the two of them do
do not collapse into one `s` number — if they do, lower `clusterThreshold`, and if one of
them splits in two, raise it. There is nothing to delete and nothing to reset: a meeting's
clustering depends on that meeting alone, so a bad run costs you that transcript's labels
and nothing else, and re-running it over the kept `.emb` file is cheap.

The behaviour itself is checked against a real call's own transcript.
