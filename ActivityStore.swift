import Foundation
import CoreServices

// Owned by Monitor's serial utility queue. Offsets and reducers never cross queues.
final class JSONLineTail {
    private var identity: String?
    private var offset: UInt64 = 0
    private var modified: Date?
    private var pending = Data()
    private var checkpoint = Data()
    private(set) var bytesRead = 0

    func consume(_ url: URL, reset: () -> Void, line: (String) -> Void) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            if identity != nil { clear(); reset() }
            return
        }
        let fileID = "\(attributes[.systemNumber] ?? ""): \(inode)"
        let date = attributes[.modificationDate] as? Date
        if identity == fileID && size == offset && date == modified { return }
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }
        do {
            var replaced = identity != fileID || size < offset || (size == offset && date != modified)
            // Also detect truncate-and-regrow between notifications, even on the same inode.
            if !replaced && !checkpoint.isEmpty {
                try file.seek(toOffset: offset - UInt64(checkpoint.count))
                let check = try file.read(upToCount: checkpoint.count) ?? Data()
                bytesRead += check.count
                replaced = check != checkpoint
            }
            if replaced { clear(); reset(); identity = fileID }
            try file.seek(toOffset: offset)
            while offset < size {
                let data = try file.read(upToCount: Int(min(262_144, size - offset))) ?? Data()
                if data.isEmpty { break }
                bytesRead += data.count
                offset += UInt64(data.count)
                checkpoint.append(data)
                checkpoint = Data(checkpoint.suffix(64))
                pending.append(data)
                // Keep an incomplete UTF-8/JSON line until its newline is appended.
                while let end = pending.firstIndex(of: 10) {
                    let record = pending[..<end]
                    if let text = String(data: record, encoding: .utf8), !text.isEmpty { line(text) }
                    pending.removeSubrange(...end)
                }
            }
            modified = date
        } catch {
            // Keep the consumed offset. A later event or reconciliation retries the remainder.
        }
    }

    private func clear() {
        identity = nil; offset = 0; modified = nil
        pending.removeAll(keepingCapacity: false); checkpoint.removeAll(keepingCapacity: false)
    }
}

private enum LogText {
    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func short(_ text: String, length: Int = 80) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(length))
    }
    static func snippet(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8)
            .joined(separator: "\n").prefix(520)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func callCode(_ payload: [String: Any]) -> String {
        let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
        if let object = object(raw) {
            for key in ["cmd", "command", "code", "input", "path"] {
                if let value = object[key] as? String { return snippet(value) }
            }
        }
        return snippet(raw)
    }
    static func content(_ value: Any?) -> String {
        (value as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
    }
}

private struct CodexLog {
    var title = "Codex 任务"
    var step = "正在思考"
    var started: Date?
    var ended: Date?
    var updated = Date.distantPast
    var log: [ActivityLine] = []

    mutating func consume(_ text: String, formatter: ISO8601DateFormatter) {
        guard let row = LogText.object(text), let p = row["payload"] as? [String: Any],
              let type = p["type"] as? String else { return }
        let outer = row["type"] as? String
        // Token counters and other telemetry do not change the displayed task.
        guard (outer == "event_msg" && ["task_started", "task_complete", "turn_aborted"].contains(type)) ||
                (outer == "response_item" && ["message", "function_call", "custom_tool_call"].contains(type)) else { return }
        let rawDate = row["timestamp"] as? String ?? ""
        let date = formatter.date(from: rawDate) ?? ISO8601DateFormatter().date(from: rawDate) ?? .distantPast
        var accepted = true
        if outer == "event_msg" {
            switch type {
            case "task_started": started = date; ended = nil; step = "开始处理任务"; log = []
            default:
                ended = date; step = type == "task_complete" ? "已完成" : "已中止"
                log.append(ActivityLine(kind: .text, value: step, date: date))
            }
        } else if type == "message" {
            let value = LogText.content(p["content"])
            if p["role"] as? String == "user", !value.isEmpty,
               !value.hasPrefix("<"), !value.hasPrefix("[{") { title = LogText.short(value) }
            else if p["role"] as? String == "assistant", !value.isEmpty,
                    ["commentary", "final"].contains(p["phase"] as? String ?? "") {
                if p["phase"] as? String == "commentary" { step = LogText.short(value) }
                log.append(ActivityLine(kind: .text, value: LogText.short(value, length: 220), date: date))
            } else { accepted = false }
        } else {
            step = "调用 \(LogText.short(p["name"] as? String ?? "工具", length: 45))"
            let code = LogText.callCode(p)
            log.append(ActivityLine(kind: code.isEmpty ? .text : .code, value: code.isEmpty ? step : code, date: date))
        }
        if accepted { updated = max(updated, date) }
        log = Array(log.suffix(6))
    }

