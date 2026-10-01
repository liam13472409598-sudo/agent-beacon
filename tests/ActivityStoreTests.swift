import Foundation

@main
struct ActivityStoreTests {
    static let fm = FileManager.default
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    static func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    static func row(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10); return data
    }
    static func event(_ type: String, at date: Date, payload: [String: Any] = [:], outer: String = "event_msg") throws -> Data {
        var p = payload; p["type"] = type
        return try row(["type": outer, "timestamp": ISO8601DateFormatter().string(from: date), "payload": p])
    }
    static func main() throws {
        let home = fm.temporaryDirectory.appendingPathComponent("AgentBeacon-tests-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try testTail(home)
        try testStore(home.appendingPathComponent("store"))
        try testObserver(home.appendingPathComponent("watch"))
        print("PASS: \(assertions) assertions (incremental reads, lifecycle, hooks, FSEvents)")
        if CommandLine.arguments.contains("--benchmark-local") {
            let store = ActivityStore(home: fm.homeDirectoryForCurrentUser)
            let started = Date()
            let first = store.snapshot()
            print("Local cold snapshot: \(first.count) activities, \(store.bytesRead) bytes, \(store.parsedLines) lines, \(Date().timeIntervalSince(started))s")
            let bytes = store.bytesRead, lines = store.parsedLines
            let warm = Date()
            for _ in 0..<20 { _ = store.snapshot() }
            print("Local 20 warm snapshots: \(store.bytesRead - bytes) bytes, \(store.parsedLines - lines) lines, \(Date().timeIntervalSince(warm))s total")
        }
    }
    static func testTail(_ home: URL) throws {
        let url = home.appendingPathComponent("tail.jsonl")
        let tail = JSONLineTail()
        var lines: [String] = []; var resets = 0
        func consume() { tail.consume(url, reset: { resets += 1; lines = [] }, line: { lines.append($0) }) }
        try write(Data("one\n".utf8), to: url); consume()
        check(lines == ["one"], "initial read")
        let bytes = tail.bytesRead; consume()
        check(tail.bytesRead == bytes && resets == 1, "unchanged file must not be reread")
        let unicode = Data("中文\n".utf8)
        try append(unicode.prefix(2), to: url); consume()
        check(lines == ["one"], "defer partial UTF-8")
        try append(unicode.dropFirst(2), to: url); consume()
        check(lines == ["one", "中文"], "reassemble split UTF-8 once")
        let before = tail.bytesRead
        try append(Data("two\n".utf8), to: url); consume()
        check(lines == ["one", "中文", "two"], "append without duplicates")
        check(tail.bytesRead - before <= 68, "append must not reread history")
        try write(Data("x\n".utf8), to: url); consume()
        check(lines == ["x"], "truncate resets state")
        try write(Data("a completely replaced longer line\n".utf8), to: url); consume()
        check(lines == ["a completely replaced longer line"], "truncate and regrow resets state")
        try Data("atomic replacement\n".utf8).write(to: url, options: .atomic); consume()
        check(lines == ["atomic replacement"], "atomic replacement resets state")
        try fm.removeItem(at: url); consume()
        check(lines.isEmpty, "deleted file clears state")
        try write(Data("new\n".utf8), to: url); consume()
        check(lines == ["new"], "recreated file is read")
    }
    static func testStore(_ home: URL) throws {
        let now = Date()
        let url = home.appendingPathComponent(".codex/sessions/2026/10/01/a.jsonl")
        let store = ActivityStore(home: home)
        try write(try event("task_started", at: now), to: url)
        try append(try event("message", at: now, payload: ["role": "user", "content": [["text": "Fix tests"]]], outer: "response_item"), to: url)
        try append(try event("function_call", at: now, payload: ["name": "exec", "arguments": "{\"cmd\":\"swift test\"}"], outer: "response_item"), to: url)
        let first = store.snapshot(now: now)
        check(first.count == 1 && first[0].state == .working && first[0].title == "Fix tests", "initial task")
        check(first[0].log.last?.value == "swift test", "command snippet")
        let bytes = store.bytesRead, lines = store.parsedLines
        let repeated = store.snapshot(now: now)
        check(first == repeated && first[0].log.last?.id == repeated[0].log.last?.id, "stable display and line identity")
        check(store.bytesRead == bytes && store.parsedLines == lines, "unchanged snapshots do no parsing")
        try append(try event("token_count", at: now.addingTimeInterval(1)), to: url)
        check(store.snapshot(now: now) == first, "telemetry must not invalidate display")
        let completed = try event("task_complete", at: now.addingTimeInterval(2))
        try append(completed.dropLast(), to: url)
        check(store.snapshot(now: now)[0].state == .working, "partial completion must wait for newline")
        try append(Data([10]), to: url)
        let done = store.snapshot(now: now)[0]
        check(done.state == .recent && done.completedAt != nil, "completion detected")
        try append(try event("task_started", at: now.addingTimeInterval(3)), to: url)
        let restarted = store.snapshot(now: now)[0]
        check(restarted.state == .working && restarted.completedAt == nil && restarted.log.isEmpty, "new turn resets completion and log")
        check(store.snapshot(now: now.addingTimeInterval(1205))[0].state == .recent, "time expiry without file change")
        let second = home.appendingPathComponent(".codex/sessions/new-folder/b.jsonl")
        try write(try event("task_started", at: now), to: second)
        check(store.snapshot(rediscover: true, now: now).filter { $0.source == "Codex" }.count == 2, "discover new nested session")
        try fm.removeItem(at: second)
        check(store.snapshot(now: now).count == 1, "deleted session disappears")
        let fallback = home.appendingPathComponent(".cursor/projects/project/transcript.jsonl")
        try write(try row(["role": "user", "message": ["content": [["type": "text", "text": "Fallback title"]]]]), to: fallback)
        check(store.snapshot(rediscover: true, now: now).contains { $0.id == "cursor-fallback" && $0.title == "Fallback title" }, "Cursor fallback")
        let hook = home.appendingPathComponent("Library/Application Support/AgentBeacon/events.jsonl")
        func hookData(_ name: String, _ index: Int, session: String = "one", title: String = "") throws -> Data {
            try row(["source": "Cursor", "session": session, "event": name, "title": title,
                     "step": "step \(index)", "timestamp": now.addingTimeInterval(Double(index)).timeIntervalSince1970])
        }
        try write(try hookData("beforeSubmitPrompt", 0, title: "Persistent title"), to: hook)
        for i in 1...12 { try append(try hookData("afterShellExecution", i), to: hook) }
        try append(try hookData("beforeSubmitPrompt", 13, session: "two", title: "Other session"), to: hook)
        let hooks = store.snapshot(now: now).filter { $0.source == "Cursor" }
        check(hooks.count == 2 && !hooks.contains { $0.id == "cursor-fallback" }, "hooks replace fallback; sessions stay separate")
        check(hooks.first { $0.id == "Cursor-one" }?.title == "Persistent title", "hook title survives log window")
        check(hooks.first { $0.id == "Cursor-one" }?.log.count == 6, "bounded recent display")
        try append(try hookData("stop", 14), to: hook)
        check(store.snapshot(now: now).first { $0.id == "Cursor-one" }?.completedAt != nil, "hook stop")
        try append(try hookData("beforeSubmitPrompt", 15), to: hook)
        let resumed = store.snapshot(now: now).first { $0.id == "Cursor-one" }
        check(resumed?.state == .working && resumed?.completedAt == nil, "hook restart")
        check(store.snapshot(now: now.addingTimeInterval(86500)).isEmpty, "24-hour expiry")
    }
    static func testObserver(_ home: URL) throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        var notices: [Bool] = []
        let observer = ActivityFileObserver(home: home) { notices.append($0) }
        func waitForNotice() {
            let deadline = Date().addingTimeInterval(4)
            while notices.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        let file = home.appendingPathComponent(".codex/sessions/new/day/test.jsonl")
        try write(Data("{}\n".utf8), to: file)
        waitForNotice()
        check(notices.contains(true), "FSEvents discovers nested folder/file created after watcher starts")
        notices = []
        try append(Data("{}\n".utf8), to: file)
        waitForNotice()
        check(!notices.isEmpty, "FSEvents observes append")
        withExtendedLifetime(observer) {}
    }
}
