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

struct AgentActivity: Identifiable, Equatable {
    let id: String
    let source: String
    let title: String
    let step: String
    let state: AgentState
    let updated: Date
    let completedAt: Date?
    let log: [ActivityLine]
}

struct ActivityLine: Identifiable, Equatable {
    enum Kind: Equatable { case text, code }
    let id = UUID()
    let kind: Kind
    let value: String
    let date: Date
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.value == rhs.value && lhs.date == rhs.date
    }
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

struct UsageWindow {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var name: String {
        guard let minutes = durationMinutes else { return "额度" }
        if minutes == 10080 { return "week" }
        return minutes >= 1440 && minutes % 1440 == 0 ? "\(minutes / 1440)d" : "\(minutes / 60)h"
    }
    func isCurrent(at date: Date) -> Bool { resetsAt.map { $0 > date } ?? true }
}

struct UsageSnapshot {
    let source: String
    let windows: [UsageWindow]
    let fetchedAt: Date

    func window(for selection: String, at date: Date = Date()) -> UsageWindow? {
        guard date.timeIntervalSince(fetchedAt) < 300 else { return nil }
        let minutes = selection == "5h" ? 300 : 10080
        let match = windows.first { $0.durationMinutes == minutes }
        return match?.isCurrent(at: date) == true ? match : nil
    }
}

final class Monitor: ObservableObject {
    @Published var activities: [AgentActivity] = []
    @Published var cursorConnected = false
    @Published var claudeConnected = false
    @Published var message = ""
    @Published var completionNoticeUntil: Date = .distantPast
    @Published var codexUsage: UsageSnapshot?
    @Published var usageError = "正在读取 Codex 额度…"

    private var timer: Timer?
    private let launchedAt = Date()
    private var seenCompletions = Set<String>()
    private var usageRefreshInProgress = false
    private var lastUsageRefresh: Date = .distantPast
    private let home: URL
    private let store: ActivityStore
    private let activityQueue = DispatchQueue(label: "local.agentbeacon.activity-reader", qos: .utility)
    private var fileObserver: ActivityFileObserver?
    private var activityRefreshInProgress = false
    private var activityRefreshPending = false
    private var needsDiscovery = true

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.store = ActivityStore(home: home)
        fileObserver = ActivityFileObserver(home: home) { [weak self] rediscover in
            self?.refresh(rediscover: rediscover)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var workingCount: Int { activities.filter { $0.state == .working }.count }

    func refresh(rediscover: Bool = false) {
        refreshUsage()
        needsDiscovery = needsDiscovery || rediscover
        guard !activityRefreshInProgress else { activityRefreshPending = true; return }
        activityRefreshInProgress = true
        let discover = needsDiscovery
        needsDiscovery = false
        let home = self.home
        activityQueue.async { [weak self] in
            guard let self = self else { return }
            let all = self.store.snapshot(rediscover: discover)
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
                let displayed = Array(all.prefix(12))
                if self.activities != displayed { self.activities = displayed }
                if self.cursorConnected != cursorConnected { self.cursorConnected = cursorConnected }
                if self.claudeConnected != claudeConnected { self.claudeConnected = claudeConnected }
                self.activityRefreshInProgress = false
                if self.activityRefreshPending {
                    self.activityRefreshPending = false
                    self.refresh()
                }
            }
        }
    }

