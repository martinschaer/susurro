import FluidAudio
import Foundation

/// Turns a segment of speech into a 256-d voiceprint. Nothing more — no gallery, no
/// matching, no identity.
///
/// Who spoke is decided once the meeting is over, by `Cluster.speakers`, from every
/// segment at once. Deciding it here, segment by segment as they arrive, was the old
/// design and the reason speaker labels were unusable: each 10-second window was matched
/// against a gallery of voiceprints accumulated across weeks, and a window is far too
/// little evidence for that comparison. Across 23 meetings it minted 139 speakers, 41% of
/// which spoke exactly one line; the gallery reached 67 entries whose median
/// nearest-neighbour distance was 0.354 against a 0.35 cutoff, at which point it could no
/// longer separate anybody from anybody.
///
/// Within one meeting the same embeddings work well, because the room, the microphone and
/// the codec are held constant and every speaker is judged on all of their audio rather
/// than one window of it. So the model stays and the gallery goes.
///
/// Not thread-safe. `Transcriber` owns the only reference and touches it solely from its
/// serial queue.
final class VoicePrints {
    private let diarizer = DiarizerManager()

    /// wespeaker's window, and a hard cap rather than a preference: the extractor copies
    /// the whole input into a `[3, 160000]` batch buffer without clamping, so a longer
    /// clip writes over the neighbouring batch slots. Only slot 0 is read back, so
    /// trimming loses nothing a longer clip would have contributed anyway.
    private static let window = 160_000        // 10 s @ 16 kHz

    init?(models dir: URL) {
        // The segmentation model is loaded but never run: `extractSpeakerEmbedding` reads
        // the frame count (589) off its output shape to size the mask. Hardcoding that
        // number would save 6 MB and break silently the day the model changes.
        guard let m = try? DiarizerModels.load(
            localSegmentationModel: dir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: dir.appendingPathComponent("wespeaker_v2.mlmodelc"))
        else { return nil }
        diarizer.initialize(models: m)
    }

    /// `nil` when the extractor refuses the clip — too short to embed at all.
    ///
    /// Normalised before it is handed back. The extractor does *not* return unit vectors —
    /// a raw pair can have a dot product above 1, which reads as a negative cosine
    /// distance — and FluidAudio normalised them on the way into its gallery, which is why
    /// nothing noticed while the gallery was doing the comparing.
    func embed(_ samples: [Float]) -> [Float]? {
        let clip = samples.count > Self.window ? Array(samples[0..<Self.window]) : samples
        guard let raw = try? diarizer.extractSpeakerEmbedding(from: clip) else { return nil }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? raw.map { $0 / norm } : nil
    }
}

// MARK: - voiceprints on disk

/// Every segment's voiceprint for one meeting, as a flat wall of `Float32`, in the order
/// the segments were written. A transcript line carries its index in `seg`.
///
/// Beside the transcript rather than in it: 256 floats is 3 KB of JSON per line, which
/// would grow a 100 KB transcript past 1.5 MB and make it unreadable for the humans and
/// agents the transcript exists for. Binary, it is 1 KB a segment — 570 KB for the longest
/// meeting here.
///
/// Kept after the meeting is clustered, not deleted, because every future improvement to
/// clustering is then a re-run over old meetings instead of something that only helps from
/// today onward. That is the whole reason this file exists.
enum VoicePrintFile {
    static func url(for transcript: URL) -> URL {
        transcript.deletingPathExtension().appendingPathExtension("emb")
    }

    /// Dimensions are fixed by the model. A file whose length is not a multiple of this is
    /// truncated — a crash mid-write — and the trailing partial vector is dropped.
    static let dims = 256

    static func append(_ embedding: [Float], to url: URL) {
        var floats = embedding
        let data = Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
        guard let h = try? FileHandle(forWritingTo: url) else {
            // First segment of the meeting: the file does not exist yet.
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
            return
        }
        h.seekToEndOfFile()
        h.write(data)
        try? h.synchronize()
        try? h.close()
    }

