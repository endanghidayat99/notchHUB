import AppKit
import SwiftUI

// MARK: - Model

struct FootballMatch: Codable, Identifiable, Equatable {
    let id: String
    let date: Date
    let end: Date
    let home: String
    let away: String
    let homeScore: Int?
    let awayScore: Int?
    let league: String
    let venue: String
    let url: String

    /// Builds a match from one VEVENT's properties.
    /// SUMMARY looks like "⚽️ Persib Bandung - Bali United FC  (2-1)"; the score is only there once played.
    init?(_ p: [String: String]) {
        guard let uid = p["UID"], let start = p["DTSTART"].flatMap(FootballMatch.parseDate), let summary = p["SUMMARY"] else { return nil }
        var s = summary.replacingOccurrences(of: "⚽️", with: "").replacingOccurrences(of: "⚽", with: "").trimmingCharacters(in: .whitespaces)
        var hs: Int?, as_: Int?
        if let r = s.range(of: #"\s*\((\d+)\s*-\s*(\d+)\)\s*$"#, options: .regularExpression) {
            let nums = s[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if nums.count == 2 { hs = nums[0]; as_ = nums[1] }
            s.removeSubrange(r)
        }
        guard let dash = s.range(of: " - ") else { return nil }
        id = uid.components(separatedBy: "-").first ?? uid
        date = start
        end = p["DTEND"].flatMap(FootballMatch.parseDate) ?? start.addingTimeInterval(2 * 3600)
        home = String(s[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
        away = String(s[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        homeScore = hs
        awayScore = as_
        // DESCRIPTION = "<match url>\n<competition>"
        league = p["DESCRIPTION"]?.components(separatedBy: "\n").dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces) ?? ""
        venue = p["LOCATION"] ?? ""
        url = p["URL"] ?? ""
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s)
    }

    var isFinished: Bool { homeScore != nil && awayScore != nil }
    /// The feed refreshes every few hours, so "live" is inferred from the kickoff window.
    var isLive: Bool { !isFinished && date <= Date() && Date() < end.addingTimeInterval(30 * 60) }

    func isHome(_ team: String) -> Bool { home == team }
    func opponent(_ team: String) -> String { isHome(team) ? away : home }

    /// "W", "D" or "L" from the given team's point of view.
    func result(_ team: String) -> String? {
        guard let h = homeScore, let a = awayScore else { return nil }
        let (us, them) = isHome(team) ? (h, a) : (a, h)
        return us > them ? "W" : (us == them ? "D" : "L")
    }
}

/// Minimal RFC 5545 reader: unfolds continuation lines and returns each VEVENT's properties (VALARMs skipped).
enum ICSParser {
    static func events(_ text: String) -> [[String: String]] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(raw) }
        }
        var out: [[String: String]] = []
        var cur: [String: String]?
        var depth = 0
        for l in lines {
            if l == "BEGIN:VEVENT" { cur = [:]; depth = 0; continue }
            if l == "END:VEVENT" { if let c = cur { out.append(c) }; cur = nil; continue }
            guard cur != nil else { continue }
            if l.hasPrefix("BEGIN:") { depth += 1; continue }
            if l.hasPrefix("END:") { depth -= 1; continue }
            guard depth == 0, let colon = l.firstIndex(of: ":") else { continue }
            let name = l[..<colon].components(separatedBy: ";").first ?? ""
            let value = String(l[l.index(after: colon)...])
                .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            cur?[name] = value
        }
        return out
    }

    static func calendarName(_ text: String) -> String? {
        text.components(separatedBy: .newlines).first { $0.hasPrefix("X-WR-CALNAME:") }
            .map { String($0.dropFirst("X-WR-CALNAME:".count)).trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Service (FotMob team calendar)

/// Fixtures & results for one club from FotMob's public .ics team calendar (whole season, all competitions, one request).
final class FootballService: ObservableObject {
    static let shared = FootballService()

    @Published var matches: [FootballMatch] = []
    @Published var teamName = "Persib Bandung"
    @Published var lastUpdate: Date?
    @Published var loading = false
    @Published var error: String?

    private var timer: Timer?
    private var fetchTimer: Timer?
    private var firedKeys = Set<String>()

    enum Key {
        static let enabled = "footballEnabled"
        static let teamID = "footballFotmobTeamID"
        static let pillMode = "footballPillMode"       // 0 always, 1 match day only, 2 off
        static let reminder = "footballReminderMinutes" // 0 = off
        static let cache = "footballCalendarCache"
    }

    static let persibID = "165196"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Key.enabled: true, Key.teamID: persibID, Key.pillMode: 1, Key.reminder: 60])
    }

