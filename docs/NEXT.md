# Next

Ranked, with the evidence for each. SPEC.md § Known limitations is the full list of what is
accepted; this is only the part worth acting on, and why.

The ranking is by *how much of the remaining pain each removes per unit of work*, not by how
interesting it is. Everything above the line in § Measure first should be measured before it
is built — the last round of this went wrong by building against a library's suggested
constant instead of the data.

## Where things stand

Speakers are clustered per meeting, when it ends, from every segment at once
(SPEC.md § Speakers). There is no cross-day identity at all, deliberately. Each meeting
keeps its voiceprints in a `.emb` file beside the transcript, so any improvement to
clustering can be re-run over meetings that already exist — that is the property everything
below leans on.

Two things are true and slightly uncomfortable:

- **`clusterThreshold = 0.40` is provisional.** It was calibrated on 187 segment embeddings
  taken from the *old* gallery, whose grouping was itself made at 0.35. The collapse above
  0.45 is solid evidence; the recovery below it is partly circular.
- **Nothing has re-clustered anything yet.** The `.emb` files are written and kept, and no
  code path reads them except the one that labels a meeting once. Until something does, the
  re-runnability is a claim rather than a fact.

## 1. Re-cluster a meeting from the UI

**Problem.** If the threshold is wrong for a room you get two `s` numbers for one person, or
one for two, and the only recourse is to accept it. Limitation 9.

**Why first.** It is the smallest change that makes every later improvement testable, it
proves the `.emb` files actually work, and it is the only thing here that helps meetings
already on disk. It also turns threshold calibration from an argument into an experiment:
re-cluster the same meeting at 0.35 / 0.40 / 0.45 and read the result.

**Shape.** A control in the meeting view that calls `TranscriptSpeakers.assign` again with a
different threshold, then reloads. The rewrite is already atomic, already proven lossless on
a 572-line transcript, and already the one place that touches a transcript. Names are keyed
by `speaker`, so re-clustering orphans them — either clear them, or map them by majority
overlap before rewriting. Decide that deliberately; silently losing a name is the failure
mode this project has already had once.

**Not worth doing if** re-clustering never changes anything on real meetings, which
§ Measure first would reveal.

## 2. Suggest a name from a previous meeting's cluster

**Problem.** Naming is per meeting, every meeting, from scratch. Limitation 8.

**Why now and not before.** The earlier version of this idea — matching a lone segment
against a persistent gallery — is exactly what failed. What is different is the evidence on
both sides: a centroid built from everything one person said in a meeting, against another
such centroid. On the old data, single-segment pairs gave within-speaker median 0.235 and
between-speaker 0.558 with overlapping tails around 0.38; averaging over a whole meeting's
worth of segments should separate those means considerably further.

**Shape.** Per named cluster, store or derive its centroid. When naming a meeting, rank
previously-named clusters by distance and offer the close ones *alongside* the existing
frequency-based suggestions, labelled as a guess with the distance shown.

**Constraints, learned the hard way.** It must never write a label — only populate a field
the user confirms. It must be ranked below and visually distinct from exact suggestions,
because on the old gallery the nearest neighbour was frequently the wrong person: `user-67`'s
true twin ranked *third* at 0.379, behind two unrelated voices. And a tight cutoff is worth
more than a ranked list: below 0.25 the old gallery had only 7 pairs in 2211, and the top
ones looked like genuine splits.

## 3. Merge and split speakers by hand

**Problem.** Clustering will sometimes be wrong and the user can see it in the text long
before any threshold can.

**Shape.** In the meeting view: select two `s` numbers and merge, or mark a line as
misattributed. Merging is a rewrite of `speaker` and is cheap. Splitting properly means
re-clustering a subset, which is why this comes after 1.

**Note.** Naming both halves of a split the same thing already reads correctly in the
transcript, so this is an ergonomics fix, not a correctness one. Rank it accordingly.

## 4. Split a segment that holds two voices

**Problem.** An interruption has no silence, so `Segmenter` does not cut it and both people
land in one segment with one averaged embedding. Limitation 7.

**Shape.** `pyannote_segmentation` is *already loaded* — `VoicePrints` loads it only to read
the frame count off its output shape and never runs it. Running it on a segment would give
speaker-change boundaries within the segment.

**Cost.** Roughly doubles the pipeline. Gate it on evidence from real transcripts, not on
principle: grep a week of meetings for lines where one cluster obviously holds two voices
mid-sentence. If that is rare, this is not worth the battery.

## 5. Make the live meeting visible

**Problem.** A meeting in progress is in `~/.susurro/live` and appears nowhere in the UI, so
during a call the app shows you nothing. That is a consequence of the segregation that makes
rewriting safe, not a goal.

**Shape.** A read-only view of the live file. Reading is safe; only writing is not. No
speakers yet — they do not exist until it closes — so it is `me` and `unknown` with text,
which is still worth having during a call.

## Measure first

These need data before they are worth building. All of them are a script over
`~/.susurro/transcripts`, not a feature.

- **Re-calibrate `clusterThreshold` on meetings clustered by the new path**, once a handful
  exist. The current number is defensible but was derived from data the old matcher shaped.
  Re-cluster the same meetings at a range of thresholds and read the transcripts.
- **Does re-clustering change anything?** If the answer is no across ten real meetings, item
  1 is a debugging tool rather than a feature, and item 3 matters more.
- **How often does one cluster hold two voices?** Decides item 4 entirely.
- **How separated are meeting-level centroids, really?** Decides whether item 2 is worth
  more than the frequency suggestions already shipped.

## Housekeeping

- **`~/.susurro/speakers.json` is read by nothing.** Kept only because it holds the sole
  real segment embeddings available for calibration. Delete it once the new path has produced
  enough meetings to calibrate against — and note it is a biometric database of people who
  agreed to be in a meeting, not to this.
- **Sidecar adoption is one release's worth of code.** `TranscriptNames.adoptSidecars`
  (`Speaker.swift`) folds `.names.json` files into their transcripts. Delete it once no
  machine has one left.
- **`TranscriptSnippets` re-reads every transcript on every call, with no index.** A few MB
  of JSONL is nothing next to the window it feeds. Index it the day that stops being true —
  the meeting list already decodes every file each time it opens.
- **Old transcripts cannot be re-clustered.** Anything written before this change has
  `user-N` labels and no `.emb`. They read and name fine and there is nothing to do; just do
  not expect item 1 to reach them.
- **A live-file name collision is retried forever.** `Transcriber.publishStragglers` leaves a
  file in place if the destination exists, and will collide again next launch. Stamps are
  second-resolution so this needs two runs to hit the same second; if it ever happens, add a
  suffix.

## Deliberately not doing

- **Restoring cross-day speaker identity as an authority.** It is the thing that broke. A
  cross-day match may suggest; it may not label.
- **Asking for, or guessing, the number of speakers.** The threshold decides it. Every
  version of "how many people were in this call" is a worse input than the audio.
- **Storing embeddings in the transcript JSONL.** 256 floats is ~3 KB of JSON per line, which
  would grow a 100 KB transcript past 1.5 MB and make it unreadable for the humans and agents
  the transcript exists for.