    static func load(for transcript: URL) -> [[Float]] {
        guard let data = try? Data(contentsOf: url(for: transcript)) else { return [] }
        let stride = dims * MemoryLayout<Float>.size
        return (0..<(data.count / stride)).map { i in
            data.subdata(in: i * stride..<(i + 1) * stride).withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
        }
    }
}

// MARK: - clustering

/// Who spoke in one meeting, worked out from all of its voiceprints at once.
///
/// Agglomerative with average linkage: start with every segment its own cluster, repeatedly
/// merge the two closest, stop when the closest pair is further apart than `threshold`.
/// Average linkage rather than nearest-neighbour because single linkage chains — one
/// borderline segment between two people welds both into a single cluster, which is the
/// failure that loses a transcript.
///
/// The number of speakers is not asked for and not guessed; the threshold decides it.
enum Cluster {
    /// Cosine distance. `VoicePrints.embed` already normalises, so the division is
    /// usually by one — it is here because assuming it silently produced a *negative*
    /// distance on raw extractor output, and this is called a few hundred times per
    /// meeting, not in a hot loop.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na * nb).squareRoot()
    }

    /// Cluster index per input segment. `nil` for a segment that carries no voiceprint.
    ///
    /// `durations` are per segment, and a cluster holding less speech than `minSeconds` is
    /// dropped — returned as `nil` — because it is a cough or a "yeah" rather than a
    /// person. Clusters come back ordered by how much was said, so speaker 0 is whoever
    /// talked most.
    static func speakers(_ prints: [[Float]?], durations: [Double],
                         threshold: Float, minSeconds: Double) -> [Int?] {
        // Only segments with a voiceprint take part; the rest keep a nil slot.
        let live = prints.indices.filter { prints[$0] != nil }
        guard !live.isEmpty else { return prints.map { _ in nil } }

        var members: [[Int]] = live.map { [$0] }        // cluster -> segment indices

        // Average linkage over the *segment* pairs, kept as a running sum so a merge is an
        // addition rather than a re-scan of both clusters.
        var sums: [[Float]] = members.indices.map { i in
            members.indices.map { j in
                i == j ? 0 : distance(prints[members[i][0]]!, prints[members[j][0]]!)
            }
        }
        // An array and not a `Set`: this scan is the hot part — O(clusters²) per merge and
        // one merge per segment — and iterating a Set costs several times what iterating
        // contiguous Ints does. A long meeting is a few hundred segments.
        var alive = Array(members.indices)

        while alive.count > 1 {
            var best = (d: Float.infinity, a: 0, b: 0)
            for x in 0..<alive.count {
                let i = alive[x]
                for y in (x + 1)..<alive.count {
                    let j = alive[y]
                    let d = sums[i][j] / Float(members[i].count * members[j].count)
                    if d < best.d { best = (d, x, y) }
                }
            }
            guard best.d <= threshold else { break }

            let a = alive[best.a], b = alive[best.b]
            // Merge b into a, and fold b's summed distances into a's.
            for k in alive where k != a && k != b {
                sums[a][k] += sums[b][k]
                sums[k][a] = sums[a][k]
            }
            members[a] += members[b]
            members[b] = []
            alive.remove(at: best.b)
        }

        // Rank by speech, drop the ones too small to be a person.
        let ranked = alive.map { c in (c, members[c].reduce(0.0) { $0 + durations[$1] }) }
            .filter { $0.1 >= minSeconds }
            .sorted { $0.1 > $1.1 }

        var out = [Int?](repeating: nil, count: prints.count)
        for (rank, entry) in ranked.enumerated() {
            for segment in members[entry.0] { out[segment] = rank }
        }
        return out
    }
}

// MARK: - the transcript

