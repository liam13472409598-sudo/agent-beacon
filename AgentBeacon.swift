import AppKit
import Foundation
import SwiftUI

enum AgentState: String {
    case working = "工作中"
    case recent = "已完成"
    case waiting = "等待中"
    case unavailable = "未接入"

    var color: Color {
        switch self {
        case .working: return .green
        case .recent: return .blue
        case .waiting: return .orange
        case .unavailable: return .secondary
        }
    }
}

struct AgentActivity: Identifiable {
    let id: String
    let source: String
    let title: String
    let step: String
    let state: AgentState
    let updated: Date
    let completedAt: Date?
    let log: [ActivityLine]
}

struct ActivityLine: Identifiable {
    enum Kind { case text, code }
    let id = UUID()
    let kind: Kind
    let value: String
    let date: Date
}

struct HookEvent {
    let source: String
    let session: String
    let name: String
    let title: String
    let step: String
    let code: String
    let date: Date
}

final class Monitor: ObservableObject {
    @Published var activities: [AgentActivity] = []
    @Published var cursorConnected = false
    @Published var claudeConnected = false
    @Published var message = ""
    @Published var completionNoticeUntil: Date = .distantPast

    private var timer: Timer?
    private let launchedAt = Date()
    private var seenCompletions = Set<String>()
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var workingCount: Int { activities.filter { $0.state == .working }.count }

    func refresh() {
        let home = self.home
        DispatchQueue.global(qos: .utility).async {
            let codex = Self.codexActivities(at: home)
            let hooks = Self.hookActivities(at: home)
            let cursor = Self.cursorFallback(at: home)
            let claude = Self.claudeFallback(at: home)
            var all = codex + hooks
            if !hooks.contains(where: { $0.source == "Cursor" }) { all += cursor }
            if !hooks.contains(where: { $0.source == "Claude Code" }) { all += claude }
            all.sort { lhs, rhs in
                if lhs.state == .working && rhs.state != .working { return true }
                if rhs.state == .working && lhs.state != .working { return false }
                return lhs.updated > rhs.updated
            }
            let cursorConfig = home.appendingPathComponent(".cursor/hooks.json")
            let claudeConfig = home.appendingPathComponent(".claude/settings.json")
            let cursorConnected = Self.containsBeaconHook(cursorConfig)
            let claudeConnected = Self.containsBeaconHook(claudeConfig)
            DispatchQueue.main.async {
                for item in all {
                    if let completedAt = item.completedAt, completedAt > self.launchedAt,
                       completedAt > Date().addingTimeInterval(-15),
                       !self.seenCompletions.contains("\(item.id):\(completedAt.timeIntervalSince1970)") {
                        self.seenCompletions.insert("\(item.id):\(completedAt.timeIntervalSince1970)")
                        self.completionNoticeUntil = Date().addingTimeInterval(8)
                    }
                }
                self.activities = Array(all.prefix(12))
                self.cursorConnected = cursorConnected
                self.claudeConnected = claudeConnected
            }
        }
    }

