import Foundation
import SwiftUI

struct UsageTotals {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var cost = 0.0
    var tokens: Int { input + output + cacheWrite + cacheRead }
    static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead, cost: a.cost + b.cost)
    }
}

struct RateLimit: Identifiable {
    var id: String { name }
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
}

/// Reads local CLI logs (Claude Code ~/.claude/projects, Codex ~/.codex/sessions). Nothing leaves the Mac.
final class AIUsageService: ObservableObject {
    static let shared = AIUsageService()

    @Published var claudeToday = UsageTotals()
    @Published var claudeBlock = UsageTotals()      // current 5-hour window
    @Published var claudeBlockStart: Date?
    @Published var claudeWeek = UsageTotals()
    @Published var codexToday = UsageTotals()
    @Published var codexWeek = UsageTotals()
    @Published var codexLimits: [RateLimit] = []
    @Published var lastTurnCost: Double?
    @Published var updated: Date?
    private var timer: Timer?
    private var alerted = Set<String>()

    // Approximate public list prices, USD per million tokens (input, output). Cache write = 1.25×, read = 0.1× input.
    static let prices: [(String, Double, Double)] = [
        ("opus-4-5", 5, 25), ("opus-4-6", 5, 25), ("opus", 15, 75), ("sonnet", 3, 15), ("haiku-4-5", 1, 5), ("haiku", 0.8, 4),
        ("gpt-5", 1.25, 10), ("o3", 2, 8), ("o4-mini", 1.1, 4.4), ("gpt-4.1", 2, 8),
    ]

    static func price(_ model: String) -> (Double, Double) {
        let m = model.lowercased()
        return prices.first { m.contains($0.0) }.map { ($0.1, $0.2) } ?? (3, 15)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let c = Self.scanClaude()
            let x = Self.scanCodex()
            DispatchQueue.main.async {
                self.claudeToday = c.today; self.claudeWeek = c.week; self.claudeBlock = c.block; self.claudeBlockStart = c.blockStart
                self.codexToday = x.today; self.codexWeek = x.week; self.codexLimits = x.limits
                self.updated = Date()
                self.checkBudgets()
            }
        }
    }

    private func checkBudgets() {
        let cb = Prefs.int(Prefs.Key.claudeTokenBudget)
        if cb > 0 { alertIfNeeded("claude", Double(claudeBlock.tokens) / Double(cb)) }
        let xb = Prefs.int(Prefs.Key.codexTokenBudget)
        if xb > 0 { alertIfNeeded("codex", Double(codexToday.tokens) / Double(xb)) }
        for l in codexLimits { alertIfNeeded("codex-\(l.name)", l.usedPercent / 100) }
    }

    private func alertIfNeeded(_ name: String, _ frac: Double) {
        for t in [0.8, 0.95] where frac >= t {
            let key = "\(name)-\(t)-\(Date().dayKey)"
            guard !alerted.contains(key) else { continue }
            alerted.insert(key)
            AppState.shared.show(Island(kind: .agent, icon: "gauge.with.dots.needle.67percent", title: "\(name.capitalized) at \(Int(frac * 100))% of limit",
                                        subtitle: "Slow down or wait for the window to reset", tint: .orange, duration: 6))
        }
    }

    // MARK: Claude Code

    static func recentFiles(in root: URL, ext: String, days: Double) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-days * 86400)
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension == ext {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > cutoff { out.append(u) }
        }
        return out
    }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }

    static func claudeUsage(_ usage: [String: Any], model: String) -> UsageTotals {
        let i = usage["input_tokens"] as? Int ?? 0
        let o = usage["output_tokens"] as? Int ?? 0
        let cw = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cr = usage["cache_read_input_tokens"] as? Int ?? 0
        let p = price(model)
        let cost = (Double(i) * p.0 + Double(o) * p.1 + Double(cw) * p.0 * 1.25 + Double(cr) * p.0 * 0.1) / 1_000_000
        return UsageTotals(input: i, output: o, cacheWrite: cw, cacheRead: cr, cost: cost)
    }

    static func scanClaude() -> (today: UsageTotals, week: UsageTotals, block: UsageTotals, blockStart: Date?) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var entries: [(Date, UsageTotals)] = []
        var seen = Set<String>()
        for f in recentFiles(in: root, ext: "jsonl", days: 7) {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in s.split(separator: "\n") {
                guard line.contains("\"usage\""), let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let msg = o["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any],
                      let ts = (o["timestamp"] as? String).flatMap(parseDate) else { continue }
                let key = "\(msg["id"] as? String ?? "")|\(o["requestId"] as? String ?? "")"
                if key != "|" { guard !seen.contains(key) else { continue }; seen.insert(key) }
                entries.append((ts, claudeUsage(usage, model: msg["model"] as? String ?? "")))
            }
        }
        entries.sort { $0.0 < $1.0 }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = entries.filter { $0.0 >= startOfDay }.reduce(UsageTotals()) { $0 + $1.1 }
        let week = entries.reduce(UsageTotals()) { $0 + $1.1 }
        // 5-hour billing blocks: a block starts at the first message (floored to the hour) after a gap / block end.
        var blockStart: Date?
        for (t, _) in entries {
            if let bs = blockStart, t < bs.addingTimeInterval(5 * 3600) { continue }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: t)
            blockStart = Calendar.current.date(from: comps)
        }
        var block = UsageTotals()
        if let bs = blockStart, Date() < bs.addingTimeInterval(5 * 3600) {
            block = entries.filter { $0.0 >= bs }.reduce(UsageTotals()) { $0 + $1.1 }
        } else { blockStart = nil }
        return (today, week, block, blockStart)
    }

    /// Cost of the last assistant turn in a transcript (used by the Stop hook).
    static func lastTurnCost(transcript: String) -> Double {
        guard let s = try? String(contentsOfFile: (transcript as NSString).expandingTildeInPath, encoding: .utf8) else { return 0 }
        var total = UsageTotals()
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if o["type"] as? String == "user", let m = o["message"] as? [String: Any], m["content"] is String { break }
            if let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] { total = total + claudeUsage(u, model: m["model"] as? String ?? "") }
        }
        return total.cost
    }

    // MARK: Codex

    static func scanCodex() -> (today: UsageTotals, week: UsageTotals, limits: [RateLimit]) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var today = UsageTotals(), week = UsageTotals()
        var latestLimits: (Date, [RateLimit])?
        let startOfDay = Calendar.current.startOfDay(for: Date())
        for f in recentFiles(in: root, ext: "jsonl", days: 7) {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var model = "gpt-5"
            for line in s.split(separator: "\n") {
                guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let payload = o["payload"] as? [String: Any] else { continue }
                if let m = payload["model"] as? String { model = m }
                guard payload["type"] as? String == "token_count", let ts = (o["timestamp"] as? String).flatMap(parseDate) else { continue }
                if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                    let i = last["input_tokens"] as? Int ?? 0
                    let cached = last["cached_input_tokens"] as? Int ?? 0
                    let out = (last["output_tokens"] as? Int ?? 0) + (last["reasoning_output_tokens"] as? Int ?? 0)
                    let p = price(model)
                    let u = UsageTotals(input: i - cached, output: out, cacheWrite: 0, cacheRead: cached,
                                        cost: (Double(i - cached) * p.0 + Double(cached) * p.0 * 0.1 + Double(out) * p.1) / 1_000_000)
                    week = week + u
                    if ts >= startOfDay { today = today + u }
                }
                if let rl = payload["rate_limits"] as? [String: Any] {
                    var limits: [RateLimit] = []
                    for (k, label) in [("primary", "5h"), ("secondary", "Weekly")] {
                        guard let l = rl[k] as? [String: Any], let used = l["used_percent"] as? Double else { continue }
                        let reset = (l["resets_in_seconds"] as? Double).map { ts.addingTimeInterval($0) } ?? (l["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                        limits.append(RateLimit(name: label, usedPercent: used, resetsAt: reset))
                    }
                    if latestLimits == nil || ts > latestLimits!.0 { latestLimits = (ts, limits) }
                }
            }
        }
        return (today, week, latestLimits?.1 ?? [])
    }
}