/// One line of a transcript, as it is on disk. The writer, the reader and the namer share
/// it so the schema exists once. `JSONEncoder` does not emit keys in declaration order, so
/// a rewritten line is reordered — same object, different byte layout.
///
/// Everything but `ts`, `speaker` and `text` is optional so that a hand-written or older
/// line still decodes — a reader that insists on every field turns a fixture into a parse
/// error, and `JSONEncoder` omits a nil rather than writing `null`.
struct TranscriptLine: Codable {
    let ts: String
    let source: String?
    /// `me` for your microphone, `unknown` until the meeting is clustered or when the
    /// segment was too little speech to place, and otherwise `s1`, `s2`, … — whoever
    /// talked most is `s1`. Meeting-local by construction: `s1` here and `s1` in another
    /// transcript are not a claim about the same person.
    var speaker: String
    let dur: Double?
    let lang: String?
    let text: String
    /// Index of this segment's voiceprint in the `.emb` file beside the transcript. Carried
    /// on the line rather than implied by position so that re-clustering a meeting years
    /// from now cannot mis-align, whatever happened to the file in between.
    let seg: Int?
    /// Who `speaker` turned out to be *in this meeting*, filled in afterwards by the naming
    /// window. Absent until somebody says.
    var name: String?
}

/// Assigning `speaker` from the meeting's own clustering, once the file is closed.
///
/// Separate from `TranscriptNames` only because one is the machine's opinion and the other
/// is yours; they are the same whole-file rewrite, and both are safe for the same reason —
/// nothing appends to a transcript that has left `Transcriber.defaultLiveDir`.
enum TranscriptSpeakers {
    /// Cluster every voiceprint of `transcript` and write the result onto its lines.
    ///
    /// Called when a meeting ends, and again for anything a crash stranded. Needs no model:
    /// the voiceprints are already on disk and cosine is arithmetic, so this runs on a
    /// launch that never loads whisper.
    static func assign(_ transcript: URL, threshold: Float, minSeconds: Double) {
        let prints = VoicePrintFile.load(for: transcript)
        let lines = TranscriptSnippets.decode(transcript)
        guard !prints.isEmpty, !lines.isEmpty else { return }

        // Indexed by `seg`, so a line the decoder could not read costs only itself.
        var byLine: [[Float]?] = [], durations: [Double] = []
        for line in lines {
            let print = line?.seg.flatMap { prints.indices.contains($0) ? prints[$0] : nil }
            byLine.append(print)
            durations.append(line?.dur ?? 0)
        }

        let clusters = Cluster.speakers(byLine, durations: durations,
                                        threshold: threshold, minSeconds: minSeconds)
        var speakers: [Int: String] = [:]
        for (i, cluster) in clusters.enumerated() where byLine[i] != nil {
            speakers[i] = cluster.map { "s\($0 + 1)" } ?? "unknown"
        }
        rewrite(transcript) { i, line in
            guard let speaker = speakers[i] else { return line }
            var line = line
            line.speaker = speaker
            return line
        }
    }

    /// Rewrite every line of a transcript through `edit`, atomically, keeping a line the
    /// decoder cannot read byte for byte. The one operation that touches a transcript, so
    /// the guarantee lives in one place.
    static func rewrite(_ transcript: URL,
                        _ edit: (Int, TranscriptLine) -> TranscriptLine) {
        guard let body = try? String(contentsOf: transcript, encoding: .utf8) else { return }
        let decoder = JSONDecoder(), encoder = JSONEncoder()

        // `omittingEmptySubsequences: false` keeps the empty piece after the final newline,
        // so joining restores it and the file stays appendable-looking.
        let out = body.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { i, raw -> String in
                guard let line = try? decoder.decode(TranscriptLine.self, from: Data(raw.utf8)),
                      let data = try? encoder.encode(edit(i, line)),
                      let text = String(data: data, encoding: .utf8)
                else { return String(raw) }
                return text
            }.joined(separator: "\n")

        guard let data = out.data(using: .utf8) else { return }
        try? data.write(to: transcript, options: .atomic)   // a rename, permissions after
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: transcript.path)
    }
}

