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

        let roster = meetings[1].voices
        check(roster.map(\.label) == ["user-1", "user-2"],
              "every voice in the meeting, and `me` is not one of them "
              + "(got \(roster.map(\.label)))")
        check(roster[0].lines == 3, "lines per voice (got \(roster[0].lines))")
        check(roster[0].sample.hasPrefix("the longest thing"),
              "the sample is the longest line, not the first (got \(roster[0].sample))")

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

        // MARK: clustering — who spoke, decided from the whole meeting at once
        //
        // No models: cosine over vectors is arithmetic. These are the checks that the old
        // online matcher could never have passed, because it judged each segment alone.
        func vec(_ a: Float, _ b: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 256)
            let n = (a * a + b * b).squareRoot()      // L2-normalised, as wespeaker's are
            v[0] = a / n; v[1] = b / n
            return v
        }
        let ana = vec(1, 0), anaAgain = vec(0.99, 0.14), bruno = vec(0, 1)
        check(Cluster.distance(ana, ana) < 0.001, "a voiceprint is zero from itself")
        check(Cluster.distance(ana, bruno) > 0.99, "and far from an unrelated one")

        // Two of Ana and one of Bruno: two speakers, and Ana is `s1` for talking most.
        let three = Cluster.speakers([ana, anaAgain, bruno], durations: [10, 10, 10],
                                     threshold: 0.6, minSeconds: 3)
        check(three == [0, 0, 1],
              "segments of one voice land in one cluster, ranked by speech (got \(three))")

        // The same three with Bruno talking longest: the ranking follows the speech, not
        // the order of arrival.
        check(Cluster.speakers([ana, anaAgain, bruno], durations: [4, 4, 30],
                               threshold: 0.6, minSeconds: 3) == [1, 1, 0],
              "whoever talked most is s1")

        // A two-second "yeah" is not a person. This is the 41% of voices the old matcher
        // minted that spoke exactly one line.
        check(Cluster.speakers([ana, anaAgain, bruno], durations: [10, 10, 2],
                               threshold: 0.6, minSeconds: 3) == [0, 0, nil],
              "a cluster with too little speech is dropped rather than numbered")

        // Average linkage, not single. `between` is 0.29 from each of the other two, which
        // are 1.0 from each other. Single linkage merges `between` with Ana, then sees
        // 0.29 to Bruno — the nearest pair, ignoring how far the rest of the cluster is —
        // and welds all three into one person. Average linkage sees (1.0 + 0.29) / 2 and
        // stops. Chaining like this is the failure that loses a transcript, because
        // nothing recovers two people filed as one.
        let between = vec(0.71, 0.71)
        let chained = Cluster.speakers([ana, between, bruno], durations: [10, 10, 10],
                                       threshold: 0.4, minSeconds: 3)
        check(Set(chained.compactMap { $0 }).count == 2,
              "a borderline segment does not chain two speakers into one (got \(chained))")

        check(Cluster.speakers([nil, ana], durations: [5, 5], threshold: 0.6, minSeconds: 3)
                == [nil, 0],
              "a segment with no voiceprint keeps its slot and no cluster")
        check(Cluster.speakers([], durations: [], threshold: 0.6, minSeconds: 3).isEmpty,
              "an empty meeting clusters to nothing")

        // MARK: voiceprints on disk, and the labelling that reads them back
        let clus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("susurro-cluster-\(getpid())")
        try FileManager.default.createDirectory(at: clus, withIntermediateDirectories: true)
        let meet = clus.appendingPathComponent("2026-02-01_09-00-00.jsonl")

        for v in [ana, anaAgain, bruno, ana] {
            VoicePrintFile.append(v, to: VoicePrintFile.url(for: meet))
        }
        let readBack = VoicePrintFile.load(for: meet)
        check(readBack.count == 4 && readBack[0].count == 256,
              "voiceprints round-trip as a wall of floats (got \(readBack.count))")
        check(Cluster.distance(readBack[0], ana) < 0.001, "and come back unchanged")

        // `seg` is what joins a line to its voiceprint — deliberately not the line's
        // position, so a mic line in the middle cannot shift the alignment.
        try """
        {"ts":"2026-02-01T09:00:00+01:00","source":"system","speaker":"unknown","dur":12,"text":"ana one","seg":0}
        {"ts":"2026-02-01T09:00:20+01:00","source":"mic","speaker":"me","dur":5,"text":"and you"}
        {"ts":"2026-02-01T09:00:40+01:00","source":"system","speaker":"unknown","dur":12,"text":"ana two","seg":1}
        {"ts":"2026-02-01T09:01:00+01:00","source":"system","speaker":"unknown","dur":2,"text":"yeah","seg":2}
        {"ts":"2026-02-01T09:01:20+01:00","source":"system","speaker":"unknown","dur":12,"text":"ana three","seg":3}
        """.write(to: meet, atomically: true, encoding: .utf8)
        TranscriptSpeakers.assign(meet, threshold: 0.6, minSeconds: 3)

        let labelled = TranscriptSnippets.decode(meet).compactMap { $0 }
        check(labelled.map(\.speaker) == ["s1", "me", "s1", "unknown", "s1"],
              "the meeting is labelled from its own voiceprints, mic untouched, the "
              + "two-second segment left unknown (got \(labelled.map(\.speaker)))")
        check(labelled.map(\.text) == ["ana one", "and you", "ana two", "yeah", "ana three"],
              "and not a word of it moved")
        try? FileManager.default.removeItem(at: clus)

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
        let models = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/models")

        // No speaker models is a skip, not a failure — the app degrades the same way,
        // labelling every system line "unknown" rather than losing the transcript.
        let voices = VoicePrints(models: models)
        if voices == nil { print("  SKIP  speaker labels (no speaker models — run ./setup.sh)") }

        guard let t = Transcriber(model: model, vad: nil, voices: voices, dir: out,
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
        check(obj["seg"] == nil, "mic line carries no voiceprint")

        // Three submits, two of one voice and — below — one of another, all clustered when
        // the meeting closed. Not while it ran: that is the whole change.
        let system = lines.filter { $0["source"] as? String == "system" }
        if voices == nil {
            check(system.allSatisfy { $0["speaker"] as? String == "unknown" },
                  "without speaker models every system line stays unknown")
        } else {
            check(system.allSatisfy { $0["seg"] != nil },
                  "every system line points at its voiceprint")
            check(system.map { $0["seg"] as? Int } == [0, 1],
                  "and the indices run in order (got \(system.map { $0["seg"] as? Int }))")
            check(system.allSatisfy { $0["speaker"] as? String == "s1" },
                  "the same voice twice is one speaker (got "
                  + "\(system.map { $0["speaker"] as? String }))")
            check(VoicePrintFile.load(for: transcripts()[0]).count == 2,
                  "the voiceprints travel with the published transcript")

            // The check that catches an embedder returning a constant vector, which would
            // collapse everyone into one speaker while every assertion above still passed.
            // Dropping every 6th sample raises rate and pitch ~1.2x, which moves the
            // formants — a different person as far as the model is concerned.
            var pitched: [Float] = []
            for (i, v) in pcm.enumerated() where i % 6 != 0 { pitched.append(v) }
            guard let a = voices?.embed(pcm), let b = voices?.embed(pitched) else {
                print("  FAIL  could not embed"); exit(1)
            }
            check(Cluster.distance(a, a) < 0.001 && Cluster.distance(a, b) > 0.6,
                  "a different voice is a different voiceprint (got "
                  + "\(Cluster.distance(a, b)))")

            // Naming still cannot leak across meetings, and clustering must not have
            // disturbed what the naming window writes.
            TranscriptNames.apply(["s1": "Ana"], to: transcripts()[0])
            check(TranscriptNames.load(for: transcripts()[0])["s1"] == "Ana",
                  "a clustered meeting names the same way")
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