    var team: String { teamName }
    var teamID: String { Prefs.string(Key.teamID).isEmpty ? Self.persibID : Prefs.string(Key.teamID) }

    var next: FootballMatch? { matches.filter { !$0.isFinished && $0.end.addingTimeInterval(30 * 60) > Date() }.min { $0.date < $1.date } }
    var recent: [FootballMatch] { Array(matches.filter(\.isFinished).sorted { $0.date > $1.date }.prefix(5)) }

    func start() {
        if let cached = UserDefaults.standard.string(forKey: Key.cache) { apply(cached) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
            self?.tick()
        }
        scheduleFetch(after: 0)
        tick()
    }

    /// Refresh every 30 min, every 5 min around a match (so the final score shows up soon after).
    private func scheduleFetch(after delay: TimeInterval) {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.fetch()
            let busy = self.next.map { $0.isLive || abs($0.date.timeIntervalSinceNow) < 3600 } ?? false
            self.scheduleFetch(after: busy ? 300 : 1800)
        }
    }

    func refreshNow() { scheduleFetch(after: 0) }

    func fetch() {
        guard Prefs.bool(Key.enabled),
              let url = URL(string: "https://pub.fotmob.com/prod/pub/api/v2/calendar/team/\(teamID).ics") else { return }
        loading = true
        URLSession.shared.dataTask(with: url) { d, resp, _ in
            let text = d.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                self.loading = false
                guard let text, (resp as? HTTPURLResponse)?.statusCode == 200, text.contains("BEGIN:VCALENDAR") else {
                    if self.matches.isEmpty { self.error = L10n.lang == "id" ? "Gagal memuat jadwal" : "Couldn't load fixtures" }
                    return
                }
                self.error = nil
                self.lastUpdate = Date()
                UserDefaults.standard.set(text, forKey: Key.cache)
                self.apply(text)
                self.tick()
            }
        }.resume()
    }

    private func apply(_ text: String) {
        matches = ICSParser.events(text).compactMap(FootballMatch.init)
        if let name = ICSParser.calendarName(text), !name.isEmpty { teamName = name }
    }

    /// Team changed in Settings → drop the old club's calendar.
    func resetCache() {
        matches = []
        UserDefaults.standard.removeObject(forKey: Key.cache)
        refreshNow()
    }

    // MARK: Countdown

    /// Calendar days until kickoff (0 = today).
    static func daysUntil(_ d: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
    }

    static func countdownText(_ m: FootballMatch) -> String {
        let id = L10n.lang == "id"
        if m.isLive { return "LIVE" }
        switch daysUntil(m.date) {
        case ..<1: return id ? "Hari ini" : "Today"
        case 1: return id ? "Besok" : "Tomorrow"
        case let n: return id ? "\(n) hari lagi" : "in \(n) days"
        }
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.lang == "id" ? "id_ID" : "en_US")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f.string(from: d)
    }

    private func tick() {
        guard Prefs.bool(Key.enabled), let m = next else { AppState.shared.clearActivity("0b-football"); return }
        let secs = m.date.timeIntervalSinceNow
        let opp = m.opponent(team)

        // Reminder island N minutes before kickoff.
        let r = Prefs.int(Key.reminder)
        let rKey = m.id + "-reminder"
        if r > 0, secs > 0, secs <= Double(r) * 60, !firedKeys.contains(rKey) {
            firedKeys.insert(rKey)
            let mins = Int(ceil(secs / 60))
            AppState.shared.show(Island(kind: .info, icon: "soccerball",
                                        title: L10n.lang == "id" ? "Kick-off \(mins) menit lagi" : "Kick-off in \(mins) min",
                                        subtitle: "\(m.home) vs \(m.away) · \(KeepAwake.fmt(m.date))", tint: .blue, duration: 6))
        }

        let mode = Prefs.int(Key.pillMode)
        let days = Self.daysUntil(m.date)
        guard mode == 0 || (mode == 1 && days <= 0) else { AppState.shared.clearActivity("0b-football"); return }
        let text: String
        if m.isLive {
            text = "LIVE vs \(opp)"
        } else if days <= 0 {
            text = secs < 3600 ? "vs \(opp) −\(Int(ceil(secs / 60)))m" : "vs \(opp) \(KeepAwake.fmt(m.date))"
        } else {
            text = "H-\(days)"
        }
        AppState.shared.setActivity(LiveActivity(id: "0b-football", icon: "soccerball", text: text, tint: .blue))
    }
}

