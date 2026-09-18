import AppKit
import FluidAudio
import SwiftUI

@main
struct SusurroApp: App {
    @State private var engine = Engine()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Toggle("Listening", isOn: Binding(
                get: { engine.enabled },
                set: { engine.setEnabled($0) }
            ))
            .keyboardShortcut("l")

            if engine.loading {
                Text("Loading model…").foregroundStyle(.secondary)
            }
            if !engine.modelsReady {
                Divider()
                if let status = engine.downloading {
                    Text(status).foregroundStyle(.secondary)
                } else {
                    Button("Download models (2.8 GB)…") { engine.downloadModels() }
                }
            }
            if let problem = engine.problem {
                Divider()
                Text(problem).foregroundStyle(.secondary)
            }

            Divider()
            Button("Open transcripts…") {
                NSWorkspace.shared.activateFileViewerSelecting([Transcriber.defaultDir])
            }
            Button("Name speakers…") {
                NSApp.activate(ignoringOtherApps: true)   // an LSUIElement app is never frontmost
                openWindow(id: "speakers")
            }

            Divider()
            Button("Quit Susurro") {
                engine.setEnabled(false)
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: engine.listening ? "waveform" : "waveform.slash")
        }

        Window("Transcripts", id: "speakers") { TranscriptsView() }
            .windowResizability(.contentSize)
    }
}

/// Which voice, in which meeting. The pair is the key everything below is addressed by:
/// naming `user-3` is naming them *here*, and the same id in another transcript is very
/// possibly somebody else.
private struct VoiceKey: Hashable {
    let transcript: URL, voice: String
}

/// Every transcript, and who the voices in each one turned out to be.
///
/// One reference type, read by all three views, is what keeps a rename visible. Handing a
/// detail view a value copy plus a refresh callback left it holding pre-rename state: the
/// roster kept saying `unnamed` and the field re-seeded itself blank off the stale copy.
/// Views carry a key — a URL, or a `VoiceKey` — and look the value up.
@Observable
final class Transcripts {
    private(set) var meetings: [TranscriptSnippets.Meeting] = []

    /// Transcripts accumulate while the window is closed, so this runs on every appearance.
    func reload() {
        TranscriptNames.adoptSidecars(in: Transcriber.defaultDir)   // one release's worth
        meetings = TranscriptSnippets.meetings()
    }

    func meeting(_ url: URL) -> TranscriptSnippets.Meeting? { meetings.first { $0.url == url } }

    func voice(_ label: String, in transcript: URL) -> TranscriptSnippets.Voice? {
        meeting(transcript)?.voices.first { $0.label == label }
    }

    func name(_ voice: String, in transcript: URL) -> String? {
        self.voice(voice, in: transcript)?.name
    }

    /// How a line's `speaker` should read on screen: the name if this meeting has one, the
    /// raw `user-N` otherwise.
    func display(_ voice: String, in transcript: URL) -> String {
        name(voice, in: transcript) ?? voice
    }

    func suggestions(for voice: String, in transcript: URL) -> [TranscriptSnippets.Suggestion] {
        TranscriptSnippets.suggestions(for: voice, excluding: transcript, in: meetings)
    }

    /// Writes the names onto the transcript's own lines — a whole-file rewrite, which is
    /// why the view calls this on commit and not on every keystroke.
    func rename(_ voices: [String: String], in transcript: URL) {
        guard !voices.isEmpty else { return }
        TranscriptNames.apply(voices, to: transcript)
        // Re-read the one file that changed, so the roster and the suggestions follow.
        guard let i = meetings.firstIndex(where: { $0.url == transcript }),
              let fresh = TranscriptSnippets.meetings(dir: transcript.deletingLastPathComponent())
                  .first(where: { $0.url.lastPathComponent == transcript.lastPathComponent })
        else { return }
        meetings[i] = fresh
    }
}

/// The roster: one row per meeting. Naming starts here rather than at a voice because the
/// meeting is what makes a `user-N` answerable — you remember who was in Tuesday's call.
struct TranscriptsView: View {
    @State private var transcripts = Transcripts()

