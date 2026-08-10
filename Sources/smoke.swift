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
        let gallery = out.appendingPathComponent("speakers.json")
        let models = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models")

        // No speaker models is a skip, not a failure — the app degrades the same way,
        // labelling every system line "unknown" rather than losing the transcript.
        let book = SpeakerBook(models: models, threshold: 0.65, url: gallery)
        if book == nil { print("  SKIP  speaker labels (no speaker models — run ./setup.sh)") }

        guard let t = Transcriber(model: model, vad: nil, speakers: book, dir: out) else {
            print("  FAIL  model load"); exit(1)
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: "vendor/whisper.cpp/samples/jfk.wav"))
        let pcm = wav.dropFirst(44).withUnsafeBytes { raw -> [Float] in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
        check(pcm.count > 16000, "read \(pcm.count) samples from jfk.wav")

        // Same audio down both streams: "mic" is you by definition, "system" has to be
        // identified. Twice, because matching an existing speaker is a different branch
        // from minting one.
        t.submit(pcm, source: "mic")
        t.submit(pcm, source: "system")
        t.submit(pcm, source: "system")
        t.close()                                   // drains the queue, flushes the gallery

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        let jsonl = out.appendingPathComponent("\(day.string(from: Date())).jsonl")
        guard let written = try? String(contentsOf: jsonl, encoding: .utf8) else {
            print("  FAIL  no JSONL written to \(jsonl.path)"); exit(1)
        }
        let lines = written.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        check(lines.count == 3, "three lines written (got \(lines.count))")
        let obj = lines[0]

        check((obj["text"] as? String)?.lowercased().contains("country") == true,
              "transcript contains 'country' — got \(obj["text"] ?? "nil")")
        check(obj["source"] as? String == "mic", "source recorded as mic")
        check(obj["dur"] as? Double != nil, "duration recorded")
        check(obj["ts"] as? String != nil, "timestamp recorded")

        check(obj["speaker"] as? String == "me", "mic line is 'me'")
        // .infinity here would have thrown inside JSONEncoder and dropped the whole line.
        check(obj["dist"] == nil, "mic line carries no distance")

        let expected = book == nil ? "unknown" : "user-1"
        check(lines[1]["speaker"] as? String == expected,
              "first system line is \(expected) (got \(lines[1]["speaker"] ?? "nil"))")
        check(lines[2]["speaker"] as? String == expected,
              "same voice matched again, not re-enrolled (got \(lines[2]["speaker"] ?? "nil"))")

        if book != nil {
            check(lines[1]["dist"] == nil, "a new speaker records no distance")
            guard let d = lines[2]["dist"] as? Double else {
                print("  FAIL  matched line records no distance"); exit(1)
            }
            check(d < 0.3, "self-distance is a confident match (got \(d))")

            // The whole point of the gallery: identity outlives the process.
            guard let reopened = SpeakerBook(models: models, threshold: 0.65, url: gallery)
            else { print("  FAIL  could not reopen gallery"); exit(1) }
            let tail = Array(pcm[(pcm.count / 2)...])
            check(reopened.label(tail)?.name == "user-1",
                  "reloaded gallery still matches a later slice of the same voice")

            // Catches the one failure every check above would survive: an embedder
            // returning a constant vector, collapsing everyone into user-1. Dropping
            // every 6th sample raises rate and pitch ~1.2x, which moves the formants.
            var pitched: [Float] = []
            for (i, v) in pcm.enumerated() where i % 6 != 0 { pitched.append(v) }
            check(reopened.label(pitched)?.name == "user-2",
                  "a different voice becomes a different speaker")
        }

        try? FileManager.default.removeItem(at: out)
        print("all checks passed")
    }
}