    func activity(url: URL, modified: Date, now: Date) -> AgentActivity? {
        guard started != nil else { return nil }
        let working = ended == nil && modified > now.addingTimeInterval(-1200)
        return AgentActivity(id: url.lastPathComponent, source: "Codex", title: title,
                             step: working ? step : "最近一次任务已结束", state: working ? .working : .recent,
                             updated: updated, completedAt: ended, log: log)
    }
}

private struct CursorLog {
    var title = "Cursor Agent"
    var step = "最近有 Agent 会话"
    var log: [ActivityLine] = []
    mutating func consume(_ text: String) {
        guard let o = LogText.object(text), let message = o["message"] as? [String: Any] else { return }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if o["role"] as? String == "user", let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            title = LogText.short(text)
        }
        if o["role"] as? String == "assistant" {
            if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                step = "调用 \(LogText.short(tool["name"] as? String ?? "工具"))"
                let input = tool["input"] as? [String: Any] ?? [:]
                let code = ["command", "cmd", "code", "file_path"].compactMap { input[$0] as? String }.first ?? ""
                if !code.isEmpty { log.append(ActivityLine(kind: .code, value: LogText.snippet(code), date: .distantPast)) }
            } else if let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                step = LogText.short(text)
                log.append(ActivityLine(kind: .text, value: LogText.short(text, length: 220), date: .distantPast))
            }
        }
        log = Array(log.suffix(6))
    }
}

private struct HookSession {
    var last: HookEvent
    var title: String
    var started: Date?
    var stopped: HookEvent?
    var recent: [ActivityLine?] = []
    mutating func consume(_ event: HookEvent) {
        last = event
        if !event.title.isEmpty { title = event.title }
        if ["beforeSubmitPrompt", "UserPromptSubmit", "sessionStart", "SessionStart"].contains(event.name) { started = event.date }
        if ["stop", "sessionEnd", "Stop", "SessionEnd"].contains(event.name) { stopped = event }
        if !event.code.isEmpty { recent.append(ActivityLine(kind: .code, value: LogText.snippet(event.code), date: event.date)) }
        else if !event.step.isEmpty { recent.append(ActivityLine(kind: .text, value: event.step, date: event.date)) }
        else { recent.append(nil) }
        recent = Array(recent.suffix(10))
    }
    func activity(now: Date) -> AgentActivity {
        let working = started != nil && (stopped == nil || started! > stopped!.date) && last.date > now.addingTimeInterval(-1200)
        let completed = stopped.map { ["stop", "Stop"].contains($0.name) ? $0.date : nil } ?? nil
        return AgentActivity(id: "\(last.source)-\(last.session)", source: last.source, title: title,
                             step: last.step.isEmpty ? (working ? "正在处理任务" : "任务已结束") : last.step,
                             state: working ? .working : .recent, updated: last.date,
                             completedAt: working ? nil : completed, log: Array(recent.compactMap { $0 }.suffix(6)))
    }
}

final class ActivityStore {
    private let home: URL
    private var paths: [String: [URL]] = [:]
    private var lastDiscovery = Date.distantPast
    private var tails: [URL: JSONLineTail] = [:]
    private var codex: [URL: CodexLog] = [:]
    private var cursor: [URL: CursorLog] = [:]
    private var hooks: [String: HookSession] = [:]
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private(set) var parsedLines = 0
    private(set) var bytesRead = 0

    init(home: URL) { self.home = home }