    /// Driven explicitly rather than by `NavigationLink`s all the way down. A link inside a
    /// `List` row hands the *whole row* to navigation, which ate every click meant for the
    /// name field and the suggestions menu sitting in it.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if transcripts.meetings.isEmpty {
                    Text("No transcripts yet. Switch Listening on, and a file appears "
                         + "the first time somebody speaks.")
                        .foregroundStyle(.secondary)
                }
                ForEach(transcripts.meetings) { m in
                    NavigationLink(value: m.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.stamp)
                            Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationDestination(for: URL.self) {
                MeetingView(transcript: $0, transcripts: transcripts, path: $path)
            }
            .navigationDestination(for: VoiceKey.self) {
                VoiceView(key: $0, transcripts: transcripts)
            }
        }
        .frame(width: 460, height: 500)      // fixed, so pushing a view does not resize
        .onAppear(perform: transcripts.reload)
    }

    /// Unnamed first, because that is the reason to open the row.
    private func subtitle(_ m: TranscriptSnippets.Meeting) -> String {
        let unnamed = m.voices.filter { transcripts.name($0.label, in: m.url) == nil }.count
        let voices = "\(m.voices.count) voice\(m.voices.count == 1 ? "" : "s")"
        return unnamed == 0 ? "\(voices) · \(m.lines) lines"
                            : "\(unnamed) unnamed of \(voices) · \(m.lines) lines"
    }
}

/// One meeting: name every voice in it. The name lands in this transcript's sidecar and
/// nowhere else — the same `user-N` next week starts unnamed again, with whatever you
/// typed here offered as a suggestion.
private struct MeetingView: View {
    let transcript: URL
    let transcripts: Transcripts
    @Binding var path: NavigationPath

    /// What is being typed *right now*, by voice. Only that: the stored name is read
    /// straight off `transcripts`, and this holds nothing until a key is pressed.
    ///
    /// Seeding it on appear instead is what made every field render empty. `.onAppear`
    /// runs after the first layout, and the rows of a `List` did not pick the values up —
    /// they arrived on the next keystroke, which is the one redraw nobody had to wait for.
    /// Nothing in this view mutates state after a render any more.
    @State private var typed: [String: String] = [:]

    /// Voices edited since the last write. Saving a name rewrites the whole transcript, so
    /// it happens on Enter, on picking a suggestion, and on leaving — never per keystroke.
    @State private var dirty: Set<String> = []

