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

    // whisper stores these as `const char *` without copying, so they must outlive
    // every whisper_full call — hence strdup rather than a Swift String.
    private let vadPath: UnsafeMutablePointer<CChar>?
    private let autoLang: UnsafeMutablePointer<CChar>

    private var handle: FileHandle?
    private var handleDay = ""
    private var closed = false

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current          // local offset, not Z — matches the day file
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init?(model: URL, vad: URL?, dir: URL = Transcriber.defaultDir) {
        var cp = whisper_context_default_params()
        cp.use_gpu = true              // Metal is off at build time; the Core ML
                                       // encoder path is selected independently
        guard let c = whisper_init_from_file_with_params(model.path, cp) else { return nil }
        ctx = c
        self.dir = dir
        vadPath = vad.flatMap { strdup($0.path) }
        autoLang = strdup("auto")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    static var defaultDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/transcripts")
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
        append(text, source: source, dur: Double(samples.count) / 16000, lang: lang)
    }

    // MARK: - storage

    private struct Line: Encodable {
        let ts: String, source: String, dur: Double, lang: String, text: String
    }

    private func append(_ text: String, source: String, dur: Double, lang: String) {
        let now = Date()
        let day = Self.dayFmt.string(from: now)
        if day != handleDay || handle == nil {
            try? handle?.close()
            handle = Self.openDay(day, in: dir)
            handleDay = day
        }
        let line = Line(ts: Self.isoFmt.string(from: now), source: source,
                        dur: (dur * 100).rounded() / 100, lang: lang, text: text)
        guard let data = try? JSONEncoder().encode(line), let h = handle else { return }
        h.write(data)
        h.write(Data([0x0a]))
        try? h.synchronize()
    }

    private static func openDay(_ day: String, in dir: URL) -> FileHandle? {
        let url = dir.appendingPathComponent("\(day).jsonl")
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
