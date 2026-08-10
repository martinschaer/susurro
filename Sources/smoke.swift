// Run with `make smoke`. Built like the app (-parse-as-library) but with its own @main,
// linking Capture.swift + Transcriber.swift instead of SusurroApp.swift.
import Foundation

private func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
    if !ok { exit(1) }
}

private func tone(_ seconds: Double, amp: Float = 0.3) -> [Float] {
    (0..<Int(seconds * 16000)).map { amp * sin(Float($0) * 0.1) }
}

private func quiet(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * 16000))
}

@main
enum Smoke {
    static func main() throws {
        // MARK: Segmenter — tone / silence / tone / silence -> exactly 2 utterances
        var segments: [[Float]] = []
        let seg = Segmenter(config: Config()) { segments.append($0) }
        seg.push(tone(1.0))
        seg.push(quiet(1.0))
        seg.push(tone(1.0))
        seg.push(quiet(1.0))
        check(segments.count == 2, "segmenter cut 2 utterances (got \(segments.count))")
        check(segments.allSatisfy { $0.count > 16000 }, "each segment carries >1s of audio")

        // A stream that never crosses the gate must produce nothing.
        var none: [[Float]] = []
        let quietSeg = Segmenter(config: Config()) { none.append($0) }
        quietSeg.push(quiet(3.0))
        check(none.isEmpty, "silence produces no segments")

        // MARK: Transcriber — jfk.wav all the way to JSONL on disk
        let model = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models/ggml-tiny.bin")
        guard FileManager.default.fileExists(atPath: model.path) else {
            print("  SKIP  transcriber (no ggml-tiny.bin — run ./setup.sh)")
            print("segmenter checks passed")
            return
        }

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("susurro-smoke-\(getpid())")
        guard let t = Transcriber(model: model, vad: nil, dir: out) else {
            print("  FAIL  model load"); exit(1)
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: "vendor/whisper.cpp/samples/jfk.wav"))
        let pcm = wav.dropFirst(44).withUnsafeBytes { raw -> [Float] in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
        check(pcm.count > 16000, "read \(pcm.count) samples from jfk.wav")

        t.submit(pcm, source: "mic")
        t.close()                                   // drains the queue

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        let jsonl = out.appendingPathComponent("\(day.string(from: Date())).jsonl")
        guard let written = try? String(contentsOf: jsonl, encoding: .utf8),
              let line = written.split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any]
        else { print("  FAIL  no JSONL written to \(jsonl.path)"); exit(1) }

        check((obj["text"] as? String)?.lowercased().contains("country") == true,
              "transcript contains 'country' — got \(obj["text"] ?? "nil")")
        check(obj["source"] as? String == "mic", "source recorded as mic")
        check(obj["dur"] as? Double != nil, "duration recorded")
        check(obj["ts"] as? String != nil, "timestamp recorded")

        try? FileManager.default.removeItem(at: out)
        print("all checks passed")
    }
}
