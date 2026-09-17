import FluidAudio
import Foundation

/// Who is talking on the `system` stream, and whether we heard them before — including
/// on an earlier day.
///
/// Diarization proper answers "where are the speaker boundaries in this recording", but
/// `Segmenter` has already done most of that: it cuts on 700 ms of silence, and a
/// conversational turn usually ends with a pause, so an emitted segment is normally one
/// person. That reduces the job to: embed the segment as a single speaker, then match the
/// vector against a gallery. Two people inside one segment are not split — see SPEC.md
/// § Known limitations.
///
/// The gallery is what makes the labels survive a restart. Diarizers hand out
/// session-local ids that are renumbered every run; a 256-d embedding on disk is the only
/// thing that carries identity from Monday to Tuesday.
///
/// Not thread-safe: `SpeakerManager` is a struct mutated in place. `Transcriber` owns the
/// only reference and touches it solely from its serial queue.
final class SpeakerBook {
    private let diarizer = DiarizerManager()
    private let url: URL
    private var lastSave = Date.distantPast
    private let drift: Float

    /// wespeaker's window, and a hard cap rather than a preference: the extractor copies
    /// the whole input into a `[3, 160000]` batch buffer without clamping, so a longer
    /// clip writes over the neighbouring batch slots. Only slot 0 is read back, so
    /// trimming loses nothing a longer clip would have contributed anyway.
    private static let window = 160_000        // 10 s @ 16 kHz

    /// EMA updates a voiceprint is allowed before it is frozen. `drift` bounds one hop;
    /// nothing bounds the sum, and the hops compound in one direction. Measured on this
    /// machine's gallery: 50 hops walked a centroid 0.23 from where it started, which is
    /// most of the way to a different person. At alpha 0.9 the mean is 88% converged
    /// after 20 hops, so the ones after that buy accuracy no longer available to buy.
    private static let settled = 20

    init?(models dir: URL, threshold: Float, drift: Float = 0.25,
          url: URL = SpeakerBook.defaultURL) {
        // The segmentation model is loaded but never run: `extractSpeakerEmbedding` reads
        // the frame count (589) off its output shape to size the mask. Hardcoding that
        // number would save 6 MB and break silently the day the model changes.
        guard let m = try? DiarizerModels.load(
            localSegmentationModel: dir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: dir.appendingPathComponent("wespeaker_v2.mlmodelc"))
        else { return nil }
        diarizer.initialize(models: m)

        // FluidAudio derives its thresholds from a clustering config this path never uses.
        // Ours comes from config.json: the right cutoff depends on the room and on what
        // the conferencing codec did to the voice, exactly like the RMS gate.
        //
        // `drift` is the one that keeps a gallery honest. Every match under it EMA-blends
        // the segment into the stored voiceprint, so leaving it at FluidAudio's 0.45 lets
        // the centroid wander toward whoever is talking now — it ends up the mean voice in
        // the room, within `threshold` of everybody, and no second speaker is ever minted.
        diarizer.speakerManager = SpeakerManager(
            speakerThreshold: threshold, embeddingThreshold: drift)

        self.drift = drift
        self.url = url
        load()
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/speakers.json")
    }

    /// Identify one segment. Returns the gallery id of the voice and the cosine distance
    /// to it — `.infinity` when it matched nobody and started a new entry.
    ///
    /// An id, never a name: a voiceprint cluster is not a person. The same cluster is a
    /// different human in a different room, so the name belongs to the transcript and is
    /// resolved at read time by `TranscriptNames`.
    ///
    /// `nil` means the segment was too short to identify *and* too short to enroll, which
    /// is `minSpeechDuration` doing its job: a sub-second grunt makes a bad centroid, and
    /// a bad centroid poisons every match after it.
    func label(_ samples: [Float]) -> (id: String, dist: Float)? {
        let clip = samples.count > Self.window ? Array(samples[0..<Self.window]) : samples
        guard let embedding = try? diarizer.extractSpeakerEmbedding(from: clip) else { return nil }

        let match = diarizer.speakerManager.findSpeaker(with: embedding)

        // Freeze the voiceprint once it is built from enough speech, by denying this one
        // assignment the right to move it. A centroid that keeps chasing the room becomes
        // the average voice in it and then matches everybody — the failure `drift` was
        // meant to stop, and only slows, because it caps each hop and not the walk.
        let updates = match.id.flatMap {
            diarizer.speakerManager.getSpeaker(for: $0)?.updateCount
        } ?? 0
        diarizer.speakerManager.embeddingThreshold = updates >= Self.settled ? 0 : drift

        let dist = match.distance
        let before = diarizer.speakerManager.speakerCount
        guard let speaker = diarizer.speakerManager.assignSpeaker(
            embedding, speechDuration: Float(samples.count) / 16000)
        else { return nil }

        // A brand new speaker is worth a disk write on the spot. The drifted centroids
        // are not, but a file that never moves for hours reads as a broken feature — so
        // they go out on a minute's timer.
        if diarizer.speakerManager.speakerCount != before
            || Date().timeIntervalSince(lastSave) > 60 { save() }

        return (speaker.id, dist)
    }