    func snapshot(rediscover: Bool = false, now: Date = Date()) -> [AgentActivity] {
        if rediscover || now.timeIntervalSince(lastDiscovery) >= 60 {
            for path in [".codex/sessions", ".cursor/projects", ".claude/projects"] {
                let enumerator = FileManager.default.enumerator(at: home.appendingPathComponent(path),
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                paths[path] = enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" } ?? []
            }
            lastDiscovery = now
        }
        let codexFiles = recent(".codex/sessions", limit: 16, now: now)
        let cursorFiles = recent(".cursor/projects", limit: 1, now: now)
        let claudeFiles = recent(".claude/projects", limit: 1, now: now)
        let hookURL = home.appendingPathComponent("Library/Application Support/AgentBeacon/events.jsonl")
        read(hookURL, reset: { self.hooks = [:] }) { text in
            guard let o = LogText.object(text), let source = o["source"] as? String,
                  let name = o["event"] as? String, let ts = o["timestamp"] as? Double else { return }
            let session = o["session"] as? String ?? "default"
            let event = HookEvent(source: source, session: session, name: name, title: o["title"] as? String ?? "",
                                  step: o["step"] as? String ?? "", code: o["code"] as? String ?? "", date: Date(timeIntervalSince1970: ts))
            let key = "\(source):\(session)"
            var state = self.hooks[key] ?? HookSession(last: event, title: "\(source) 任务")
            state.consume(event); self.hooks[key] = state
        }
        hooks = hooks.filter { $0.value.last.date > now.addingTimeInterval(-86400) }
        var result = hooks.values.map { $0.activity(now: now) }
        for (url, modified) in codexFiles {
            var state = codex[url] ?? CodexLog()
            read(url, reset: { state = CodexLog() }) { state.consume($0, formatter: self.formatter) }
            codex[url] = state
            if let activity = state.activity(url: url, modified: modified, now: now) { result.append(activity) }
        }
        if !result.contains(where: { $0.source == "Cursor" }), let (url, modified) = cursorFiles.first {
            var state = cursor[url] ?? CursorLog()
            read(url, reset: { state = CursorLog() }) { state.consume($0) }
            cursor[url] = state
            result.append(AgentActivity(id: "cursor-fallback", source: "Cursor", title: state.title, step: state.step,
                                        state: .recent, updated: modified, completedAt: nil, log: state.log))
        }
        if !result.contains(where: { $0.source == "Claude Code" }), let (_, modified) = claudeFiles.first {
            result.append(AgentActivity(id: "claude-fallback", source: "Claude Code", title: "最近的 Claude Code 会话",
                                        step: "接入后可显示实时状态", state: .recent, updated: modified, completedAt: nil, log: []))
        }
        let retained = Set(codexFiles.map(\.0) + cursorFiles.map(\.0) + [hookURL])
        tails = tails.filter { retained.contains($0.key) }
        codex = codex.filter { retained.contains($0.key) }
        cursor = cursor.filter { retained.contains($0.key) }
        return result.sorted {
            if ($0.state == .working) != ($1.state == .working) { return $0.state == .working }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.id < $1.id
        }
    }

    private func recent(_ key: String, limit: Int, now: Date) -> [(URL, Date)] {
        (paths[key] ?? []).compactMap { url -> (URL, Date)? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let date = attributes[.modificationDate] as? Date, date > now.addingTimeInterval(-86400) else { return nil }
            return (url, date)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    private func read(_ url: URL, reset: () -> Void, line: (String) -> Void) {
        let tail = tails[url] ?? JSONLineTail(); tails[url] = tail
        let previous = tail.bytesRead
        tail.consume(url, reset: reset) { self.parsedLines += 1; line($0) }
        bytesRead += tail.bytesRead - previous
    }
}

// FSEvents supplies changes even for new nested session folders. The cheap timer in
// Monitor remains a fallback for dropped notifications and time-based expiry.
final class ActivityFileObserver {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var needsDiscovery = false
    private let roots: [String]
    private let changed: (Bool) -> Void

    init(home: URL, changed: @escaping (Bool) -> Void) {
        roots = [".codex/sessions", ".cursor/projects", ".claude/projects", ".cursor/hooks.json",
                 ".claude/settings.json", "Library/Application Support/AgentBeacon/events.jsonl"]
            .map { Self.normalizedPath(home.appendingPathComponent($0).path) }
        self.changed = changed
        let watched = Set(roots.map { path -> String in
            var url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            while url.path != "/" {
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { break }
                url.deleteLastPathComponent()
            }
            return url.path
        })
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info = info else { return }
            let observer = Unmanaged<ActivityFileObserver>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            for index in 0..<count { observer.event(path: paths[index], flags: flags[index]) }
        }, &context, Array(watched) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }

    // Normalize existing ancestors too: FSEvents can report /private/var while
    // Foundation uses /var, and a removed file cannot resolve its own symlinks.
    private static func normalizedPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
            missing.append(url.lastPathComponent); url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for component in missing.reversed() { url.appendPathComponent(component) }
        return url.path
    }

    private func event(path: String, flags: FSEventStreamEventFlags) {
        let path = Self.normalizedPath(path)
        let dropped = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
        guard dropped || roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { return }
        let relevant = dropped || path.hasSuffix(".jsonl") || path.hasSuffix("hooks.json") || path.hasSuffix("settings.json") || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard relevant else { return }
        needsDiscovery = needsDiscovery || dropped || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir) != 0
        // Coalesce the burst without delaying indefinitely while a log is streaming.
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = nil
            let discover = self.needsDiscovery; self.needsDiscovery = false
            self.changed(discover)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit {
        pending?.cancel()
        if let stream = stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