    func refreshUsage(force: Bool = false) {
        guard !usageRefreshInProgress,
              force || Date().timeIntervalSince(lastUsageRefresh) >= 60 else { return }
        usageRefreshInProgress = true
        lastUsageRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.readCodexUsage()
            DispatchQueue.main.async {
                self.codexUsage = result.0
                self.usageError = result.1
                self.usageRefreshInProgress = false
            }
        }
    }

    private static func readCodexUsage() -> (UsageSnapshot?, String) {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("codex_usage.py") else {
            return (nil, "额度读取程序缺失")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [helper.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return (nil, "Codex 额度读取失败")
            }
            if let error = object["error"] as? String { return (nil, error) }
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let value = object[key] as? [String: Any],
                      let used = value["usedPercent"] as? Int else { return nil }
                let reset = (value["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return UsageWindow(usedPercent: used,
                                   durationMinutes: value["windowDurationMins"] as? Int,
                                   resetsAt: reset)
            }
            guard !windows.isEmpty else { return (nil, "Codex 未返回额度") }
            return (UsageSnapshot(source: "Codex", windows: windows, fetchedAt: Date()), "")
        } catch {
            return (nil, "Codex 额度读取失败")
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

}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @State private var showSetup = false
    @AppStorage("menuBarTheme") private var menuBarTheme = "dark"
    @AppStorage("idleUsageSource") private var idleUsageSource = "auto"
    @AppStorage("usageWindow") private var usageWindow = "week"
    @AppStorage("usageTextEffect") private var usageTextEffect = "shimmer"
    private let background = Color(red: 0.012, green: 0.022, blue: 0.035)
    private let panel = Color(red: 0.032, green: 0.058, blue: 0.083)
    private let muted = Color(red: 0.34, green: 0.45, blue: 0.53)
    private let green = Color(red: 0.30, green: 0.53, blue: 0.64)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                BrandIconView(workingCount: monitor.workingCount,
                              completionNoticeUntil: monitor.completionNoticeUntil)
                Spacer()
                Text("agent-beacon — live").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                Spacer()
                Button { monitor.refresh(); monitor.refreshUsage(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(muted).help("刷新")
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
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
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("$ usage --remaining").foregroundStyle(green)
                    Spacer()
                    Picker("额度周期", selection: $usageWindow) {
                        Text("5 小时").tag("5h")
                        Text("week").tag("week")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                if let usage = monitor.codexUsage, let selected = usage.window(for: usageWindow) {
                    HStack(spacing: 10) {
                        Text("Codex").foregroundStyle(Color.white.opacity(0.9))
                        Text("\(selected.remainingPercent)% remaining · \(selected.name)")
                            .foregroundStyle(green)
                        Spacer()
                        Text(usage.fetchedAt, style: .relative).foregroundStyle(muted)
                    }
                    ForEach(usage.windows.indices, id: \.self) { index in
                        let window = usage.windows[index]
                        HStack(spacing: 8) {
                            Text(window.name).lineLimit(1).frame(width: 36, alignment: .leading)
                            Text("\(window.remainingPercent)% 剩余")
                            if let reset = window.resetsAt {
                                Text("· \(reset, style: .relative)重置")
                            }
                        }.foregroundStyle(muted)
                    }
                } else {
                    Text("Codex · \(monitor.usageError.isEmpty ? "额度已过期，等待刷新" : monitor.usageError)")
                        .foregroundStyle(muted)
                }
                Text("Claude Code 和 Cursor 额度暂不可读取")
                    .foregroundStyle(muted)
                Picker("额度文字效果", selection: $usageTextEffect) {
                    ForEach(UsageTextEffect.allCases) { effect in
                        Text(effect.title).tag(effect.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("菜单栏额度文字的像素亮度动画")
                TimelineView(.animation(minimumInterval: 0.10)) { timeline in
                    let window = monitor.codexUsage?.window(for: usageWindow)
                    let text = idleUsageSource == "claude" ? "Claude —" :
                        (idleUsageSource == "cursor" ? "Cursor —" :
                            (window.map { "Codex \($0.remainingPercent)% · \($0.name)" } ?? "usage —"))
                    Image(nsImage: StatusPixelAnimation.usage(
                        text, frame: Int(timeline.date.timeIntervalSinceReferenceDate * 10),
                        effect: UsageTextEffect(rawValue: usageTextEffect) ?? .shimmer,
                        palette: .darkBar))
                        .accessibilityLabel("额度文字效果预览")
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 18).padding(.vertical, 12)

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
                    Text("# idle usage source").font(.system(size: 11, design: .monospaced)).foregroundStyle(green)
                    Picker("待机额度来源", selection: $idleUsageSource) {
                        Text("自动选择").tag("auto")
                        Text("Codex").tag("codex")
                        Text("Claude Code").tag("claude")
                        Text("Cursor").tag("cursor")
                    }
                    .pickerStyle(.menu)
                    Text("自动显示有可靠数据的 Agent；固定 Claude Code 或 Cursor 时，目前显示 —。")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
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

struct BrandIconView: View {
    let workingCount: Int
    let completionNoticeUntil: Date

    private let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.10)) { timeline in
            BrandIconFrame(icon: icon,
                           time: timeline.date.timeIntervalSinceReferenceDate,
                           working: workingCount > 0,
                           done: completionNoticeUntil > timeline.date)
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel("Agent 哨站图标")
    }
}

struct BrandIconFrame: View {
    let icon: NSImage
    let time: TimeInterval
    let working: Bool
    let done: Bool

    var body: some View {
        let pulse = (sin(time * 3.0) + 1) / 2
        let coral = Color(red: 1, green: 0.39, blue: 0.27)
        let mint = Color(red: 0.43, green: 0.91, blue: 0.75)
        ZStack {
            Circle()
                .stroke((done ? mint : coral).opacity(done ? 0.35 + 0.50 * pulse : 0.12 + 0.18 * pulse),
                        lineWidth: 1.5)
                .frame(width: 37, height: 37)
            if working && !done {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(coral, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .frame(width: 37, height: 37)
                    .rotationEffect(.degrees(time * 130))
            }
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 31, height: 31)
                .shadow(color: (done ? mint : coral).opacity(0.08 + 0.18 * pulse), radius: 3 + 2 * pulse)
        }
        .frame(width: 40, height: 40)
    }
}

enum UsageTextEffect: String, CaseIterable, Identifiable {
    case shimmer, ripple, breathe, steady
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shimmer: return "流光"
        case .ripple: return "波纹"
        case .breathe: return "呼吸"
        case .steady: return "静态"
        }
    }
}

enum StatusPixelAnimation {
    enum Mode { case loading, done, usage(UsageTextEffect) }
    enum Palette { case lightBar, darkBar }

    private static let glyphs: [Character: [String]] = [
        "c": [".....", ".####", "#....", "#....", "#....", ".####", "....."],
        "h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "....."],
        "s": [".....", ".####", "#....", ".###.", "....#", "####.", "....."],
        "u": [".....", "#...#", "#...#", "#...#", "#...#", ".####", "....."],
        "x": [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
        "%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
        "—": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
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

    static func usage(_ text: String, frame: Int, effect: UsageTextEffect, palette: Palette) -> NSImage {
        render(text, frame: frame, mode: .usage(effect), palette: palette)
    }

    static func idle(frame: Int, palette: Palette) -> NSImage {
        let prompt: NSColor = palette == .lightBar
            ? NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.25, alpha: 1)
            : NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.95, alpha: 1)
        let cursor = NSColor(calibratedRed: 1, green: 0.37, blue: 0.25,
                             alpha: idleBrightness(frame: frame))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 2.5, y: 14.1))
            chevron.line(to: NSPoint(x: 8.2, y: 9))
            chevron.line(to: NSPoint(x: 2.5, y: 3.9))
            chevron.lineWidth = 2.4
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            prompt.setStroke()
            chevron.stroke()
            let cursorBlock = NSBezierPath(roundedRect: NSRect(x: 11.5, y: 3.8, width: 3.8, height: 10.4),
                                           xRadius: 0.9, yRadius: 0.9)
            cursor.setFill()
            cursorBlock.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Agent 哨站"
        return image
    }

    static func idleBrightness(frame: Int) -> Double {
        let pulse = (sin(Double(frame) * 0.24) + 1) / 2
        return 0.55 + 0.45 * pow(pulse, 1.8)
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
        case .usage(let effect):
            let phase = Double(frame % 60) / 60 * 2 * Double.pi
            switch effect {
            case .shimmer:
                let sweep = Double(frame % 60) / 60 * Double(columnCount + 36) - 18
                let distance = (Double(column) - sweep - Double(row) * 0.65) / 9
                return 0.30 + 0.70 * exp(-distance * distance / 2)
            case .ripple:
                let wave = (cos(Double(column) * 0.15 + Double(row) * 0.65 - phase) + 1) / 2
                return 0.22 + 0.78 * pow(wave, 1.8)
            case .breathe:
                return 0.28 + 0.72 * pow((sin(phase) + 1) / 2, 1.4)
            case .steady:
                return 0.85
            }
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
        if !["auto", "codex", "claude", "cursor"].contains(UserDefaults.standard.string(forKey: "idleUsageSource") ?? "") {
            UserDefaults.standard.set("auto", forKey: "idleUsageSource")
        }
        if !["5h", "week"].contains(UserDefaults.standard.string(forKey: "usageWindow") ?? "") {
            UserDefaults.standard.set("week", forKey: "usageWindow")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.image = nil
            button.imagePosition = .noImage
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
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Agent 任务完成"
            button.setAccessibilityLabel("work done! Agent 任务完成")
            frameIndex += 1
        } else if mode == "loading" {
            button.image = StatusPixelAnimation.loading(frame: frameIndex, count: monitor.workingCount, palette: palette)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "\(monitor.workingCount) 个 Agent 正在工作"
            button.setAccessibilityLabel("loading · \(monitor.workingCount)")
            frameIndex += 1
        } else {
            button.image = nil
            button.imagePosition = .noImage
            let selection = UserDefaults.standard.string(forKey: "idleUsageSource") ?? "auto"
            let usageWindow = UserDefaults.standard.string(forKey: "usageWindow") ?? "week"
            let window = ["auto", "codex"].contains(selection) ? monitor.codexUsage?.window(for: usageWindow) : nil
            let label: String
            switch selection {
            case "claude": label = "Claude —"
            case "cursor": label = "Cursor —"
            case "codex": label = window.map { "Codex \($0.remainingPercent)% · \($0.name)" } ?? "Codex —"
            default: label = window.map { "Codex \($0.remainingPercent)% · \($0.name)" } ?? "usage —"
            }
            let effect = UsageTextEffect(rawValue: UserDefaults.standard.string(forKey: "usageTextEffect") ?? "") ?? .shimmer
            button.image = StatusPixelAnimation.usage(label, frame: frameIndex, effect: effect, palette: palette)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = ["claude", "cursor"].contains(selection)
                ? "\(selection == "claude" ? "Claude Code" : "Cursor") 订阅额度暂不可读取"
                : (window == nil ? "Agent 哨站：\(monitor.usageError.isEmpty ? "所选周期暂无最新额度" : monitor.usageError)" : "Codex \(usageWindow) 订阅额度剩余")
            button.setAccessibilityLabel("Agent 哨站：\(label)")
            frameIndex += 1
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