// MARK: - Tab

struct FootballTab: View {
    @ObservedObject var s = FootballService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(title: L10n.lang == "id" ? "Laga berikutnya" : "Next match") {
                if let m = s.next {
                    HStack(spacing: 8) {
                        TeamBadge(id: s.teamID, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("vs \(m.opponent(s.team))").font(.system(size: 14, weight: .bold)).lineLimit(1)
                            Text(m.isHome(s.team) ? (L10n.lang == "id" ? "Kandang" : "Home") : (L10n.lang == "id" ? "Tandang" : "Away"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    if m.isLive {
                        Label(L10n.lang == "id" ? "Sedang berlangsung" : "In progress", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.red)
                    } else {
                        Text(FootballService.countdownText(m))
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.blue)
                        if FootballService.daysUntil(m.date) <= 1, m.date > Date() {
                            Text(m.date, style: .timer).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(.blue)
                        }
                    }
                    Text(FootballService.dateText(m.date)).font(.caption)
                    Text([m.league, m.venue].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundColor(.secondary).lineLimit(2)
                } else if s.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(s.error ?? (L10n.lang == "id" ? "Belum ada jadwal" : "No upcoming match")).font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 240)

            Card(title: L10n.lang == "id" ? "5 laga terakhir" : "Last 5 matches") {
                if s.recent.isEmpty {
                    Text(s.loading ? "…" : (L10n.lang == "id" ? "Belum ada data" : "No data")).font(.caption).foregroundColor(.secondary)
                }
                ForEach(s.recent) { m in
                    HStack(spacing: 6) {
                        ResultChip(result: m.result(s.team))
                        Text((m.isHome(s.team) ? "vs " : "@ ") + m.opponent(s.team)).lineLimit(1)
                        Spacer()
                        Text("\(m.homeScore ?? 0)–\(m.awayScore ?? 0)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text(m.date, format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .help("\(m.home) \(m.homeScore ?? 0)–\(m.awayScore ?? 0) \(m.away) · \(m.league)")
                    .onTapGesture { if let u = URL(string: m.url) { NSWorkspace.shared.open(u) } }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(s.teamName).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    if let u = s.lastUpdate { Text(u, style: .relative).font(.caption2).foregroundColor(.secondary) }
                    Button { s.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundColor(.secondary).disabled(s.loading)
                }
            }
        }
    }
}

struct ResultChip: View {
    let result: String?
    var body: some View {
        let color: Color = result == "W" ? .green : (result == "D" ? .gray : .red)
        Text(L10n.lang == "id" ? (["W": "M", "D": "S", "L": "K"][result ?? ""] ?? "–") : (result ?? "–"))
            .font(.system(size: 10, weight: .bold))
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.85)))
    }
}

struct TeamBadge: View {
    let id: String
    let size: CGFloat
    var body: some View {
        AsyncImage(url: URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\(id)_small.png")) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "shield.fill").resizable().scaledToFit().foregroundColor(.white.opacity(0.2))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Settings

struct FootballSettings: View {
    @AppStorage(FootballService.Key.enabled) var enabled = true
    @AppStorage(FootballService.Key.teamID) var teamID = FootballService.persibID
    @AppStorage(FootballService.Key.pillMode) var pillMode = 1
    @AppStorage(FootballService.Key.reminder) var reminder = 60

    var body: some View {
        Form {
            Section("Jadwal pertandingan") {
                Toggle("Tampilkan jadwal tim", isOn: $enabled)
                Picker("Countdown di notch", selection: $pillMode) {
                    Text("Selalu (H-n)").tag(0); Text("Hanya di hari pertandingan").tag(1); Text("Tidak").tag(2)
                }
                Stepper(reminder == 0 ? "Pengingat kick-off: mati" : "Pengingat \(reminder) menit sebelum kick-off", value: $reminder, in: 0...180, step: 15)
            }
            Section("Tim") {
                TextField("FotMob team ID (Persib = 165196)", text: $teamID)
                    .onSubmit { FootballService.shared.resetCache() }
                Text("Data dari kalender publik FotMob (fotmob.com/teams/<ID>/…). Skor masuk setelah laga selesai; kalender diperbarui FotMob beberapa jam sekali.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Muat ulang sekarang") { FootballService.shared.resetCache() }
            }
        }
        .formStyle(.grouped)
    }
}
