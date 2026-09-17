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

        // MARK: transcripts — what the naming window reads, minus the window
        //
        // No models needed, so this runs even on a bare checkout. Its own directory: the
        // gap check at the bottom counts files in `out`.
        let snips = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("susurro-snips-\(getpid())")
        try FileManager.default.createDirectory(at: snips, withIntermediateDirectories: true)
        let a = snips.appendingPathComponent("2026-01-01_09-00-00.jsonl")
        let b = snips.appendingPathComponent("2026-01-02_14-30-00.jsonl")

        // An exchange, because the context either side is the point. Last line truncated,
        // as a file the engine is still appending to would be.
        try """
        {"ts":"2026-01-01T09:00:00+01:00","source":"mic","speaker":"me","text":"so what do you think"}
        {"ts":"2026-01-01T09:01:00+01:00","source":"system","speaker":"user-1","text":"the short one"}
        {"ts":"2026-01-01T09:02:00+01:00","source":"system","speaker":"user-1","text":"the longest thing this voice said, which is the one worth showing"}
        {"ts":"2026-01-01T09:03:00+01:00","source":"system","speaker":"user-2","text":"somebody else"}
        not json at all
        {"ts":"2026-01-01T09:05:00+01:00","source":"system","speaker":"user-1","text":"after the gap"}
        {"ts":"2026-01-01T09:06:00+01:00","source":"system","speaker":"user-1","tex
        """.write(to: a, atomically: true, encoding: .utf8)
        // A second meeting, one line long: a neighbour must never cross a file.
        try """
        {"ts":"2026-01-02T14:30:00+01:00","source":"system","speaker":"user-1","text":"alone in its file"}
        """.write(to: b, atomically: true, encoding: .utf8)

        // MARK: the roster — one row per meeting, newest first
        let meetings = TranscriptSnippets.meetings(dir: snips)
        check(meetings.map { $0.url.lastPathComponent }
                == [b, a].map { $0.lastPathComponent },
              "meetings come back newest first "
              + "(got \(meetings.map { $0.url.lastPathComponent }))")
        check(meetings[0].stamp == "2026-01-02 14:30",
              "the file name reads as a date and a time (got \(meetings[0].stamp))")
        check(meetings[1].lines == 5,
              "only decodable lines are counted (got \(meetings[1].lines))")

        let voices = meetings[1].voices
        check(voices.map(\.label) == ["user-1", "user-2"],
              "every voice in the meeting, and `me` is not one of them "
              + "(got \(voices.map(\.label)))")
        check(voices[0].lines == 3, "lines per voice (got \(voices[0].lines))")
        check(voices[0].sample.hasPrefix("the longest thing"),
              "the sample is the longest line, not the first (got \(voices[0].sample))")

        // MARK: one voice in one meeting — in order, with the turn either side
        let said = TranscriptSnippets.lines(for: "user-1", in: a)
        check(said.map(\.line.text)
                == ["the short one", "the longest thing this voice said, which is the one "
                    + "worth showing", "after the gap"],
              "every line this voice spoke here, in order (got \(said.map(\.line.text)))")
        check(said[0].before?.speaker == "me" && said[0].before?.text == "so what do you think",
              "the previous turn comes back with whose it was (got \(said[0].before as Any))")
        check(said[0].after?.text.hasPrefix("the longest thing") == true,
              "the next turn comes back too (got \(said[0].after as Any))")

        // An undecodable line mid-file must not shift the lines after it. `compactMap`
        // instead of `map` would drop it, close the gap, and quote "somebody else" — the
        // wrong person — as what came before this one. Both sides are unreadable here.
        check(said[2].before == nil && said[2].after == nil,
              "an unreadable neighbour is no context, not the next one along "
              + "(got \(said[2].before as Any) / \(said[2].after as Any))")

        // First and last line of its file: no context, and the truncated tail of the *other*
        // file must not leak in as a neighbour.
        let lone = TranscriptSnippets.lines(for: "user-1", in: b)
        check(lone.count == 1 && lone[0].before == nil && lone[0].after == nil,
              "a file-boundary line has no neighbours rather than the wrong ones")

        // MARK: naming — the whole point: a name belongs to one transcript
        //
        // The same `user-1` is Ana on Thursday and Bruno on Friday, because a `user-N` is a
        // voiceprint cluster and clusters merge people. This is the check that fails if a
        // name ever leaks back across transcripts.
        TranscriptNames.apply(["user-1": "Ana", "user-2": "  "], to: a)
        TranscriptNames.apply(["user-1": "Bruno"], to: b)
        check(TranscriptNames.load(for: a)["user-1"] == "Ana"
                && TranscriptNames.load(for: b)["user-1"] == "Bruno",
              "the same voice is named per transcript, not once for all of them")
        check(TranscriptNames.load(for: a)["user-2"] == nil, "a blank field names nobody")

        // The whole reason the name is in the file: whatever reads the transcript next
        // gets it without being told where else to look.
        let namedBody = try String(contentsOf: a, encoding: .utf8)
        check(namedBody.contains("\"name\":\"Ana\""),
              "the name is on the transcript line itself")
        check(namedBody.contains("not json at all")
                && namedBody.hasSuffix("\"user-1\",\"tex"),
              "a rewrite returns the lines it cannot read byte for byte")
        check(TranscriptSnippets.decode(a).compactMap { $0 }.count == 5,
              "and loses none of the ones it can")

        // Clearing is the correction path, and the only way to take a wrong name back.
        TranscriptNames.apply(["user-2": "Cleo"], to: a)
        TranscriptNames.apply(["user-2": ""], to: a)
        check(TranscriptNames.load(for: a) == ["user-1": "Ana"],
              "a cleared name is removed and its neighbour left alone "
              + "(got \(TranscriptNames.load(for: a)))")

        // MARK: suggestions — the record of speakers, which is what makes a `user-N` guessable
        let c = snips.appendingPathComponent("2026-01-03_09-00-00.jsonl")
        try """
        {"ts":"2026-01-03T09:00:00+01:00","source":"system","speaker":"user-1","text":"a third meeting"}
        """.write(to: c, atomically: true, encoding: .utf8)
        TranscriptNames.apply(["user-1": "Ana"], to: c)

        let named = TranscriptSnippets.meetings(dir: snips)
        check(named.first { $0.url.lastPathComponent == a.lastPathComponent }?
                .voices.first?.name == "Ana",
              "the roster reads the name back off the transcript")

        let hints = TranscriptSnippets.suggestions(for: "user-1", in: named)
        check(hints == [.init(name: "Ana", count: 2), .init(name: "Bruno", count: 1)],
              "names this voice went by elsewhere, most-used first (got \(hints))")
        check(TranscriptSnippets.suggestions(for: "user-1", excluding: c, in: named)
                == [.init(name: "Ana", count: 1), .init(name: "Bruno", count: 1)],
              "the transcript being named does not vote for itself, and a tie is "
              + "alphabetical")
        check(TranscriptSnippets.suggestions(for: "user-9", in: named).isEmpty,
              "a voice nobody has ever named suggests nothing")

        // MARK: the old sidecars are folded in, not stripped
        let d = snips.appendingPathComponent("2026-01-04_09-00-00.jsonl")
        try """
        {"ts":"2026-01-04T09:00:00+01:00","source":"system","speaker":"user-5","text":"from before the move"}
        """.write(to: d, atomically: true, encoding: .utf8)
        try #"{"user-5":"Dylan"}"#
            .write(to: snips.appendingPathComponent("2026-01-04_09-00-00.names.json"),
                   atomically: true, encoding: .utf8)
        TranscriptNames.adoptSidecars(in: snips)
        check(TranscriptNames.load(for: d)["user-5"] == "Dylan",
              "a name written when names lived in a sidecar survives the move into the file")
        check(TranscriptSnippets.meetings(dir: snips).count == 4,
              "and the sidecar is gone rather than left to be re-applied forever")

        try? FileManager.default.removeItem(at: snips)

        // MARK: Transcriber — jfk.wav all the way to JSONL on disk
        let model = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models/ggml-tiny.bin")
        guard FileManager.default.fileExists(atPath: model.path) else {
            print("  SKIP  transcriber (no ggml-tiny.bin — run ./setup.sh)")
            print("segmenter + snippet checks passed")
            return
        }

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("susurro-smoke-\(getpid())")
        // Its own live directory, emphatically. The default is `~/.susurro/live`, and
        // `publishStragglers` would move a real stranded meeting into this temp dir.
        let hot = out.appendingPathComponent("live")
        let gallery = out.appendingPathComponent("speakers.json")
        let models = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models")

        // No speaker models is a skip, not a failure — the app degrades the same way,
        // labelling every system line "unknown" rather than losing the transcript.
        let book = SpeakerBook(models: models, threshold: 0.65, url: gallery)
        if book == nil { print("  SKIP  speaker labels (no speaker models — run ./setup.sh)") }

        guard let t = Transcriber(model: model, vad: nil, speakers: book, dir: out,
                                  liveDir: hot) else {
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

        func jsonl(_ dir: URL) -> [URL] {
            let all = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            return (all ?? []).filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        // The whole reason naming can rewrite a file: while `Transcriber` holds it open at
        // a cached offset it is not in the directory anything else reads. A rewrite there
        // would leave the next append landing mid-file.
        //
        // `submit` is async, so wait for the first line rather than racing it.
        for _ in 0..<600 where jsonl(hot).isEmpty { usleep(50_000) }
        check(jsonl(hot).count == 1 && jsonl(out).isEmpty,
              "an open transcript is in the live directory and nowhere else "
              + "(live \(jsonl(hot).count), published \(jsonl(out).count))")

        t.close()                                   // drains the queue, flushes the gallery
        check(jsonl(hot).isEmpty && jsonl(out).count == 1,
              "closing publishes it, and only then")

        func transcripts() -> [URL] { jsonl(out) }

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
            check(reopened.label(tail)?.id == "1",
                  "reloaded gallery still matches a later slice of the same voice")

            // Catches the one failure every check above would survive: an embedder
            // returning a constant vector, collapsing everyone into user-1. Dropping
            // every 6th sample raises rate and pitch ~1.2x, which moves the formants.
            var pitched: [Float] = []
            for (i, v) in pcm.enumerated() where i % 6 != 0 { pitched.append(v) }
            check(reopened.label(pitched)?.id == "2",
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

            // MARK: the walk — `drift` caps one hop, nothing caps their sum
            //
            // Same voice over and over, with drift wide open: without the freeze the
            // centroid keeps moving forever, which is how one entry ends up within
            // `threshold` of everybody. Feeding it *one* voice understates the real
            // damage (the room's other voices are what it walks toward) and is still
            // enough to catch a freeze that stopped working.
            let walk = out.appendingPathComponent("walk.json")
            var prints: [[Float]] = []
            for _ in 0..<25 {
                guard let w = SpeakerBook(models: models, threshold: 0.65, drift: 1, url: walk)
                else { print("  FAIL  could not open walk gallery"); exit(1) }
                _ = w.label(pcm)
                w.close()
                prints.append(SpeakerNames.load(from: walk)[0].currentEmbedding)
            }
            let moved = zip(prints[prints.count - 2], prints[prints.count - 1])
                .contains { $0 != $1 }
            check(!moved, "a settled voiceprint stops moving (25 matches, drift wide open)")

            // MARK: names stay out of the transcript
            //
            // Naming a voice must change what the *reader* sees and nothing the engine
            // writes. If a name ever reaches this label again, it is baked into every
            // later line and one rename retroactively renames every meeting — the bug the
            // sidecar exists to prevent.
            TranscriptNames.apply(["user-1": "Ana"], to: transcripts()[0])
            guard let after = SpeakerBook(models: models, threshold: 0.65, url: gallery)
            else { print("  FAIL  could not reopen gallery"); exit(1) }
            check(after.label(tail)?.id == "1",
                  "a named voice still identifies as an id, not a name "
                  + "(got \(after.label(tail)?.id as Any))")
            after.close()
            check(TranscriptNames.load(for: transcripts()[0])["user-1"] == "Ana",
                  "flushing the gallery does not disturb the transcript's names")
            check(SpeakerNames.load(from: gallery).allSatisfy { $0.currentEmbedding.count == 256 },
                  "and it keeps every voiceprint")
        }

        // A gap longer than `gapSec` starts a new file. gapSec: 0 makes any elapsed time
        // count as a gap; the sleep is only so the name lands in a different second.
        sleep(1)
        guard let t2 = Transcriber(model: model, vad: nil, gapSec: 0, dir: out,
                                   liveDir: hot) else {
            print("  FAIL  reopen for gap check"); exit(1)
        }
        t2.submit(pcm, source: "mic")
        t2.close()
        check(transcripts().count == 2,
              "a silence gap starts a second file (got \(transcripts().count))")

        // A meeting stranded by a crash is finished by definition: the next launch
        // publishes it rather than leaving it where nothing reads it.
        try "{\"ts\":\"x\",\"speaker\":\"user-1\",\"text\":\"orphaned\"}"
            .write(to: hot.appendingPathComponent("2026-01-09_09-00-00.jsonl"),
                   atomically: true, encoding: .utf8)
        _ = Transcriber(model: model, vad: nil, dir: out, liveDir: hot)
        check(jsonl(hot).isEmpty && transcripts().count == 3,
              "a transcript stranded by a crash is published on the next launch "
              + "(live \(jsonl(hot).count), published \(transcripts().count))")

        try? FileManager.default.removeItem(at: out)
        print("all checks passed")
    }
}