/// Who each voice was in one meeting, written onto the meeting's own lines.
///
/// Per transcript and not per gallery entry because a `user-N` is a voiceprint cluster, not
/// a person. Across days the embedding degrades enough that two people merge into one
/// cluster (SPEC.md § Known limitations), so a name that is right in Monday's call is wrong
/// in Thursday's, and a single global name has no way to say so.
///
/// In the file and not in a sidecar so that the transcript is self-describing: whatever
/// reads it next — a script, an agent — gets the names without being told where else to
/// look. That is only safe because a transcript being appended to lives in a different
/// directory (`Transcriber.defaultLiveDir`) and never reaches this code: `Transcriber`
/// holds an open file handle at a cached offset, and rewriting underneath it would land
/// the next append in the middle of the file.
enum TranscriptNames {
    /// The names currently on a transcript, by voice.
    static func load(for transcript: URL) -> [String: String] {
        var names: [String: String] = [:]
        for line in TranscriptSnippets.decode(transcript) {
            guard let line, let name = line.name else { continue }
            names[line.speaker] = name
        }
        return names
    }

    /// Put `names` on every line they apply to. A blank name removes it; a voice that is
    /// not mentioned is left alone.
    ///
    /// Whole-file rewrite — 13 ms on the largest transcript here, which is why the window
    /// writes on commit and not on every keystroke.
    static func apply(_ names: [String: String], to transcript: URL) {
        TranscriptSpeakers.rewrite(transcript) { _, line in
            guard let typed = names[line.speaker] else { return line }
            var line = line
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            line.name = name.isEmpty ? nil : name
            return line
        }
    }

    /// Names used to live in a `<stamp>.names.json` beside the transcript. Fold any that
    /// are still there into the transcript and delete them.
    ///
    /// ponytail: one release's worth of code. Delete it once no machine has a sidecar left.
    static func adoptSidecars(in dir: URL) {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for sidecar in all where sidecar.lastPathComponent.hasSuffix(".names.json") {
            let transcript = sidecar.deletingPathExtension()   // <stamp>.names
                .deletingPathExtension().appendingPathExtension("jsonl")
            guard let data = try? Data(contentsOf: sidecar),
                  let names = try? JSONDecoder().decode([String: String].self, from: data),
                  FileManager.default.fileExists(atPath: transcript.path)
            else { continue }
            apply(names, to: transcript)
            try? FileManager.default.removeItem(at: sidecar)
        }
    }
}

// MARK: - reading the transcripts

/// What a voice actually said, so a human can work out whose it is. A `user-N` on its own
/// is unnamable: nobody remembers which FluidAudio id was Ana, but everybody recognises
/// what she said. Read straight off the JSONL for the same reason `SpeakerNames` is — the
/// naming window must work with Listening off and no models loaded.
enum TranscriptSnippets {
    /// One line of transcript and who said it — `me`, a `user-N`, or, in a transcript
    /// written before names came out of this field, a name.
    struct Turn: Equatable { let speaker: String, text: String }

    /// A line with the turns either side of it, so the exchange can be read rather than the
    /// line alone. "Yeah, that works for me" identifies nobody; the same line between two
    /// of yours does.
    struct Snippet { let ts: String; let before: Turn?; let line: Turn; let after: Turn? }

    /// One voice as it appears in one meeting.
    struct Voice: Identifiable {
        let label: String     // `user-3`, or a name in a transcript written before the split
        /// What this meeting calls them, if anybody has said.
        let name: String?
        let lines: Int
        /// The longest thing it said. A first line is usually "yeah" or "hi"; the longest
        /// one is the one somebody can actually recognise.
        let sample: String
        var id: String { label }
    }

    /// One transcript file and the voices heard in it. `me` is you and needs no naming;
    /// `unknown` is the speaker models having failed to load, and naming it would attach a
    /// person to a bucket of unrelated audio.
    struct Meeting: Identifiable {
        let url: URL
        let lines: Int
        let voices: [Voice]
        var id: URL { url }

        /// `2026-09-15_14-02-11` as `2026-09-15 14:02`. Seconds are in the file name to
        /// keep an off/on inside one minute from reopening the previous session's file;
        /// they are noise in a list.
        var stamp: String {
            let base = url.deletingPathExtension().lastPathComponent
            let parts = base.split(separator: "_")
            guard parts.count == 2 else { return base }
            return "\(parts[0]) \(parts[1].split(separator: "-").prefix(2).joined(separator: ":"))"
        }
    }

