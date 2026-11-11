import AppKit
import SwiftUI

// MARK: - live transcript

/// One transcribed segment as the live window shows it, or a pause marker (`speaker` empty).
struct LiveLine: Identifiable {
    let id: Int
    let time: String
    let speaker: String
    let text: String
    var isBreak: Bool { speaker.isEmpty }
}

/// The meeting in progress, as far as the window is concerned.
///
/// Pausing hides, it does not stop: the transcript file keeps everything. Hiding is decided
/// by the *epoch the audio was captured in*, never by when whisper's text comes back — that
/// is seconds later, and checking `paused` on arrival hides the sentence said just before
/// the press and shows the one said just before resuming. Even epochs show, odd ones hide.
@Observable
final class LiveTranscript {
    private(set) var lines: [LiveLine] = []
    private(set) var epoch = 0
    var selected: Set<Int> = []
    private var pausedAt: Date?

    var paused: Bool { epoch % 2 == 1 }

    /// The selected segments, oldest first — the order they were said in.
    var selection: [LiveLine] { lines.filter { selected.contains($0.id) && !$0.isBreak } }

    /// Flip, and return the new epoch for the segmenters to cut at.
    func toggle() -> Int {
        epoch += 1
        if paused {
            pausedAt = Date()
        } else if let from = pausedAt {
            // The marker goes in on resume, not on pause: by now the lines from before the
            // press have come back from whisper and sit above it, where they were said.
            let f = Date.FormatStyle.dateTime.hour().minute()
            lines.append(LiveLine(id: lines.count, time: "",
                                  speaker: "",
                                  text: "paused \(from.formatted(f)) – \(Date().formatted(f))"))
        }
        return epoch
    }

    func receive(_ l: TranscriptLine, epoch e: Int) {
        guard e % 2 == 0 else { return }
        // "2026-08-10T14:32:07+02:00" → "14:32:07"
        lines.append(LiveLine(id: lines.count, time: String(l.ts.dropFirst(11).prefix(8)),
                              speaker: l.speaker, text: l.text))
    }
}

// MARK: - context documents

struct ContextDoc: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

/// What the agent is told besides the transcript. The list is this run of the app only;
/// every document is also copied to `dir` so a later run can offer it under Recent.
@Observable
final class ContextDocs {
    private(set) var docs: [ContextDoc] = []
    var problem: String?

    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/context")

