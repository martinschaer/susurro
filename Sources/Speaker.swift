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

    /// Label one segment. Returns the name to record and the cosine distance to the
    /// speaker it matched — `.infinity` when it matched nobody and started a new entry.
    ///
    /// `nil` means the segment was too short to identify *and* too short to enroll, which
    /// is `minSpeechDuration` doing its job: a sub-second grunt makes a bad centroid, and
    /// a bad centroid poisons every match after it.
    func label(_ samples: [Float]) -> (name: String, dist: Float)? {
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

        return (speaker.label, dist)
    }

    // MARK: - gallery

    private func save() {
        // A name is the one field a human edits behind our back: the naming window writes
        // straight to the file, so it works with Listening off. Adopt those names before
        // overwriting, or flushing the drifted centroids reverts the rename.
        //
        // ponytail: adopted at save time, so a rename reaches the live labels at the next
        // flush rather than immediately. Push it through Transcriber's queue if that grates.
        for edited in SpeakerNames.load(from: url) where edited.isNamed {
            guard var mine = diarizer.speakerManager.getSpeaker(for: edited.id),
                  mine.name != edited.name else { continue }
            mine.name = edited.name
            diarizer.speakerManager.upsertSpeaker(mine)
        }
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

/// The gallery as a plain file, with no models attached: the naming window has to work
/// while Listening is off, and loading wespeaker just to rename someone would cost 6 MB
/// and, on a cold start, half a minute.
enum SpeakerNames {
    static func load(from url: URL = SpeakerBook.defaultURL) -> [Speaker] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Speaker].self, from: data)
        else { return [] }
        return list.sorted { $0.createdAt < $1.createdAt }   // enrolment order, like user-N
    }

    /// Write `names` (id → name) over whatever is on disk *now*, ignoring blanks. Re-reading
    /// instead of encoding the window's own copy: a running engine may have enrolled someone
    /// since the window opened, and that embedding must survive somebody else's rename.
    static func save(_ names: [String: String], to url: URL = SpeakerBook.defaultURL) {
        var list = load(from: url)
        for i in list.indices {
            guard let typed = names[list[i].id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !typed.isEmpty
            else { continue }
            list[i].name = typed
        }
        write(list, to: url)
    }

    /// This file is a voiceprint database of people who agreed to be in a meeting, not to
    /// this. Same 0700 as the transcripts, and deleting it forgets everyone.
    static func write(_ list: [Speaker], to url: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)   // a rename, so permissions come after
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Speaker {
    /// FluidAudio names a new speaker `Speaker <id>`. Anything else a human typed, and wins.
    var isNamed: Bool { !name.hasPrefix("Speaker ") }

    /// What the transcript calls this voice.
    var label: String { isNamed ? name : "user-\(id)" }
}

// MARK: - snippets

/// What a voice actually said, so a human can work out whose it is. A `user-N` on its own
/// is unnamable: nobody remembers which FluidAudio id was Ana, but everybody recognises
/// what she said. Read straight off the JSONL for the same reason `SpeakerNames` is — the
/// naming window must work with Listening off and no models loaded.
enum TranscriptSnippets {
    private struct Line: Decodable { let ts, speaker, text: String }

    /// One line of transcript and who said it — `me`, a `user-N` or a name.
    struct Turn: Equatable { let speaker: String, text: String }

    /// A sampled line with the turns either side of it, so the exchange can be read rather
    /// than the line alone. "Yeah, that works for me" identifies nobody; the same line
    /// between two of yours does.
    struct Snippet { let ts: String; let before: Turn?; let line: Turn; let after: Turn? }

    /// Up to `count` lines this speaker spoke, sampled at random across every transcript.
    ///
    /// `Transcriber` records `Speaker.label` at write time, so lines from before a rename
    /// say `user-N` and lines from after say the name — both belong to this voice. A voice
    /// renamed twice loses its middle-era lines; see SPEC.md § Known limitations.
    ///
    /// ponytail: re-reads every file on every call, no index. A few MB of JSONL is nothing
    /// next to the window it feeds — index it the day that stops being true.
    static func random(for speaker: Speaker, count: Int = 10,
                       dir: URL = Transcriber.defaultDir) -> [Snippet] {
        var wanted: Set<String> = ["user-\(speaker.id)"]
        if speaker.isNamed { wanted.insert(speaker.name) }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var hits: [Snippet] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }

            // `map`, not `compactMap`: the array has to stay the same length as the file or
            // index ±1 is not the adjacent line any more, and every snippet after a dropped
            // line would quote the wrong person. An undecodable line — the half-written
            // tail of a file the engine is appending to — is context nobody gets instead.
            let lines = body.split(separator: "\n").map {
                try? decoder.decode(Line.self, from: Data($0.utf8))
            }
            for (i, line) in lines.enumerated() {
                guard let line, wanted.contains(line.speaker) else { continue }
                // Neighbours come from this file only, which is to say this meeting only.
                hits.append(Snippet(ts: line.ts, before: turn(lines, i - 1),
                                    line: Turn(speaker: line.speaker, text: line.text),
                                    after: turn(lines, i + 1)))
            }
        }
        return Array(hits.shuffled().prefix(count))
    }

    private static func turn(_ lines: [Line?], _ i: Int) -> Turn? {
        guard lines.indices.contains(i), let l = lines[i] else { return nil }
        return Turn(speaker: l.speaker, text: l.text)
    }
}
