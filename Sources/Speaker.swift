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

    /// wespeaker's window, and a hard cap rather than a preference: the extractor copies
    /// the whole input into a `[3, 160000]` batch buffer without clamping, so a longer
    /// clip writes over the neighbouring batch slots. Only slot 0 is read back, so
    /// trimming loses nothing a longer clip would have contributed anyway.
    private static let window = 160_000        // 10 s @ 16 kHz

    /// FluidAudio names a new speaker `Speaker <id>`. Anything else is a name a human
    /// typed into speakers.json, and wins.
    private static let unnamed = "Speaker "

    init?(models dir: URL, threshold: Float, url: URL = SpeakerBook.defaultURL) {
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
        diarizer.speakerManager = SpeakerManager(speakerThreshold: threshold)

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

        let dist = diarizer.speakerManager.findSpeaker(with: embedding).distance
        let before = diarizer.speakerManager.speakerCount
        guard let speaker = diarizer.speakerManager.assignSpeaker(
            embedding, speechDuration: Float(samples.count) / 16000)
        else { return nil }

        // Centroids drift a little on every match and that loss is cheap; a brand new
        // speaker is not, so that is the one moment worth paying a disk write for.
        if diarizer.speakerManager.speakerCount != before { save() }

        let name = speaker.name.hasPrefix(Self.unnamed) ? "user-\(speaker.id)" : speaker.name
        return (name, dist)
    }

    // MARK: - gallery

    /// This file is a voiceprint database of people who agreed to be in a meeting, not to
    /// this. Same 0700 as the transcripts, and deleting it forgets everyone.
    private func save() {
        guard let data = try? JSONEncoder().encode(diarizer.speakerManager.getSpeakerList())
        else { return }
        try? data.write(to: url, options: .atomic)   // a rename, so permissions come after
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let speakers = try? JSONDecoder().decode([Speaker].self, from: data)
        else { return }
        diarizer.speakerManager.initializeKnownSpeakers(speakers, mode: .reset)
    }

    /// Flush the drifted centroids. Called once, from `Transcriber.close`.
    func close() { save() }
}
