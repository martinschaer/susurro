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

    /// Lines actually written to the current file — the next one's index, which is how the
    /// live window addresses a line when it names it. Counted on write, not on attempt: a
    /// line that never reached the file must not shift every index after it.
    private var written = 0

    /// This meeting's voices so far, for the live window. Reset with the file.
    private var liveVoices: LiveVoices

    /// Names picked in the live window for the file still being written, by line index.
    /// Applied at `publish`, after the clustering and before the move, so a transcript never
    /// reaches `dir` without them.
    private var picks: [URL: [Int: NamePick]] = [:]

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

    /// Every line as it is written, with the epoch its audio was captured in, on the
    /// whisper queue. The live window. Set before the first `submit`.
    var onLine: ((Written, Int) -> Void)?

    /// A line as it landed: where, and which live voice it sounded like. `voice` is `me`,
    /// `voice N`, or `unknown` when there was no voiceprint — never an `sN`, which only
    /// exists once the meeting is clustered.
    struct Written {
        let line: TranscriptLine
        let file: URL
        let index: Int
        let voice: String
    }

    /// What the segment still being spoken says so far, by source, on the whisper queue.
    /// Display only: never written, never embedded. Empty text means "no preview any
    /// more" — sent when a segment ends without a line, so a stale one does not linger.
    var onPreview: ((_ source: String, _ text: String, _ epoch: Int) -> Void)?

    /// Previews are the first thing to give way. `queued` counts finals not yet run, and a
    /// preview is skipped while there are any: it must never delay a line, nor the file.
    /// `latest` holds only the newest buffer per source, so a backlog cannot form.
    private let lock = NSLock()
    private var queued = 0
    private var latest: [String: ([Float], Int)] = [:]
    private var previewing = false

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
        liveVoices = LiveVoices(threshold: clusterThreshold)
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
    func submit(_ samples: [Float], source: String, epoch: Int = 0) {
        lock.withLock { queued += 1 }
        queue.async { [weak self] in
            self?.run(samples, source, epoch)
            self?.lock.withLock { self?.queued -= 1 }
        }
    }

    /// Names from the live window for `file`, replacing any sent before. Ordered against
    /// `publish` by the queue: still live, they wait for it; already published (a silence
    /// gap rotated it, or Listening went off), they are voted onto the published copy.
    func setNames(_ names: [Int: NamePick], for file: URL) {
        queue.async { [self] in
            if file == live {
                picks[file] = names
            } else {
                TranscriptNames.vote(names, in: dir.appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    /// End this meeting now: lines already queued land in it, the next one starts a new
    /// file. `then` runs on the queue once it is published.
    func rotate(then: @escaping () -> Void) {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
            publish()
            then()
        }
    }

    /// Switch previews on only while someone is looking: each one is a whisper pass.
    func setPreviews(_ on: Bool) {
        lock.withLock {
            previewing = on
            if !on { latest = [:] }
        }
    }

    /// The in-progress segment, for `onPreview`. Returns immediately; dropped when off,
    /// and replaced if a newer one for the same source arrives before it runs.
    func preview(_ samples: [Float], source: String, epoch: Int) {
        let schedule: Bool = lock.withLock {
            guard previewing else { return false }
            let idle = latest.isEmpty
            latest[source] = (samples, epoch)
            return idle
        }
        if schedule { queue.async { [weak self] in self?.runPreviews() } }
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

    private func runPreviews() {
        guard !closed else { return }      // the context is already freed
        let jobs: [String: ([Float], Int)] = lock.withLock {
            defer { latest = [:] }
            return queued > 0 ? [:] : latest
        }
        for (source, (samples, epoch)) in jobs {
            guard let (text, _) = transcribe(samples) else { continue }
            onPreview?(source, text, epoch)
        }
    }

    private func run(_ samples: [Float], _ source: String, _ epoch: Int) {
        guard !closed else { return }
        // Whatever happens below, this segment's preview is finished: either a line
        // replaces it, or nothing does and it must be cleared.
        guard let (text, lang) = transcribe(samples) else {
            onPreview?(source, "", epoch)
            return
        }

        // "mic" is you — a fact no embedding can improve on. Only the system stream needs
        // identifying, and nothing here identifies it: the voiceprint is kept and the
        // question is answered at `publish`, from the whole meeting at once. Taking the
        // embedding after the empty-text guard means only audio whisper agreed was speech
        // ever reaches the clustering.
        var speaker = "me"
        var seg: Int?
        var print: [Float]?
        if source == "system" {
            speaker = "unknown"          // until this meeting is clustered
            print = voices?.embed(samples)
        }

        // Opens the file first if this line starts a meeting, so the voiceprint below goes
        // in the new meeting's `.emb` and the live voices start from nothing.
        rotateIfIdle()
        if let print, let file = live {
            VoicePrintFile.append(print, to: VoicePrintFile.url(for: file))
            seg = segs
            segs += 1
        }

        let line = append(text, source: source, speaker: speaker, seg: seg,
                          dur: Double(samples.count) / 16000, lang: lang)
        guard let line, let file = live else {
            onPreview?(source, "", epoch)
            return
        }
        let voice = print.map { "voice \(liveVoices.assign($0) + 1)" } ?? speaker
        onLine?(Written(line: line, file: file, index: written - 1, voice: voice), epoch)
    }

    /// One whisper pass: the text and its language, or nil for nothing worth a line.
    /// Shared by lines and previews — on `queue` only, the context is not reentrant.
    private func transcribe(_ samples: [Float]) -> (String, String)? {
        guard samples.count >= 4800 else { return nil }   // < 300 ms is not worth a pass

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

        guard whisper_full(ctx, p, samples, Int32(samples.count)) == 0 else { return nil }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, String(cString: whisper_lang_str(whisper_full_lang_id(ctx))))
    }

    // MARK: - storage

    /// One file per meeting. Nothing runs while nobody is talking, so the gap between this
    /// line and the last one *is* the silence measurement — no timer needed. A session that
    /// spans midnight stays in one file, named for its first line.
    private func rotateIfIdle() {
        let now = Date()
        if handle == nil || now.timeIntervalSince(lastWrite) > gapSec {
            segs = 0
            written = 0
            liveVoices = LiveVoices(threshold: clusterThreshold)
            try? handle?.close()
            publish()                  // the meeting that just ended
            let url = liveDir.appendingPathComponent(
                "\(Self.fileFmt.string(from: now)).jsonl")
            handle = Self.openFile(url)
            live = handle == nil ? nil : url
        }
        lastWrite = now                // even if the line is then dropped: it must not
                                       // strand the clock at the previous session
    }

    /// The line, or nil if it never reached the file.
    private func append(_ text: String, source: String, speaker: String, seg: Int?,
                        dur: Double, lang: String) -> TranscriptLine? {
        let line = TranscriptLine(ts: Self.isoFmt.string(from: lastWrite), source: source,
                                  speaker: speaker, dur: (dur * 100).rounded() / 100,
                                  lang: lang, text: text, seg: seg, name: nil)
        guard let data = try? JSONEncoder().encode(line), let h = handle else { return nil }
        h.write(data)
        h.write(Data([0x0a]))
        try? h.synchronize()
        written += 1
        return line
    }

    /// Hand a finished transcript over to the readers. Nothing appends to it after this,
    /// which is exactly what makes naming — a whole-file rewrite — safe.
    private func publish() {
        guard let url = live else { return }
        live = nil
        Self.publish(url, to: dir, threshold: clusterThreshold, minSeconds: minSpeakerSec,
                     picks: picks.removeValue(forKey: url) ?? [:])
    }

    /// Work out who spoke, then hand the meeting over to the readers. In that order: the
    /// clustering rewrites the whole file, which is safe here and nowhere else, and a
    /// transcript must never appear in `dir` still saying `unknown` on every line.
    private static func publish(_ url: URL, to dir: URL,
                                threshold: Float, minSeconds: Double,
                                picks: [Int: NamePick] = [:]) {
        TranscriptSpeakers.assign(url, threshold: threshold, minSeconds: minSeconds)
        TranscriptNames.vote(picks, in: url)      // onto the clusters just assigned
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