    func add(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            problem = "\(url.lastPathComponent) is not a UTF-8 text file"
            return
        }
        add(name: url.lastPathComponent, text: text)
    }

    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { problem = "Nothing to paste — the clipboard holds no text"; return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        add(name: "Pasted \(stamp.replacingOccurrences(of: ":", with: "-")).txt", text: text)
    }

    func remove(_ d: ContextDoc) { docs.removeAll { $0.id == d.id } }

    /// Saved documents not already in the list, newest first.
    func recent() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: keys)) ?? []
        let open = Set(docs.map(\.name))
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return all.filter { !open.contains($0.lastPathComponent) }
            .sorted { mtime($0) > mtime($1) }
            .prefix(15).map { $0 }
    }

    /// Same name replaces: re-adding an edited file must not send both versions.
    private func add(name: String, text: String) {
        problem = nil
        docs.removeAll { $0.name == name }
        docs.append(ContextDoc(name: name, text: text))
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: Self.dir.appendingPathComponent(name).path,
                      contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - agent

struct AgentTurn: Identifiable {
    let id = UUID()
    let prompt: String
    let attached: String
    var reply = ""
    var note: String?
}

/// One `claude -p` per question, chained with `--resume` into a single conversation.
///
/// Run from a fixed directory because `--resume` looks sessions up per project directory,
/// and with the user's settings, hooks and MCP servers switched off: this is a meeting
/// assistant, not their coding setup, and a SessionStart hook or a slow MCP server has no
/// business in the middle of a call. Auth still comes from their normal `claude` login.
@Observable
final class Agent {
    private(set) var turns: [AgentTurn] = []
    private(set) var running = false
    var tools = false

    private var session: String?
    private var sent: [String: String] = [:]   // document name → text already in the session
    private var process: Process?

    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/agent")

    private static let system = """
        You are helping the user during a live conversation. Transcript excerpts are machine \
        transcription of speech: "me" is the user's own microphone, "unknown" is anyone else \
        on the call. Expect transcription errors. Be concise — the user is reading this while \
        the conversation continues.
        """

    /// A Finder-launched app gets PATH=/usr/bin:/bin, so look where installers put it.
    /// ponytail: fixed list; an nvm-managed npm install is not on it.
    private static var claude: URL? {
        let home = NSHomeDirectory()
        return [home + "/.local/bin/claude", home + "/.claude/local/claude",
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Documents new or changed since this conversation last saw them go along; the
    /// selected lines go every time, because the selection is what the question is about.
    func ask(_ question: String, docs: [ContextDoc], lines: [LiveLine]) {
        guard !running else { return }
        let fresh = docs.filter { sent[$0.name] != $0.text }
        var parts: [String] = []
        if !fresh.isEmpty {
            parts.append("<context_documents>\n" + fresh.map {
                "<document name=\"\($0.name)\">\n\($0.text)\n</document>"
            }.joined(separator: "\n") + "\n</context_documents>")
        }
        if !lines.isEmpty {
            parts.append("<transcript_excerpt>\n" + lines.map {
                "[\($0.time)] \($0.speaker): \($0.text)"
            }.joined(separator: "\n") + "\n</transcript_excerpt>")
        }
        parts.append(question)

        var attached: [String] = []
        if !fresh.isEmpty { attached.append("\(fresh.count) document\(fresh.count == 1 ? "" : "s")") }
        if !lines.isEmpty { attached.append("\(lines.count) line\(lines.count == 1 ? "" : "s")") }
        turns.append(AgentTurn(prompt: question, attached: attached.joined(separator: " · ")))
        let i = turns.count - 1

        guard let exe = Self.claude else {
            turns[i].note = "claude CLI not found — install it from code.claude.com"
            return
        }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--setting-sources", "",
                    "--strict-mcp-config", "--append-system-prompt", Self.system]
        let readOnly = "WebSearch,WebFetch,Read"
        // In -p nobody can answer a permission prompt, so a tool must be listed as both
        // available and allowed, or it is silently denied.
        args += tools ? ["--tools", readOnly, "--allowedTools", readOnly] : ["--tools", ""]
        if let session { args += ["--resume", session] }

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = Self.dir
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        // A read can end mid-line; only whole lines are JSON.
        var pending = Data()
        // Read to EOF rather than stopping at exit: the last line is the `result` event, and
        // for a failed login or an API error it is the only place the reason is.
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0a) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                DispatchQueue.main.async { self?.handle(o, turn: i) }
            }
        }
        var stderr = Data()
        errors.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        p.terminationHandler = { [weak self] proc in
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.process = nil
                if self.session == nil { self.sent = [:] }   // nothing to resume into
                if proc.terminationStatus != 0, self.turns[i].note == nil,
                   self.turns[i].reply.isEmpty {
                    let why = String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.turns[i].note = why.isEmpty ? "claude exited (\(proc.terminationStatus))" : why
                }
            }
        }

        do {
            try p.run()
        } catch {
            turns[i].note = "could not start claude: \(error.localizedDescription)"
            return
        }
        running = true
        process = p
        for d in fresh { sent[d.name] = d.text }
        // Off main: context can be bigger than a pipe buffer.
        let data = Data(parts.joined(separator: "\n\n").utf8)
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
    }

    func stop() { process?.terminate() }

    func reset() {
        guard !running else { return }
        turns = []
        session = nil
        sent = [:]
    }

    private func handle(_ o: [String: Any], turn i: Int) {
        guard turns.indices.contains(i) else { return }
        if session == nil, let id = o["session_id"] as? String { session = id }
        switch o["type"] as? String {
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { return }
            switch e["type"] as? String {
            case "content_block_delta":
                if let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                   let t = d["text"] as? String { turns[i].reply += t }
            case "content_block_start":
                if let b = e["content_block"] as? [String: Any], b["type"] as? String == "tool_use",
                   let name = b["name"] as? String { turns[i].reply += "\n\n*using \(name)…*\n\n" }
            case "message_start":
                // Text after a tool call is a new message; do not glue it to the last word.
                if !turns[i].reply.isEmpty, !turns[i].reply.hasSuffix("\n") { turns[i].reply += "\n\n" }
            default: break
            }
        case "result":
            let text = o["result"] as? String ?? ""
            if o["is_error"] as? Bool == true {
                turns[i].note = text.isEmpty ? "claude reported an error" : text
            } else if turns[i].reply.isEmpty {
                turns[i].reply = text
            }
        default: break
        }
    }
}

// MARK: - window

struct LiveView: View {
    let engine: Engine
    let live: LiveTranscript
    let docs: ContextDocs
    @Bindable var agent: Agent

    @AppStorage("liveFontSize") private var fontSize = 14.0
    @State private var tab = 0
    @State private var question = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Transcript").tag(0)
                    Text(docs.docs.isEmpty ? "Context" : "Context (\(docs.docs.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if tab == 0 { transcript } else { context }
            }
            .frame(minWidth: 380)

