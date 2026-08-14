// Run with `make smoke`. Built like the app (-parse-as-library) but with its own @main,
// linking Capture.swift + Transcriber.swift instead of SusurroApp.swift.
import FluidAudio
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

        func transcripts() -> [URL] {
            let all = try? FileManager.default.contentsOfDirectory(
                at: out, includingPropertiesForKeys: nil)
            return (all ?? []).filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        // Three submits seconds apart are one meeting, hence one file.
        check(transcripts().count == 1,
              "one transcript file for one session (got \(transcripts().count))")
        guard let written = try? String(contentsOf: transcripts()[0], encoding: .utf8) else {
            print("  FAIL  no JSONL written to \(out.path)"); exit(1)
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

            // MARK: drift — does `drift` actually reach the clustering
            //
            // Every match under `drift` EMA-blends the segment into the stored voiceprint.
            // Left at FluidAudio's 0.45 the centroid walks toward whoever spoke last until
            // it is the average voice in the room and matches everybody — which is how the
            // real gallery ended up with two entries for months. That collapse needs
            // hundreds of genuinely different voices to reproduce, so what is checked here
            // is the knob itself: at 0 no match may touch the voiceprint, at 1 every match
            // must. Get the parameter wrong and one of the two fails.
            func moveAfterMatch(drift: Float, _ name: String) -> [Float] {
                let url = out.appendingPathComponent("drift-\(name).json")
                guard let a = SpeakerBook(models: models, threshold: 0.65, drift: drift, url: url)
                else { print("  FAIL  could not open \(name) gallery"); exit(1) }
                _ = a.label(pcm)                     // enrols user-1
                a.close()
                let enrolled = SpeakerNames.load(from: url)[0].currentEmbedding
                guard let b = SpeakerBook(models: models, threshold: 0.65, drift: drift, url: url)
                else { print("  FAIL  could not reopen \(name) gallery"); exit(1) }
                _ = b.label(tail)                    // a confident match of the same voice
                b.close()
                let after = SpeakerNames.load(from: url)[0].currentEmbedding
                check(enrolled.count == 256 && after.count == 256, "\(name) voiceprint is 256-d")
                return zip(enrolled, after).map { $1 - $0 }
            }
            check(moveAfterMatch(drift: 0, "frozen").allSatisfy { $0 == 0 },
                  "drift 0: a match leaves the stored voiceprint untouched")
            check(moveAfterMatch(drift: 1, "loose").contains { $0 != 0 },
                  "drift 1: a match does move it — the knob is wired to the clustering")

            // MARK: naming — what the window does, minus the window
            SpeakerNames.save(["1": "Ana", "2": "  "], to: gallery)
            let renamed = SpeakerNames.load(from: gallery)
            check(renamed.first { $0.id == "1" }?.name == "Ana", "rename by id landed")
            check(renamed.first { $0.id == "2" }?.isNamed == false, "a blank field renames nobody")
            check(renamed.allSatisfy { $0.currentEmbedding.count == 256 },
                  "renaming kept every voiceprint")

            guard let named = SpeakerBook(models: models, threshold: 0.65, url: gallery)
            else { print("  FAIL  could not reopen renamed gallery"); exit(1) }
            check(named.label(tail)?.name == "Ana", "the typed name is what the transcript records")

            // Renamed behind a live book's back, then flushed: the rename has to win.
            SpeakerNames.save(["2": "Bruno"], to: gallery)
            named.close()
            check(SpeakerNames.load(from: gallery).first { $0.id == "2" }?.name == "Bruno",
                  "a flush of drifted centroids does not revert a rename")
        }

        // A gap longer than `gapSec` starts a new file. gapSec: 0 makes any elapsed time
        // count as a gap; the sleep is only so the name lands in a different second.
        sleep(1)
        guard let t2 = Transcriber(model: model, vad: nil, gapSec: 0, dir: out) else {
            print("  FAIL  reopen for gap check"); exit(1)
        }
        t2.submit(pcm, source: "mic")
        t2.close()
        check(transcripts().count == 2,
              "a silence gap starts a second file (got \(transcripts().count))")

        try? FileManager.default.removeItem(at: out)
        print("all checks passed")
    }
}