struct AITab: View {
    @ObservedObject var u = AIUsageService.shared
    @ObservedObject var agents = AgentCenter.shared
    @AppStorage(Prefs.Key.aiSections) var sections = "claude,codex"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if sections.contains("claude") {
                Card(title: "Claude Code") {
                    usageRow("5h block", u.claudeBlock, budget: Prefs.int(Prefs.Key.claudeTokenBudget))
                    if let bs = u.claudeBlockStart { Text("Resets ") .font(.caption2).foregroundColor(.secondary) + Text(bs.addingTimeInterval(5 * 3600), style: .relative).font(.caption2).foregroundColor(.secondary) }
                    usageRow("Today", u.claudeToday)
                    usageRow("7 days", u.claudeWeek)
                    if let c = agents.lastTurnCost { Text(String(format: "Last turn: $%.3f", c)).font(.caption) }
                }
            }
            if sections.contains("codex") {
                Card(title: "Codex") {
                    ForEach(u.codexLimits) { l in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack { Text(l.name).font(.caption); Spacer(); Text("\(Int(l.usedPercent))%").font(.caption.monospacedDigit()) }
                            ProgressView(value: l.usedPercent / 100).tint(l.usedPercent > 80 ? .red : .green)
                        }
                    }
                    usageRow("Today", u.codexToday, budget: Prefs.int(Prefs.Key.codexTokenBudget))
                    usageRow("7 days", u.codexWeek)
                }
            }
            Card(title: "Agents") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if agents.events.isEmpty { Text("Install hooks in Settings › Developer to see Claude Code / Codex activity.").font(.caption).foregroundColor(.secondary) }
                        ForEach(agents.events.prefix(20)) { e in
                            HStack(alignment: .top) {
                                Image(systemName: e.icon).foregroundColor(.purple)
                                VStack(alignment: .leading) {
                                    Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text(e.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func usageRow(_ label: String, _ t: UsageTotals, budget: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Self.short(t.tokens)) · $\(String(format: "%.2f", t.cost))").font(.caption.monospacedDigit())
            }
            if budget > 0 { ProgressView(value: min(1, Double(t.tokens) / Double(budget))).tint(Double(t.tokens) / Double(budget) > 0.8 ? .red : .blue) }
        }
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}