    func connect(_ source: String) {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("install_hooks.py") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [resource.path, source]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            message = task.terminationStatus == 0 ? "已接入\(source == "cursor" ? " Cursor" : " Claude Code")" : "接入失败：\(result)"
        } catch { message = "接入失败：\(error.localizedDescription)" }
        refresh()
    }

    private static func containsBeaconHook(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("agent_beacon_hook.py")
    }

    private static func recentFiles(root: URL, suffix: String, limit: Int = 24) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == suffix {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  let date = values.contentModificationDate, date > Date().addingTimeInterval(-24 * 3600) else { continue }
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func lines(in url: URL, maxBytes: UInt64 = 900_000) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: .newlines)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func short(_ text: String, length: Int = 80) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(length))
    }

    private static func codeSnippet(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8)
        return String(lines.joined(separator: "\n").prefix(520)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callCode(_ payload: [String: Any]) -> String {
        let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
        if let data = raw.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["cmd", "command", "code", "input", "path"] {
                if let value = object[key] as? String { return codeSnippet(value) }
            }
        }
        return codeSnippet(raw)
    }

    private static func recentLog(_ lines: [ActivityLine]) -> [ActivityLine] {
        Array(lines.suffix(6))
    }

    private static func contentText(_ value: Any?) -> String {
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private static func codexActivities(at home: URL) -> [AgentActivity] {
        let root = home.appendingPathComponent(".codex/sessions")
        return recentFiles(root: root, suffix: "jsonl", limit: 16).compactMap { url in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var title = "Codex 任务"
            var step = "正在思考"
            var started: Date?
            var ended: Date?
            var lastEvent: Date = .distantPast
            var sawTask = false
            var log: [ActivityLine] = []
            for line in lines(in: url, maxBytes: 8_000_000) {
                guard let row = object(line), let payload = row["payload"] as? [String: Any] else { continue }
                let date = formatter.date(from: row["timestamp"] as? String ?? "") ?? .distantPast
                let outerType = row["type"] as? String ?? ""
                let type = payload["type"] as? String ?? ""
                if outerType == "event_msg" {
                    if type == "task_started" {
                        started = date; ended = nil; sawTask = true; step = "开始处理任务"; log = []
                    }
                    if type == "task_complete" || type == "turn_aborted" {
                        ended = date; step = type == "task_complete" ? "已完成" : "已中止"
                        log.append(ActivityLine(kind: .text, value: step, date: date))
                    }
                }
                if outerType == "response_item" {
                    if type == "message", payload["role"] as? String == "user" {
                        let value = contentText(payload["content"])
                        if !value.isEmpty && !value.hasPrefix("<") && !value.hasPrefix("[{") { title = short(value) }
                    }
                    if type == "message", payload["role"] as? String == "assistant", payload["phase"] as? String == "commentary" {
                        let value = contentText(payload["content"])
                        if !value.isEmpty {
                            step = short(value)
                            log.append(ActivityLine(kind: .text, value: short(value, length: 220), date: date))
                        }
                    }
                    if type == "message", payload["role"] as? String == "assistant", payload["phase"] as? String == "final" {
                        let value = contentText(payload["content"])
                        if !value.isEmpty { log.append(ActivityLine(kind: .text, value: short(value, length: 220), date: date)) }
                    }
                    if type == "function_call" || type == "custom_tool_call" {
                        let name = payload["name"] as? String ?? "工具"
                        step = "调用 \(short(name, length: 45))"
                        let code = callCode(payload)
                        if !code.isEmpty { log.append(ActivityLine(kind: .code, value: code, date: date)) }
                        else { log.append(ActivityLine(kind: .text, value: step, date: date)) }
                    }
                }
                if date > lastEvent { lastEvent = date }
            }
            guard sawTask else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? lastEvent
            let fresh = modified > Date().addingTimeInterval(-20 * 60)
            let working = started != nil && ended == nil && fresh
            return AgentActivity(id: url.lastPathComponent, source: "Codex", title: title,
                                 step: working ? step : "最近一次任务已结束", state: working ? .working : .recent,
                                 updated: modified, completedAt: ended, log: recentLog(log))
        }
    }

    private static func hookActivities(at home: URL) -> [AgentActivity] {
        let url = home.appendingPathComponent("Library/Application Support/AgentBeacon/events.jsonl")
        var groups: [String: [HookEvent]] = [:]
        for line in lines(in: url, maxBytes: 1_500_000) {
            guard let o = object(line), let source = o["source"] as? String, let name = o["event"] as? String,
                  let ts = o["timestamp"] as? Double else { continue }
            let session = o["session"] as? String ?? "default"
            let event = HookEvent(source: source, session: session, name: name, title: o["title"] as? String ?? "",
                                  step: o["step"] as? String ?? "", code: o["code"] as? String ?? "",
                                  date: Date(timeIntervalSince1970: ts))
            groups["\(source):\(session)", default: []].append(event)
        }
        return groups.values.compactMap { events in
            guard let last = events.last, last.date > Date().addingTimeInterval(-24 * 3600) else { return nil }
            let title = events.reversed().first(where: { !$0.title.isEmpty })?.title ?? "\(last.source) 任务"
            let stopNames = ["stop", "sessionEnd", "Stop", "SessionEnd"]
            let started = events.reversed().first(where: { ["beforeSubmitPrompt", "UserPromptSubmit", "sessionStart", "SessionStart"].contains($0.name) })
            let stopped = events.reversed().first(where: { stopNames.contains($0.name) })
            let working = started != nil && (stopped == nil || started!.date > stopped!.date) && last.date > Date().addingTimeInterval(-20 * 60)
            let step = last.step.isEmpty ? (working ? "正在处理任务" : "任务已结束") : last.step
            let log = events.suffix(10).compactMap { event -> ActivityLine? in
                if !event.code.isEmpty { return ActivityLine(kind: .code, value: codeSnippet(event.code), date: event.date) }
                if !event.step.isEmpty { return ActivityLine(kind: .text, value: event.step, date: event.date) }
                return nil
            }
            let completedAt = stopped?.name == "stop" || stopped?.name == "Stop" ? stopped?.date : nil
            return AgentActivity(id: "\(last.source)-\(last.session)", source: last.source, title: title, step: step,
                                 state: working ? .working : .recent, updated: last.date,
                                 completedAt: working ? nil : completedAt, log: recentLog(log))
        }
    }

    private static func cursorFallback(at home: URL) -> [AgentActivity] {
        let root = home.appendingPathComponent(".cursor/projects")
        guard let url = recentFiles(root: root, suffix: "jsonl", limit: 1).first else { return [] }
        var title = "Cursor Agent"
        var step = "最近有 Agent 会话"
        var log: [ActivityLine] = []
        for line in lines(in: url, maxBytes: 350_000) {
            guard let o = object(line), let message = o["message"] as? [String: Any] else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if o["role"] as? String == "user", let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String { title = short(text) }
            if o["role"] as? String == "assistant" {
                if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                    step = "调用 \(short(tool["name"] as? String ?? "工具"))"
                    let input = tool["input"] as? [String: Any] ?? [:]
                    let code = ["command", "cmd", "code", "file_path"].compactMap { input[$0] as? String }.first ?? ""
                    if !code.isEmpty { log.append(ActivityLine(kind: .code, value: codeSnippet(code), date: .distantPast)) }
                } else if let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                    step = short(text)
                    log.append(ActivityLine(kind: .text, value: short(text, length: 220), date: .distantPast))
                }
            }
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return [AgentActivity(id: "cursor-fallback", source: "Cursor", title: title, step: step, state: .recent,
                              updated: date, completedAt: nil, log: recentLog(log))]
    }

    private static func claudeFallback(at home: URL) -> [AgentActivity] {
        let root = home.appendingPathComponent(".claude/projects")
        guard let url = recentFiles(root: root, suffix: "jsonl", limit: 1).first else { return [] }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return [AgentActivity(id: "claude-fallback", source: "Claude Code", title: "最近的 Claude Code 会话",
                              step: "接入后可显示实时状态", state: .recent, updated: date,
                              completedAt: nil, log: [])]
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @State private var showSetup = false
    @AppStorage("menuBarTheme") private var menuBarTheme = "dark"
    private let background = Color(red: 0.012, green: 0.022, blue: 0.035)
    private let panel = Color(red: 0.032, green: 0.058, blue: 0.083)
    private let muted = Color(red: 0.34, green: 0.45, blue: 0.53)
    private let green = Color(red: 0.30, green: 0.53, blue: 0.64)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.99, green: 0.38, blue: 0.36)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.98, green: 0.76, blue: 0.3)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.37, green: 0.8, blue: 0.48)).frame(width: 10, height: 10)
                Spacer()
                Text("agent-beacon — live").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(muted).help("刷新")
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(panel)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text("❯").foregroundStyle(green)
                    Text("agent-beacon status --watch").foregroundStyle(Color(red: 0.69, green: 0.76, blue: 0.81))
                }.font(.system(size: 12, design: .monospaced))
                HStack(spacing: 8) {
                    Circle().fill(monitor.workingCount > 0 ? green : muted).frame(width: 6, height: 6)
                    Text(monitor.workingCount > 0 ? "loading · \(monitor.workingCount) agent\(monitor.workingCount == 1 ? "" : "s")" : "all agents idle")
                        .foregroundStyle(monitor.workingCount > 0 ? green : muted)
                    if monitor.completionNoticeUntil > Date() {
                        Text("✓ work done!").foregroundStyle(green)
                    }
                }.font(.system(size: 11, design: .monospaced))
            }.padding(.horizontal, 18).padding(.vertical, 16)

            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if monitor.activities.isEmpty {
                        Text("$ waiting for agent events_")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                            .padding(.vertical, 30)
                    }
                    ForEach(monitor.activities) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 7) {
                                Text("●").foregroundStyle(item.state == .working ? green : muted)
                                Text(item.source.lowercased().replacingOccurrences(of: " ", with: "-"))
                                    .foregroundStyle(green)
                                Text("/ \(item.state == .working ? "loading" : "done")").foregroundStyle(muted)
                                Spacer()
                                Text(item.updated, style: .relative).foregroundStyle(muted)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            Text(item.title).font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.73, green: 0.80, blue: 0.84)).lineLimit(2)
                            if item.log.isEmpty {
                                Text("# \(item.step)").font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(muted).lineLimit(2)
                            } else {
                                ForEach(item.log) { line in
                                    if line.kind == .code {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("$").foregroundStyle(green)
                                            Text(line.value).foregroundStyle(Color(red: 0.62, green: 0.72, blue: 0.78))
                                                .textSelection(.enabled).lineLimit(6)
                                        }
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(9)
                                        .background(background, in: RoundedRectangle(cornerRadius: 7))
                                    } else {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("#").foregroundStyle(green)
                                            Text(line.value).foregroundStyle(muted).lineLimit(3)
                                        }.font(.system(size: 11, design: .monospaced))
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(14)
            }.frame(maxHeight: 460)

            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            if showSetup {
                VStack(alignment: .leading, spacing: 9) {
                    Text("# menu bar appearance").font(.system(size: 11, design: .monospaced)).foregroundStyle(green)
                    Picker("菜单栏配色", selection: $menuBarTheme) {
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.bottom, 5)
                    Text("# integrations").font(.system(size: 11, design: .monospaced)).foregroundStyle(green)
                    HStack {
                        Text("Cursor Agent").font(.system(size: 11, design: .monospaced))
                        Spacer()
                        if monitor.cursorConnected { Text("connected").foregroundStyle(green) }
                        else { Button("接入") { monitor.connect("cursor") } }
                    }
                    HStack {
                        Text("Claude Code").font(.system(size: 11, design: .monospaced))
                        Spacer()
                        if monitor.claudeConnected { Text("connected").foregroundStyle(green) }
                        else { Button("接入") { monitor.connect("claude") } }
                    }
                    Text("Claude 桌面聊天目前没有任务事件接口；Claude Code 可接入。")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    if !monitor.message.isEmpty { Text(monitor.message).font(.system(size: 10)).foregroundStyle(muted) }
                }.foregroundStyle(Color.white.opacity(0.9)).padding(.horizontal, 18).padding(.vertical, 12)
                Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            }
            HStack {
                Button(showSetup ? "收起设置" : "外观与接入") { showSetup.toggle() }.buttonStyle(.plain)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 430)
        .background(background)
        .preferredColorScheme(.dark)
    }
}