    private var voices: [TranscriptSnippets.Voice] { transcripts.meeting(transcript)?.voices ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voices.isEmpty {
                Text("Only your own voice in this one — `me` needs no naming.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(voices) { row($0) }
                Text("Saved when you press Return or leave. Clearing a name removes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle(transcripts.meeting(transcript)?.stamp ?? "Transcript")
        // Catches the edit that is typed and then navigated away from, which is how a name
        // got silently dropped before there was anywhere to drop it from.
        .onDisappear(perform: commit)
    }

    private func row(_ v: TranscriptSnippets.Voice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(v.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 54, alignment: .trailing)
                TextField(v.label, text: binding(v.label), prompt: Text("unnamed"))
                    .textFieldStyle(.roundedBorder)   // or it reads as a label, not a field
                    .onSubmit(commit)
                suggestions(v.label)
                // The way down, as its own button: everything this voice said here, with
                // the turn either side.
                Button {
                    path.append(VoiceKey(transcript: transcript, voice: v.label))
                } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("What this voice said")
            }
            // The sample is the identification: the longest thing it said, because the
            // first thing is usually "yeah".
            HStack(alignment: .top, spacing: 6) {
                Text("\(v.lines)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Text(v.sample).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Names this voice went by in other meetings. Empty for a voice nobody has ever named,
    /// which is every voice until the first time somebody does — hence the disabled menu
    /// rather than a missing control that moves the layout around.
    private func suggestions(_ voice: String) -> some View {
        Menu {
            // Tallied here rather than cached in `@State`: the scan is a handful of
            // forty-byte files, and state filled in after a render is the bug above.
            let options = transcripts.suggestions(for: voice, in: transcript)
            if options.isEmpty {
                Text("No other meeting has named this voice")
            }
            ForEach(options) { s in
                Button("\(s.name) (\(s.count))") { set(voice, to: s.name); commit() }
            }
        } label: {
            Image(systemName: "person.crop.circle.badge.questionmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Named elsewhere — pick one")
    }

    private func set(_ voice: String, to name: String) {
        typed[voice] = name
        dirty.insert(voice)
    }

    /// Write every edited voice at once. Blank clears; see `TranscriptNames`.
    private func commit() {
        transcripts.rename(dirty.reduce(into: [:]) { $0[$1] = typed[$1] ?? "" },
                           in: transcript)
        dirty = []
    }

    /// Falls back to the stored name, so the very first render already shows it. The
    /// buffer wins once there is one, or a half-typed "Ana " would lose its space to the
    /// trim on the way to disk.
    private func binding(_ voice: String) -> Binding<String> {
        Binding(get: { typed[voice] ?? transcripts.name(voice, in: transcript) ?? "" },
                set: { set(voice, to: $0) })
    }
}

/// One voice in one meeting, in full and in order. Read as a conversation it identifies a
/// speaker far better than the line alone: `me` either side means this voice was answering
/// you, which places them faster than anything they said by themselves.
private struct VoiceView: View {
    let key: VoiceKey
    let transcripts: Transcripts

    @State private var snippets: [TranscriptSnippets.Snippet] = []
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snippets.isEmpty {
                Text("No lines for this voice.").foregroundStyle(.secondary)
                Spacer()
            } else {
                // By index: a snippet is a line of text, and the same sentence can honestly
                // turn up twice in one meeting.
                List(snippets.indices, id: \.self) { i in
                    // A Button, not an onTapGesture, so a row stays keyboard-reachable.
                    Button { toggle(i) } label: { row(i) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .navigationTitle(transcripts.display(key.voice, in: key.transcript))
        .onAppear { snippets = TranscriptSnippets.lines(for: key.voice, in: key.transcript) }
    }

    /// One line, collapsed to three lines of text; expanded, the turn either side of it as
    /// well — chronological, so the exchange reads top to bottom.
    private func row(_ i: Int) -> some View {
        let s = snippets[i]
        let open = expanded.contains(i)
        return VStack(alignment: .leading, spacing: 3) {
            if open, let before = s.before { turn(before) }

            HStack(alignment: .top, spacing: 6) {
                if open {
                    speakerTag(s.line.speaker)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: tagWidth, alignment: .trailing)
                }
                Text(s.line.text)
                    .lineLimit(open ? nil : 3)   // expanded shows the complete message
                Spacer(minLength: 0)
            }

            if open, let after = s.after { turn(after) }

            Text(s.ts.prefix(16).replacingOccurrences(of: "T", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, tagWidth + 6)
        }
        .contentShape(Rectangle())   // the gaps are part of the click target
    }

    /// A neighbouring turn: whose it was is the whole point.
    private func turn(_ t: TranscriptSnippets.Turn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            speakerTag(t.speaker)
            Text(t.text)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Fixed width, trailing-aligned, so the three turns line up as a column. Resolved
    /// through this meeting's sidecar: a neighbour you have named reads `Ana`, not `user-7`.
    private func speakerTag(_ who: String) -> some View {
        Text(transcripts.display(who, in: key.transcript))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: tagWidth, alignment: .trailing)
    }

    private var tagWidth: CGFloat { 54 }

    private func toggle(_ i: Int) {
        if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) }
    }
}

/// Owns the model and both capture graphs. Enabling loads, disabling frees.
///
/// Deliberately not persisted across launches: an always-on recorder that resumes
/// silently on login is worse than one you have to switch on.
@Observable
final class Engine {
    private(set) var enabled = false          // intent — flips as soon as you click
    private(set) var loading = false          // model is being loaded off the main thread
    private(set) var problem: String?
    private(set) var downloading: String?     // last line out of models.sh, nil when idle

    /// Stored rather than computed: `@Observable` only tracks stored properties, and the
    /// menu has to lose its Download item the moment the download finishes.
    private(set) var modelsReady = Engine.checkModels()

    static let modelsDir = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models")

    static func checkModels() -> Bool {
        FileManager.default.fileExists(
            atPath: modelsDir.appendingPathComponent(Config.load().model).path)
    }

    /// Actually capturing, as opposed to merely switched on and still loading.
    var listening: Bool { enabled && !loading }

    private var transcriber: Transcriber?
    private var mic: MicCapture?
    private var system: SystemCapture?
    private var generation = 0                // invalidates an in-flight load on toggle-off
    private var download: Process?            // held so it outlives this call

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    /// Runs the `models.sh` bundled in Resources — the same script `setup.sh` calls, so
    /// there is one fetch path and not two. It is idempotent and resumable, so a failed
    /// run is fixed by clicking again.
    ///
    /// The script's stdout is one short line per file and goes straight in the menu;
    /// curl's progress bar is on stderr and goes to a log, because \r-redrawing a
    /// progress bar into a menu item is not a thing.
    func downloadModels() {
        guard download == nil,
              let script = Bundle.main.path(forResource: "models", ofType: "sh")
        else { return }

        downloading = "starting…"
        let log = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models-download.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        p.standardError = try? FileHandle(forWritingTo: log)

        let out = Pipe()
        p.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { h in
            guard let text = String(data: h.availableData, encoding: .utf8),
                  let line = text.split(separator: "\n").last(where: { !$0.isEmpty })
            else { return }
            DispatchQueue.main.async { self.downloading = String(line) }
        }

        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.download = nil
                self.modelsReady = Engine.checkModels()
                // Exit status alone is not enough: the script can succeed while the
                // configured model is one it does not fetch.
                self.downloading = self.modelsReady && proc.terminationStatus == 0
                    ? nil : "download failed — see ~/.susurro/models-download.log"
            }
        }

        do {
            try p.run()
            download = p
        } catch {
            downloading = "could not start: \(error.localizedDescription)"
        }
    }

    private func start() {
        guard !enabled else { return }
        problem = nil

        let cfg = Config.load()
        let models = Self.modelsDir
        let model = models.appendingPathComponent(cfg.model)
        guard FileManager.default.fileExists(atPath: model.path) else {
            problem = "Missing model: \(cfg.model) — use Download models"
            return
        }
        let vad = models.appendingPathComponent("ggml-silero-v5.1.2.bin")
        let vadURL = FileManager.default.fileExists(atPath: vad.path) ? vad : nil

        enabled = true
        loading = true
        generation += 1
        let gen = generation

        // Off the main thread: the first ever load compiles the Core ML encoder for the
        // ANE, measured at ~36 s here. macOS caches the result, so later loads are <1 s —
        // but that first one would freeze the menu bar solid.
        DispatchQueue.global(qos: .userInitiated).async {
            // Missing speaker models must not cost you the transcript: without them every
            // system line is simply labelled "unknown".
            let voices = VoicePrints(models: models)
            let t = Transcriber(model: model, vad: vadURL, voices: voices,
                                gapSec: cfg.sessionGapMin * 60,
                                clusterThreshold: cfg.clusterThreshold,
                                minSpeakerSec: cfg.minSpeakerSec)
            DispatchQueue.main.async {
                guard gen == self.generation, self.enabled else {
                    t?.close()                // toggled off mid-load; discard it
                    return
                }
                guard let t else {
                    self.problem = "Could not load \(cfg.model)"
                    self.enabled = false
                    self.loading = false
                    return
                }
                self.transcriber = t

                // Two segmenters, one per source: that split is the speaker attribution.
                let m = MicCapture(seg: Segmenter(config: cfg) { [weak t] s in
                    t?.submit(s, source: "mic")
                })
                let s = SystemCapture(seg: Segmenter(config: cfg) { [weak t] s in
                    t?.submit(s, source: "system")
                })

                // One source failing must not take the other down.
                var failures: [String] = []
                if voices == nil { failures.append("speaker models missing — use Download models") }
                do { try m.start() } catch {
                    failures.append("mic: \(error.localizedDescription)")
                }
                do { try s.start() } catch {
                    failures.append("system: \(error.localizedDescription)")
                }

                self.mic = m
                self.system = s
                self.loading = false
                if !failures.isEmpty { self.problem = failures.joined(separator: " · ") }
            }
        }
    }

    private func stop() {
        guard enabled else { return }
        generation += 1               // any in-flight load will now discard itself
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        transcriber?.close()          // drains in-flight segments before freeing
        transcriber = nil
        enabled = false
        loading = false
    }
}
