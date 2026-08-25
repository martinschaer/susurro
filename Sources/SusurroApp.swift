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

        Window("Speaker names", id: "speakers") { SpeakerNamesView() }
            .windowResizability(.contentSize)
    }
}

/// Put a name on a voice. `user-3` in the transcripts is a FluidAudio id and only a human
/// knows it is Ana; from the rename on, every later line says Ana. Older lines keep the id
/// — the transcripts are append-only.
///
/// One reference type, read by both views, is what keeps a rename visible. Handing the
/// detail view a `Speaker` and a refresh callback instead left it holding a value copy from
/// before the rename: the roster kept saying `unnamed` and the field re-seeded itself blank
/// off the stale copy. Views now carry the id — immutable — and look the voice up.
@Observable
final class Gallery {
    private(set) var speakers: [Speaker] = []

    /// The gallery grows while the window is closed, so this is called on every appearance.
    func reload() { speakers = SpeakerNames.load() }

    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    func rename(_ id: String, to name: String) {
        SpeakerNames.save([id: name])     // read-modify-write; a blank renames nobody
        reload()
    }
}

/// The roster: every voice, read-only. A row is a `user-N` and nothing else identifying, so
/// the naming happens one voice at a time in `SpeakerDetailView`, next to what it said.
struct SpeakerNamesView: View {
    @State private var gallery = Gallery()

    var body: some View {
        NavigationStack {
            List {
                if gallery.speakers.isEmpty {
                    Text("No voices yet. The system stream enrols one the first time "
                         + "somebody who is not you speaks.")
                        .foregroundStyle(.secondary)
                }
                ForEach(gallery.speakers) { s in
                    NavigationLink(value: s.id) {
                        HStack {
                            Text("user-\(s.id)")
                            Spacer()
                            Text(s.isNamed ? s.name : "unnamed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                SpeakerDetailView(id: id, gallery: gallery)
            }
        }
        .frame(width: 420, height: 460)      // fixed, so pushing a view does not resize
        .onAppear(perform: gallery.reload)
    }
}

/// One voice, with enough of what it said to recognise it.
private struct SpeakerDetailView: View {
    let id: String
    let gallery: Gallery

    @State private var typed = ""
    @State private var snippets: [TranscriptSnippets.Snippet] = []
    @State private var expanded: Set<Int> = []

    private var speaker: Speaker? { gallery.speaker(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("user-\(id)", text: $typed, prompt: Text("unnamed"))
                Button("Save") { gallery.rename(id, to: typed) }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                Text("What this voice said").font(.headline)
                Spacer()
                Button("Another 10") { shuffle() }
            }

            if snippets.isEmpty {
                Text("No transcript lines for this voice yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                // By index: a snippet is a line of text, and the same sentence can honestly
                // turn up twice in one sample.
                List(snippets.indices, id: \.self) { i in
                    // A Button, not an onTapGesture, so a row stays keyboard-reachable.
                    Button { toggle(i) } label: { row(i) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .navigationTitle(speaker.map { $0.isNamed ? $0.name : "user-\(id)" } ?? "user-\(id)")
        .onAppear {
            typed = speaker.flatMap { $0.isNamed ? $0.name : nil } ?? ""
            shuffle()
        }
    }

    /// One sampled line, collapsed to three lines of text; expanded, the turn either side
    /// of it as well — chronological, so the exchange reads top to bottom.
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

    /// A neighbouring turn: whose it was is the whole point — `me` either side means this
    /// voice was answering you.
    private func turn(_ t: TranscriptSnippets.Turn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            speakerTag(t.speaker)
            Text(t.text)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Fixed width, trailing-aligned, so the three turns line up as a column.
    private func speakerTag(_ who: String) -> some View {
        Text(who)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: tagWidth, alignment: .trailing)
    }

    private var tagWidth: CGFloat { 54 }

    private func toggle(_ i: Int) {
        if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) }
    }

    private func shuffle() {
        expanded = []                // indices would otherwise point at the previous sample
        snippets = speaker.map { TranscriptSnippets.random(for: $0) } ?? []
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

    /// Actually capturing, as opposed to merely switched on and still loading.
    var listening: Bool { enabled && !loading }

    private var transcriber: Transcriber?
    private var mic: MicCapture?
    private var system: SystemCapture?
    private var generation = 0                // invalidates an in-flight load on toggle-off

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    private func start() {
        guard !enabled else { return }
        problem = nil

        let cfg = Config.load()
        let models = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models")
        let model = models.appendingPathComponent(cfg.model)
        guard FileManager.default.fileExists(atPath: model.path) else {
            problem = "Missing model: \(cfg.model) — run ./setup.sh"
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
            let book = SpeakerBook(models: models, threshold: cfg.speakerThreshold,
                                   drift: cfg.embeddingThreshold)
            let t = Transcriber(model: model, vad: vadURL, speakers: book,
                                gapSec: cfg.sessionGapMin * 60)
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
                if book == nil { failures.append("speaker models missing — run ./setup.sh") }
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
