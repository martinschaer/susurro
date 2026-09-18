import Foundation

/// One resident whisper context, fed from a serial queue.
///
/// A `whisper_context` is not reentrant, so both capture streams funnel through
/// `queue`. Segments are seconds long, so queueing costs latency but never audio,
/// and it halves resident memory versus one context per stream.
final class Transcriber {
    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "dev.susurro.whisper", qos: .utility)
    private let dir: URL

    // Touched only from `queue`, which is what keeps it single-threaded.
    private let voices: VoicePrints?
    private let clusterThreshold: Float
    private let minSpeakerSec: Double

    /// How many voiceprints this meeting has written, which is the next one's `seg`.
    private var segs = 0

    // whisper stores these as `const char *` without copying, so they must outlive
    // every whisper_full call — hence strdup rather than a Swift String.
    private let vadPath: UnsafeMutablePointer<CChar>?
    private let autoLang: UnsafeMutablePointer<CChar>

    /// Silence longer than this on both streams ends the file. See `append`.
    private let gapSec: Double

    private var handle: FileHandle?
    private var live: URL?                 // the file `handle` is open on, in `liveDir`
    private var lastWrite = Date.distantPast
    private var closed = false

    /// Where a transcript lives *while it is being written*. Not a detail: naming a voice
    /// rewrites the whole file, and this handle keeps a cached offset from
    /// `seekToEndOfFile()` that a rewrite underneath it would leave pointing mid-file, so
    /// the next append would overwrite real lines. Keeping the open file out of the
    /// directory anything else reads makes that impossible rather than unlikely.
    private let liveDir: URL

    /// Seconds, not minutes: an off/on inside the same minute must not reopen the
    /// previous session's file.
    private static let fileFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current          // local offset, not Z — matches the file name
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init?(model: URL, vad: URL?, voices: VoicePrints? = nil, gapSec: Double = 300,
          clusterThreshold: Float = 0.4, minSpeakerSec: Double = 3,
          dir: URL = Transcriber.defaultDir, liveDir: URL = Transcriber.defaultLiveDir) {
        self.liveDir = liveDir
        self.gapSec = gapSec
        self.clusterThreshold = clusterThreshold
        self.minSpeakerSec = minSpeakerSec
        var cp = whisper_context_default_params()
        cp.use_gpu = true              // Metal is off at build time; the Core ML
                                       // encoder path is selected independently
        guard let c = whisper_init_from_file_with_params(model.path, cp) else { return nil }
        ctx = c
        self.dir = dir
        self.voices = voices
        vadPath = vad.flatMap { strdup($0.path) }
        autoLang = strdup("auto")
        for d in [dir, liveDir] {
            try? FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        publishStragglers()
    }

    static var defaultDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/transcripts")
    }

    /// A sibling of `defaultDir`, not a subdirectory of it: anything scanning the
    /// transcripts recursively must not find the one file that is still moving.
    static var defaultLiveDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/live")
    }

    /// Hand a finished segment over for transcription. Returns immediately.
    func submit(_ samples: [Float], source: String) {
        queue.async { [weak self] in self?.run(samples, source) }
    }

    /// Drain in-flight work, then release the model.
    func close() {
        queue.sync {}
        guard !closed else { return }
        closed = true
        whisper_free(ctx)
        try? handle?.close()
        handle = nil
        publish()                     // this meeting is over; it can be named now
        free(vadPath)
        free(autoLang)
    }

    // MARK: - transcription

    private func run(_ samples: [Float], _ source: String) {
        guard !closed, samples.count >= 4800 else { return }   // < 300 ms is not worth a pass

        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.print_realtime = false
        p.print_progress = false
        p.print_timestamps = false
        p.print_special = false
        p.no_context = true            // segments are independent; without this one bad
                                       // transcription poisons the rest of the day
        p.suppress_blank = true
        p.suppress_nst = true          // drop (music), [BLANK_AUDIO] and friends
        p.language = UnsafePointer(autoLang)
        p.detect_language = false
        p.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        if let v = vadPath {
            p.vad = true
            p.vad_model_path = UnsafePointer(v)
        }

        guard whisper_full(ctx, p, samples, Int32(samples.count)) == 0 else { return }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let lang = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))

        // "mic" is you — a fact no embedding can improve on. Only the system stream needs
        // identifying, and nothing here identifies it: the voiceprint is kept and the
        // question is answered at `publish`, from the whole meeting at once. Taking the
        // embedding after the empty-text guard means only audio whisper agreed was speech
        // ever reaches the clustering.
        var speaker = "me"
        var seg: Int?
        if source == "system" {
            speaker = "unknown"          // until this meeting is clustered
            if let print = voices?.embed(samples), let file = live {
                VoicePrintFile.append(print, to: VoicePrintFile.url(for: file))
                seg = segs
                segs += 1
            }
        }

        append(text, source: source, speaker: speaker, seg: seg,
               dur: Double(samples.count) / 16000, lang: lang)
    }

    // MARK: - storage

    private func append(_ text: String, source: String, speaker: String, seg: Int?,
                        dur: Double, lang: String) {
        // One file per meeting. Nothing runs while nobody is talking, so the gap between
        // this line and the last one *is* the silence measurement — no timer needed. A
        // session that spans midnight stays in one file, named for its first line.
        let now = Date()
        if handle == nil || now.timeIntervalSince(lastWrite) > gapSec {
            segs = 0
            try? handle?.close()
            publish()                  // the meeting that just ended
            let url = liveDir.appendingPathComponent(
                "\(Self.fileFmt.string(from: now)).jsonl")
            handle = Self.openFile(url)
            live = handle == nil ? nil : url
        }
        lastWrite = now                // before the guard below: a dropped line must not
                                       // strand the clock at the previous session
        let line = TranscriptLine(ts: Self.isoFmt.string(from: now), source: source,
                                  speaker: speaker, dur: (dur * 100).rounded() / 100,
                                  lang: lang, text: text, seg: seg, name: nil)
        guard let data = try? JSONEncoder().encode(line), let h = handle else { return }
        h.write(data)
        h.write(Data([0x0a]))
        try? h.synchronize()
    }

    /// Hand a finished transcript over to the readers. Nothing appends to it after this,
    /// which is exactly what makes naming — a whole-file rewrite — safe.
    private func publish() {
        guard let url = live else { return }
        live = nil
        Self.publish(url, to: dir, threshold: clusterThreshold, minSeconds: minSpeakerSec)
    }

    /// Work out who spoke, then hand the meeting over to the readers. In that order: the
    /// clustering rewrites the whole file, which is safe here and nowhere else, and a
    /// transcript must never appear in `dir` still saying `unknown` on every line.
    private static func publish(_ url: URL, to dir: URL,
                                threshold: Float, minSeconds: Double) {
        TranscriptSpeakers.assign(url, threshold: threshold, minSeconds: minSeconds)
        let fm = FileManager.default
        try? fm.moveItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
        // The voiceprints travel with the transcript: re-clustering it later is the point.
        let prints = VoicePrintFile.url(for: url)
        try? fm.moveItem(at: prints, to: dir.appendingPathComponent(prints.lastPathComponent))
    }

    /// Anything already in `liveDir` belongs to a process that is no longer running — a
    /// crash, or a quit that never reached `close`. It is finished by definition.
    ///
    /// ponytail: a name collision leaves the file where it is, and it is retried next
    /// launch. Stamps are second-resolution, so two would need the same second on two runs.
    private func publishStragglers() {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: liveDir, includingPropertiesForKeys: nil)) ?? []
        for url in all where url.pathExtension == "jsonl" {
            Self.publish(url, to: dir, threshold: clusterThreshold, minSeconds: minSpeakerSec)
        }
    }

    private static func openFile(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        return h
    }
}