            agentPanel.frame(minWidth: 300, idealWidth: 360)
        }
        .frame(minWidth: 720, minHeight: 440)
        .toolbar {
            ToolbarItem {
                Button(live.paused ? "Resume" : "Pause",
                       systemImage: live.paused ? "play.fill" : "pause.fill") {
                    engine.togglePause()
                }
                .help(live.paused ? "Show new lines again" : "Stop showing new lines — the transcript file keeps recording")
            }
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: $fontSize, in: 10...32).frame(width: 110)
                    Image(systemName: "textformat.size.larger")
                }
                .help("Text size")
            }
        }
    }

    // MARK: transcript tab

    private var transcript: some View {
        VStack(spacing: 0) {
            if !engine.enabled {
                banner("Not listening.", action: ("Start listening", { engine.setEnabled(true) }))
            } else if engine.loading {
                banner("Loading model…")
            } else if live.paused {
                banner("Paused — still recording to the transcript file, just not shown here.")
            }
            ScrollViewReader { proxy in
                List(live.lines) { line($0) }
                    .onChange(of: live.lines.count) {
                        // Not while picking lines: jumping away mid-selection loses your place.
                        if live.selected.isEmpty, let last = live.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .overlay {
                        if live.lines.isEmpty {
                            Text("Lines appear here a few seconds after they are spoken.")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            Divider()
            HStack {
                Text(live.selected.isEmpty ? "Click lines to select them for the agent"
                                           : "\(live.selected.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear selection") { live.selected = [] }
                    .disabled(live.selected.isEmpty)
            }
            .font(.caption)
            .padding(8)
        }
    }

    @ViewBuilder
    private func line(_ l: LiveLine) -> some View {
        if l.isBreak {
            Text("— \(l.text) —")
                .font(.system(size: fontSize * 0.8))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            let on = live.selected.contains(l.id)
            // A Button, not onTapGesture, so a row stays keyboard-reachable.
            Button {
                if on { live.selected.remove(l.id) } else { live.selected.insert(l.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(l.time)
                        .font(.system(size: fontSize * 0.75).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(l.speaker)
                        .font(.system(size: fontSize * 0.75))
                        .foregroundStyle(l.speaker == "me" ? Color.accentColor : .secondary)
                        .frame(minWidth: fontSize * 3.5, alignment: .leading)
                    Text(l.text).font(.system(size: fontSize))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(on ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func banner(_ text: String, action: (String, () -> Void)? = nil) -> some View {
        HStack {
            Text(text)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .font(.callout)
        .padding(8)
        .background(.yellow.opacity(0.15))
    }

    // MARK: context tab

    private var context: some View {
        VStack(spacing: 0) {
            List {
                ForEach(docs.docs) { d in
                    HStack {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text("\(d.text.count) characters").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { docs.remove(d) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Remove from this session")
                    }
                }
            }
            .overlay {
                if docs.docs.isEmpty {
                    Text("Drop text files here, or paste text (⌘V).")
                        .foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                urls.forEach(docs.add)
                return !urls.isEmpty
            }
            .onPasteCommand(of: [.utf8PlainText, .plainText]) { _ in docs.paste() }

            if let p = docs.problem {
                Text(p).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
            }
            Divider()
            HStack {
                Button("Add files…", action: pickFiles)
                Button("Paste text") { docs.paste() }
                Menu("Recent") {
                    let recent = docs.recent()
                    if recent.isEmpty { Text("Nothing else used before") }
                    ForEach(recent, id: \.self) { u in
                        Button(u.lastPathComponent) { docs.add(u) }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding(8)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach(docs.add) }
    }

    // MARK: agent panel

    private var agentPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent").font(.headline)
                Spacer()
                Toggle("Web & file tools", isOn: $agent.tools)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Let Claude use WebSearch, WebFetch and Read (read-only)")
                Button { agent.reset() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .disabled(agent.running || agent.turns.isEmpty)
                    .help("New conversation")
            }
            .padding(8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(agent.turns) { turn($0) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                }
                .onChange(of: agent.turns.last?.reply) { proxy.scrollTo("end", anchor: .bottom) }
                .overlay {
                    if agent.turns.isEmpty {
                        Text("Select lines, add context, and ask.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask about the selected lines…", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if agent.running {
                    Button("Stop", action: agent.stop)
                } else {
                    Button("Send", action: send)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(8)
        }
    }

    private func turn(_ t: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.prompt).bold()
            if !t.attached.isEmpty {
                Text(t.attached).font(.caption).foregroundStyle(.secondary)
            }
            if !t.reply.isEmpty {
                Text((try? AttributedString(markdown: t.reply, options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t.reply))
                    .textSelection(.enabled)
            } else if agent.running, t.id == agent.turns.last?.id, t.note == nil {
                ProgressView().controlSize(.small)
            }
            if let n = t.note { Text(n).foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.system(size: fontSize))
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !agent.running else { return }
        agent.ask(q, docs: docs.docs, lines: live.selection)
        question = ""
    }
}
