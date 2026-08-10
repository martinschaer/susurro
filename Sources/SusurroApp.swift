import AppKit
import SwiftUI

@main
struct SusurroApp: App {
    @State private var engine = Engine()

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

            Divider()
            Button("Quit Susurro") {
                engine.setEnabled(false)
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: engine.listening ? "waveform" : "waveform.slash")
        }
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
            let book = SpeakerBook(models: models, threshold: cfg.speakerThreshold)
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