    // MARK: - gallery

    // Nothing here re-reads the names off disk first, because nothing on this file is
    // hand-edited any more: names live per-transcript in `TranscriptNames`, and the only
    // field the gallery owns is the voiceprint this write exists to flush.
    private func save() {
        SpeakerNames.write(diarizer.speakerManager.getSpeakerList(), to: url)
        lastSave = Date()
    }

    private func load() {
        let known = SpeakerNames.load(from: url)
        guard !known.isEmpty else { return }
        diarizer.speakerManager.initializeKnownSpeakers(known, mode: .reset)
    }

    /// Flush the drifted centroids. Called once, from `Transcriber.close`.
    func close() { save() }
}

// MARK: - naming

/// Write JSON at `0600`, atomically. Same permissions as the transcripts: a voiceprint
/// database and a list of who was in the room are equally nobody else's business.
private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: .atomic)   // a rename, so permissions come after
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// The gallery as a plain file, with no models attached: the naming window has to work
/// while Listening is off, and loading wespeaker just to read a roster would cost 6 MB
/// and, on a cold start, half a minute.
///
/// No `save` here. The `name` field on a `Speaker` is FluidAudio's, is always `Speaker N`,
/// and nothing reads it: names live on the transcript lines themselves.
enum SpeakerNames {
    static func load(from url: URL = SpeakerBook.defaultURL) -> [Speaker] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Speaker].self, from: data)
        else { return [] }
        return list.sorted { $0.createdAt < $1.createdAt }   // enrolment order, like user-N
    }

    /// This file is a voiceprint database of people who agreed to be in a meeting, not to
    /// this. Same 0600 as the transcripts, and deleting it forgets everyone.
    static func write(_ list: [Speaker], to url: URL) { writeJSON(list, to: url) }
}

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
    /// `me`, `user-N`, or `unknown`. A cluster id, never a person.
    let speaker: String
    let dist: Double?
    let dur: Double?
    let lang: String?
    let text: String
    /// Who `speaker` turned out to be *in this meeting*, filled in afterwards by the naming
    /// window. Absent until somebody says.
    var name: String?
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
    /// Whole-file rewrite, atomically — 13 ms on the largest transcript here, which is why
    /// the window writes on commit and not on every keystroke.
    static func apply(_ names: [String: String], to transcript: URL) {
        guard let body = try? String(contentsOf: transcript, encoding: .utf8) else { return }
        let decoder = JSONDecoder(), encoder = JSONEncoder()

        // `omittingEmptySubsequences: false` keeps the empty piece after the final newline,
        // so joining restores it and the file stays appendable-looking.
        let rewritten = body.split(separator: "\n", omittingEmptySubsequences: false).map {
            raw -> String in
            // A line this cannot read — the tail a crash left half-written — goes back
            // byte for byte. Rewriting a transcript must never cost it a line.
            guard var line = try? decoder.decode(TranscriptLine.self, from: Data(raw.utf8)),
                  let typed = names[line.speaker]
            else { return String(raw) }
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            line.name = name.isEmpty ? nil : name
            guard let data = try? encoder.encode(line),
                  let text = String(data: data, encoding: .utf8)
            else { return String(raw) }
            return text
        }.joined(separator: "\n")

        guard let data = rewritten.data(using: .utf8) else { return }
        try? data.write(to: transcript, options: .atomic)   // a rename, so permissions come after
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: transcript.path)
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