enum StatusPixelAnimation {
    enum Mode { case loading, done }
    enum Palette { case lightBar, darkBar }

    private static let glyphs: [Character: [String]] = [
        "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "o": [".....", ".###.", "#...#", "#...#", "#...#", ".###.", "....."],
        "a": [".....", ".###.", "....#", ".####", "#...#", ".####", "....."],
        "d": ["....#", "....#", ".####", "#...#", "#...#", ".####", "....."],
        "i": ["..#..", ".....", ".##..", "..#..", "..#..", ".###.", "....."],
        "n": [".....", "####.", "#...#", "#...#", "#...#", "#...#", "....."],
        "g": [".....", ".####", "#...#", "#...#", ".####", "....#", ".###."],
        "w": [".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#.", "....."],
        "r": [".....", "#.##.", "##..#", "#....", "#....", "#....", "....."],
        "k": ["#....", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "....."],
        "e": [".....", ".###.", "#...#", "#####", "#....", ".####", "....."],
        "!": ["..#..", "..#..", "..#..", "..#..", ".....", "..#..", "....."],
        "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "#....", "####.", "....#", "....#", "####."],
        "6": [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]
    private static let pitch = 1.6
    private static let dotSize = 1.28

    static func loading(frame: Int, count: Int, palette: Palette) -> NSImage {
        render("loading · \(count)", frame: frame, mode: .loading, palette: palette)
    }

    static func done(frame: Int, count: Int, palette: Palette) -> NSImage {
        let text = count > 0 ? "work done! · \(count) loading" : "work done!"
        return render(text, frame: frame, mode: .done, palette: palette)
    }

    static func pixels(for text: String) -> [(Int, Int)] {
        var points: [(Int, Int)] = []
        for (letterIndex, character) in text.lowercased().enumerated() {
            guard let glyph = glyphs[character] else { continue }
            for (row, pattern) in glyph.enumerated() {
                for (column, pixel) in pattern.enumerated() where pixel == "#" {
                    points.append((letterIndex * 6 + column, row))
                }
            }
        }
        return points
    }

    static func brightness(column: Int, row: Int, columnCount: Int, frame: Int, mode: Mode) -> Double {
        switch mode {
        case .loading:
            let sweep = (Double(frame) * 1.7).truncatingRemainder(dividingBy: Double(columnCount + 20)) - 10
            let crest = sweep + 2.1 * sin(Double(row) * 0.8 + Double(frame) * 0.08)
            let distance = (Double(column) - crest) / 7.0
            return 0.18 + 0.82 * exp(-distance * distance / 2)
        case .done:
            let ripple = (sin(Double(frame) * 0.34 - Double(row) * 0.5) + 1) / 2
            return 0.06 + 0.94 * pow(ripple, 1.5)
        }
    }

    private static func render(_ text: String, frame: Int, mode: Mode, palette: Palette) -> NSImage {
        let columnCount = max(1, text.count * 6 - 1)
        let width = Double(columnCount) * pitch + 4
        let points = pixels(for: text)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            for (column, row) in points {
                let brightness = brightness(column: column, row: row, columnCount: columnCount,
                                            frame: frame, mode: mode)
                let base: NSColor
                let crest: NSColor
                switch palette {
                case .lightBar:
                    base = NSColor(calibratedRed: 0.40, green: 0.47, blue: 0.51, alpha: 1)
                    crest = NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.30, alpha: 1)
                case .darkBar:
                    base = NSColor(calibratedRed: 0.26, green: 0.34, blue: 0.39, alpha: 1)
                    crest = NSColor(calibratedRed: 0.68, green: 0.82, blue: 0.87, alpha: 1)
                }
                (base.blended(withFraction: brightness, of: crest) ?? base).setFill()
                NSRect(x: 2 + Double(column) * pitch,
                       y: 3.3 + Double(6 - row) * pitch,
                       width: dotSize, height: dotSize).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = text
        return image
    }
}

enum MenuBarPaletteSelection {
    static func resolve(_ selection: String?) -> StatusPixelAnimation.Palette {
        switch selection {
        case "light": return .lightBar
        default: return .darkBar
        }
    }
}

#if !AGENT_BEACON_TEST
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private var timer: Timer?
    private var frameIndex = 0
    private var displayedMode = ""
    private var lastCompletionNoticeUntil: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !["light", "dark"].contains(UserDefaults.standard.string(forKey: "menuBarTheme") ?? "") {
            UserDefaults.standard.set("dark", forKey: "menuBarTheme")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Agent 哨站")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }
        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        popover.behavior = .transient
        updateTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in self?.updateTitle() }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let palette = selectedPalette()
        let mode = monitor.completionNoticeUntil > Date() ? "done" : (monitor.workingCount > 0 ? "loading" : "idle")
        if mode != displayedMode || monitor.completionNoticeUntil > lastCompletionNoticeUntil {
            frameIndex = 0
            displayedMode = mode
            lastCompletionNoticeUntil = monitor.completionNoticeUntil
        }
        if mode == "done" {
            button.image = StatusPixelAnimation.done(frame: frameIndex, count: monitor.workingCount, palette: palette)
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Agent 任务完成"
            button.setAccessibilityLabel("work done! Agent 任务完成")
            frameIndex += 1
        } else if mode == "loading" {
            button.image = StatusPixelAnimation.loading(frame: frameIndex, count: monitor.workingCount, palette: palette)
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "\(monitor.workingCount) 个 Agent 正在工作"
            button.setAccessibilityLabel("loading · \(monitor.workingCount)")
            frameIndex += 1
        } else {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Agent 哨站")
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Agent 哨站：暂无运行中任务"
            button.setAccessibilityLabel("Agent 哨站：暂无运行中任务")
        }
    }

    private func selectedPalette() -> StatusPixelAnimation.Palette {
        MenuBarPaletteSelection.resolve(UserDefaults.standard.string(forKey: "menuBarTheme"))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { monitor.refresh(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}

@main
struct AgentBeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
#endif