    /// Every meeting, newest first. The file names are sortable timestamps, so ordering
    /// them is a string compare and never a `stat`.
    ///
    /// ponytail: re-reads every file on every call, no index. A few MB of JSONL is nothing
    /// next to the window it feeds — index it the day that stops being true.
    static func meetings(dir: URL = Transcriber.defaultDir) -> [Meeting] {
        files(in: dir).reversed().map { file in
            let lines = decode(file)
            var counts: [String: Int] = [:]
            var samples: [String: String] = [:]
            var named: [String: String] = [:]
            for line in lines.compactMap({ $0 })
            where line.speaker != "me" && line.speaker != "unknown" {
                counts[line.speaker, default: 0] += 1
                if line.text.count > (samples[line.speaker]?.count ?? 0) {
                    samples[line.speaker] = line.text
                }
                if let name = line.name { named[line.speaker] = name }
            }
            let voices = counts.keys.sorted().map {
                Voice(label: $0, name: named[$0], lines: counts[$0] ?? 0, sample: samples[$0] ?? "")
            }
            // Decodable lines only: a half-written tail is not a line anybody can read.
            return Meeting(url: file, lines: lines.compactMap { $0 }.count, voices: voices)
        }
    }

    /// Everything this voice said in one meeting, in order, each with the turn either side.
    ///
    /// Chronological and complete rather than a random sample: one meeting is a bounded
    /// amount of text, and read in order it is a conversation, which identifies a voice
    /// better than ten lines out of context ever did.
    static func lines(for voice: String, in transcript: URL) -> [Snippet] {
        let lines = decode(transcript)
        return lines.indices.compactMap { i in
            guard let line = lines[i], line.speaker == voice else { return nil }
            return Snippet(ts: line.ts, before: turn(lines, i - 1),
                           line: Turn(speaker: line.speaker, text: line.text),
                           after: turn(lines, i + 1))
        }
    }

    /// A name this voice went by elsewhere, and how many meetings agreed.
    struct Suggestion: Identifiable, Equatable {
        let name: String, count: Int
        var id: String { name }
    }

    /// What this voice has been called in *other* meetings, most-used first, ties
    /// alphabetical. The gallery holds the voiceprint; the meetings are the only record of
    /// who it turned out to be, and a name you have used four times is a better guess than
    /// one you used once.
    ///
    /// A pure tally over meetings already in hand — reading the transcripts again here
    /// would decode every file on every menu.
    static func suggestions(for voice: String, excluding transcript: URL? = nil,
                            in meetings: [Meeting]) -> [Suggestion] {
        // By file name, not by URL: `contentsOfDirectory` hands back `/private/var/...`
        // where the caller said `/var/...`, and two URLs for one file would have this
        // meeting voting for itself.
        var votes: [String: Int] = [:]
        for m in meetings where m.url.lastPathComponent != transcript?.lastPathComponent {
            guard let name = m.voices.first(where: { $0.label == voice })?.name else { continue }
            votes[name, default: 0] += 1
        }
        return votes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                    .map { Suggestion(name: $0.key, count: $0.value) }
    }

    // MARK: -

    /// Transcript files, oldest first. Sidecars end `.names.json` and are skipped here.
    private static func files(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "jsonl" }
                  .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `map`, not `compactMap`: the array has to stay the same length as the file or index
    /// ±1 is not the adjacent line any more, and every snippet after a dropped line would
    /// quote the wrong person. An undecodable line — the half-written tail of a file the
    /// engine is appending to — is context nobody gets instead.
    static func decode(_ file: URL) -> [TranscriptLine?] {
        guard let body = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return body.split(separator: "\n").map {
            try? decoder.decode(TranscriptLine.self, from: Data($0.utf8))
        }
    }

    private static func turn(_ lines: [TranscriptLine?], _ i: Int) -> Turn? {
        guard lines.indices.contains(i), let l = lines[i] else { return nil }
        return Turn(speaker: l.speaker, text: l.text)
    }
}
