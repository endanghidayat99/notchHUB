import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Astronomical calculation (offline, PrayTimes-style algorithm)

enum Prayer: String, CaseIterable, Identifiable, Codable {
    case imsak, fajr, sunrise, dhuhr, asr, maghrib, isha
    var id: String { rawValue }

    var name: String {
        let id = L10n.lang == "id"
        switch self {
        case .imsak: return "Imsak"
        case .fajr: return id ? "Subuh" : "Fajr"
        case .sunrise: return id ? "Terbit" : "Sunrise"
        case .dhuhr: return id ? "Dzuhur" : "Dhuhr"
        case .asr: return id ? "Ashar" : "Asr"
        case .maghrib: return "Maghrib"
        case .isha: return id ? "Isya" : "Isha"
        }
    }

    var icon: String {
        switch self {
        case .imsak: return "moon.haze"
        case .fajr: return "sunrise"
        case .sunrise: return "sun.horizon"
        case .dhuhr: return "sun.max"
        case .asr: return "sun.min"
        case .maghrib: return "sunset"
        case .isha: return "moon.stars"
        }
    }

    /// The five obligatory prayers (adzan/notification apply to these).
    var isFard: Bool { [.fajr, .dhuhr, .asr, .maghrib, .isha].contains(self) }
}

struct CalcMethod: Identifiable, Hashable {
    let id: String
    let name: String
    let fajrAngle: Double
    let ishaAngle: Double?       // nil → ishaMinutes after maghrib
    let ishaMinutes: Double
    let ihtiyat: Double          // safety minutes added to each time

    static let all: [CalcMethod] = [
        CalcMethod(id: "kemenag", name: "Kemenag RI (Indonesia)", fajrAngle: 20, ishaAngle: 18, ishaMinutes: 0, ihtiyat: 2),
        CalcMethod(id: "jakim", name: "JAKIM (Malaysia)", fajrAngle: 20, ishaAngle: 18, ishaMinutes: 0, ihtiyat: 1),
        CalcMethod(id: "muis", name: "MUIS (Singapura)", fajrAngle: 20, ishaAngle: 18, ishaMinutes: 0, ihtiyat: 1),
        CalcMethod(id: "mwl", name: "Muslim World League", fajrAngle: 18, ishaAngle: 17, ishaMinutes: 0, ihtiyat: 0),
        CalcMethod(id: "isna", name: "ISNA (Amerika Utara)", fajrAngle: 15, ishaAngle: 15, ishaMinutes: 0, ihtiyat: 0),
        CalcMethod(id: "egypt", name: "Egyptian General Authority", fajrAngle: 19.5, ishaAngle: 17.5, ishaMinutes: 0, ihtiyat: 0),
        CalcMethod(id: "makkah", name: "Umm al-Qura (Makkah)", fajrAngle: 18.5, ishaAngle: nil, ishaMinutes: 90, ihtiyat: 0),
        CalcMethod(id: "karachi", name: "Univ. Islamic Sciences, Karachi", fajrAngle: 18, ishaAngle: 18, ishaMinutes: 0, ihtiyat: 0),
    ]

    static func byID(_ id: String) -> CalcMethod { all.first { $0.id == id } ?? all[0] }
}

enum PrayerCalculator {
    private static func dsin(_ d: Double) -> Double { sin(d * .pi / 180) }
    private static func dcos(_ d: Double) -> Double { cos(d * .pi / 180) }
    private static func dtan(_ d: Double) -> Double { tan(d * .pi / 180) }
    private static func darcsin(_ x: Double) -> Double { asin(x) * 180 / .pi }
    private static func darccos(_ x: Double) -> Double { acos(min(1, max(-1, x))) * 180 / .pi }
    private static func darctan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180 / .pi }
    private static func darccot(_ x: Double) -> Double { atan(1 / x) * 180 / .pi }
    private static func fix(_ a: Double, _ b: Double) -> Double { let r = a - b * floor(a / b); return r < 0 ? r + b : r }

    private static func julian(_ y: Int, _ m: Int, _ d: Int) -> Double {
        var y = y, m = m
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(Double(y) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(d) + b - 1524.5
    }

    private static func sunPosition(_ jd: Double) -> (decl: Double, eqt: Double) {
        let d = jd - 2451545.0
        let g = fix(357.529 + 0.98560028 * d, 360)
        let q = fix(280.459 + 0.98564736 * d, 360)
        let l = fix(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g), 360)
        let e = 23.439 - 0.00000036 * d
        let ra = darctan2(dcos(e) * dsin(l), dcos(l)) / 15
        let eqt = q / 15 - fix(ra, 24)
        return (darcsin(dsin(e) * dsin(l)), eqt)
    }

    /// Returns today's times as Dates for the given coordinates.
    static func times(for date: Date, lat: Double, lon: Double, method: CalcMethod, hanafi: Bool,
                      offsets: [Prayer: Double] = [:], tz: TimeZone = .current) -> [Prayer: Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let jdate = julian(c.year!, c.month!, c.day!) - lon / (15 * 24)

        func midDay(_ t: Double) -> Double { fix(12 - sunPosition(jdate + t).eqt, 24) }
        func angleTime(_ angle: Double, _ t: Double, ccw: Bool) -> Double {
            let decl = sunPosition(jdate + t).decl
            let noon = midDay(t)
            let tt = darccos((-dsin(angle) - dsin(decl) * dsin(lat)) / (dcos(decl) * dcos(lat))) / 15
            return noon + (ccw ? -tt : tt)
        }
        func asrTime(_ factor: Double, _ t: Double) -> Double {
            let decl = sunPosition(jdate + t).decl
            let angle = -darccot(factor + dtan(abs(lat - decl)))
            return angleTime(angle, t, ccw: false)
        }

        // Two iterations for accuracy.
        var fajr = 5.0, sunrise = 6.0, dhuhr = 12.0, asr = 13.0, sunset = 18.0, isha = 18.0
        for _ in 0..<2 {
            fajr = angleTime(method.fajrAngle, fajr / 24, ccw: true)
            sunrise = angleTime(0.833, sunrise / 24, ccw: true)
            dhuhr = midDay(dhuhr / 24)
            asr = asrTime(hanafi ? 2 : 1, asr / 24)
            sunset = angleTime(0.833, sunset / 24, ccw: false)
            isha = method.ishaAngle.map { angleTime($0, isha / 24, ccw: false) } ?? (sunset + method.ishaMinutes / 60)
        }

        let tzHours = Double(tz.secondsFromGMT(for: date)) / 3600
        let adjust = tzHours - lon / 15
        let ih = method.ihtiyat / 60
        var raw: [Prayer: Double] = [
            .fajr: fajr + adjust + ih,
            .sunrise: sunrise + adjust - ih,            // ihtiyat makes sunrise earlier (safer end of Subuh)
            .dhuhr: dhuhr + adjust + ih,
            .asr: asr + adjust + ih,
            .maghrib: sunset + adjust + ih,
            .isha: isha + adjust + ih,
        ]
        raw[.imsak] = raw[.fajr]! - 10.0 / 60

        let midnight = cal.startOfDay(for: date)
        var out: [Prayer: Date] = [:]
        for (p, h) in raw where h.isFinite {
            let minutes = (h * 60 + (offsets[p] ?? 0)).rounded()
            out[p] = midnight.addingTimeInterval(minutes * 60)
        }
        return out
    }
}

// MARK: - Service: countdown activity, adzan, notifications

final class PrayerService: ObservableObject {
    static let shared = PrayerService()

    @Published var today: [Prayer: Date] = [:]
    @Published var tomorrowFajr: Date?
    @Published var adzanPlaying = false
    private var timer: Timer?
    private var firedKeys = Set<String>()
    private var player: AVAudioPlayer?
    private var lastDay = ""

    enum Key {
        static let enabled = "prayerEnabled"
        static let method = "prayerMethod"
        static let hanafi = "prayerHanafi"
        static let lat = "prayerLat"
        static let lon = "prayerLon"
        static let city = "prayerCity"
        static let adzan = "prayerAdzan"                 // master on/off
        static let adzanFile = "prayerAdzanFile"
        static let adzanFajrFile = "prayerAdzanFajrFile"
        static let adzanVolume = "prayerAdzanVolume"
        static let notify = "prayerNotify"
        static let reminder = "prayerReminderMinutes"   // 0 = off
        static let pillMode = "prayerPillMode"          // 0 always, 1 last 30 min, 2 off
        static let muteInFocus = "prayerMuteInFocus"
        static func adzanFor(_ p: Prayer) -> String { "prayerAdzan_\(p.rawValue)" }
        static func offsetFor(_ p: Prayer) -> String { "prayerOffset_\(p.rawValue)" }
    }

    static func registerDefaults() {
        var d: [String: Any] = [Key.enabled: true, Key.method: "kemenag", Key.hanafi: false, Key.adzan: true,
                                Key.adzanVolume: 0.8, Key.notify: true, Key.reminder: 10, Key.pillMode: 1, Key.muteInFocus: false]
        for p in Prayer.allCases where p.isFard { d[Key.adzanFor(p)] = true }
        UserDefaults.standard.register(defaults: d)
    }

    var coordinates: (Double, Double)? {
        let lat = Prefs.double(Key.lat), lon = Prefs.double(Key.lon)
        if lat != 0 || lon != 0 { return (lat, lon) }
        let wl = Prefs.double(Prefs.Key.weatherLat), wn = Prefs.double(Prefs.Key.weatherLon)
        if wl != 0 || wn != 0 { return (wl, wn) }
        return nil
    }

    var cityName: String {
        let c = Prefs.string(Key.city)
        return c.isEmpty ? WeatherService.shared.place : c
    }

    func start() {
        recalc()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        tick()
    }

    private var lastSignature = ""
    private func settingsChanged() {
        let sig = [Key.enabled, Key.method, Key.hanafi, Key.lat, Key.lon, Key.notify, Key.reminder, Key.pillMode]
            .map { "\(UserDefaults.standard.object(forKey: $0) ?? "")" }.joined(separator: "|")
            + Prayer.allCases.map { "\(Prefs.double(Key.offsetFor($0)))" }.joined()
            + "\(Prefs.double(Prefs.Key.weatherLat))"
        guard sig != lastSignature else { return }
        lastSignature = sig
        recalc()
        tick()
    }

    func recalc() {
        guard let coord = coordinates else { today = [:]; return }
        let lat = coord.0, lon = coord.1
        let method = CalcMethod.byID(Prefs.string(Key.method))
        let hanafi = Prefs.bool(Key.hanafi)
        var offsets: [Prayer: Double] = [:]
        for p in Prayer.allCases { offsets[p] = Prefs.double(Key.offsetFor(p)) }
        let now = Date()
        today = PrayerCalculator.times(for: now, lat: lat, lon: lon, method: method, hanafi: hanafi, offsets: offsets)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        tomorrowFajr = PrayerCalculator.times(for: tomorrow, lat: lat, lon: lon, method: method, hanafi: hanafi, offsets: offsets)[.fajr]
        lastDay = now.dayKey
        scheduleNotifications()
    }

    /// Next fard prayer (rolls over to tomorrow's Subuh after Isya).
    var next: (Prayer, Date)? {
        let now = Date()
        if let n = Prayer.allCases.filter(\.isFard).compactMap({ p in today[p].map { (p, $0) } }).filter({ $0.1 > now }).min(by: { $0.1 < $1.1 }) {
            return n
        }
        return tomorrowFajr.map { (.fajr, $0) }
    }

    private func tick() {
        guard Prefs.bool(Key.enabled) else { AppState.shared.clearActivity("0a-prayer"); return }
        if Date().dayKey != lastDay { firedKeys.removeAll(); recalc() }
        let now = Date()

        // Prayer time reached → island + adzan (+ in-app fallback for the notification).
        for p in Prayer.allCases where p.isFard {
            guard let t = today[p] else { continue }
            let key = "\(lastDay)-\(p.rawValue)"
            if now >= t, now.timeIntervalSince(t) < 120, !firedKeys.contains(key) {
                firedKeys.insert(key)
                prayerTimeArrived(p)
            }
            // Reminder island N minutes before.
            let r = Prefs.int(Key.reminder)
            let rKey = key + "-reminder"
            if r > 0, now >= t.addingTimeInterval(-Double(r) * 60), now < t, !firedKeys.contains(rKey) {
                firedKeys.insert(rKey)
                AppState.shared.show(Island(kind: .info, icon: "bell.badge", title: "\(r) menit lagi \(p.name)",
                                            subtitle: "\(p.name) pukul \(KeepAwake.fmt(t))", tint: .teal, duration: 5))
            }
        }

        // Countdown in the collapsed pill.
        if let n = next {
            let p = n.0, t = n.1
            let secs = t.timeIntervalSince(now)
            let mode = Prefs.int(Key.pillMode)
            if mode == 0 || (mode == 1 && secs <= 30 * 60) {
                let text = secs < 3600 ? "\(p.name) −\(Int(ceil(secs / 60)))m" : "\(p.name) \(KeepAwake.fmt(t))"
                AppState.shared.setActivity(LiveActivity(id: "0a-prayer", icon: p.icon, text: text, tint: .teal))
            } else {
                AppState.shared.clearActivity("0a-prayer")
            }
        }
    }

    private func prayerTimeArrived(_ p: Prayer) {
        let playAdzan = Prefs.bool(Key.adzan) && Prefs.bool(Key.adzanFor(p)) && !(Prefs.bool(Key.muteInFocus) && FocusWatcher.shared.isFocused)
        if playAdzan { playAdzanSound(fajr: p == .fajr) }
        var actions: [IslandAction] = []
        if playAdzan { actions.append(IslandAction(title: "Stop adzan") { PrayerService.shared.stopAdzan() }) }
        // Shown directly (bypasses the Focus filter on purpose: prayer time is high priority).
        DispatchQueue.main.async {
            let island = Island(kind: .approval, icon: p.icon, title: L10n.lang == "id" ? "Waktunya sholat \(p.name)" : "Time for \(p.name)",
                                subtitle: "\(KeepAwake.fmt(self.today[p] ?? Date())) · \(self.cityName)", tint: .teal, actions: actions,
                                duration: playAdzan ? 0 : 12)
            AppState.shared.show(island)
        }
    }

    // MARK: Adzan audio

    func playAdzanSound(fajr: Bool) {
        stopAdzan()
        let custom = Prefs.string(fajr && !Prefs.string(Key.adzanFajrFile).isEmpty ? Key.adzanFajrFile : Key.adzanFile)
        let volume = Float(Prefs.double(Key.adzanVolume))
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom), let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: custom)) {
            p.volume = volume
            p.delegate = AdzanDelegate.shared
            p.play()
            player = p
            adzanPlaying = true
        } else {
            // No adzan file chosen yet: short chime so the moment isn't missed.
            NSSound(named: "Glass")?.play()
        }
    }

    func stopAdzan() {
        player?.stop()
        player = nil
        if adzanPlaying {
            adzanPlaying = false
            if AppState.shared.island?.kind == .approval { AppState.shared.dismissIsland() }
        }
    }

    final class AdzanDelegate: NSObject, AVAudioPlayerDelegate {
        static let shared = AdzanDelegate()
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            DispatchQueue.main.async {
                PrayerService.shared.adzanPlaying = false
                AppState.shared.dismissIsland()
            }
        }
    }

    // MARK: System notifications (delivered even when the notch is hidden)

    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("prayer-") })
            guard Prefs.bool(Key.enabled), Prefs.bool(Key.notify) else { return }
            let now = Date()
            var items: [(String, Date, String, String)] = []
            for p in Prayer.allCases where p.isFard {
                guard let t = self.today[p] else { continue }
                items.append(("prayer-\(p.rawValue)", t, L10n.lang == "id" ? "Waktunya sholat \(p.name)" : "Time for \(p.name)",
                              "\(KeepAwake.fmt(t)) · \(self.cityName)"))
                let r = Prefs.int(Key.reminder)
                if r > 0 {
                    items.append(("prayer-\(p.rawValue)-rem", t.addingTimeInterval(-Double(r) * 60),
                                  L10n.lang == "id" ? "\(r) menit lagi \(p.name)" : "\(p.name) in \(r) minutes", KeepAwake.fmt(t)))
                }
            }
            if let f = self.tomorrowFajr {
                items.append(("prayer-fajr-tomorrow", f, L10n.lang == "id" ? "Waktunya sholat Subuh" : "Time for Fajr", KeepAwake.fmt(f)))
            }
            for (id, date, title, body) in items where date > now {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                center.add(UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }

    static var hijriDate: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .islamicUmmAlQura)
        f.locale = Locale(identifier: L10n.lang == "id" ? "id_ID" : "en_US")
        f.dateStyle = .long
        return f.string(from: Date())
    }
}

// MARK: - Tab

struct PrayerTab: View {
    @ObservedObject var s = PrayerService.shared
    @AppStorage(PrayerService.Key.adzan) var adzan = true
    @AppStorage(PrayerService.Key.notify) var notify = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card {
                if let n = s.next {
                    let p = n.0, t = n.1
                    Text(L10n.lang == "id" ? "Berikutnya" : "Next").font(.caption).foregroundColor(.secondary)
                    Label(p.name, systemImage: p.icon).font(.system(size: 20, weight: .bold))
                    Text(t, style: .timer).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(.teal)
                    Text("\(KeepAwake.fmt(t)) · \(s.cityName)").font(.caption).foregroundColor(.secondary)
                } else {
                    Text(L10n.lang == "id" ? "Lokasi belum diketahui" : "Location unknown").font(.headline)
                    Text(L10n.lang == "id" ? "Izinkan Lokasi atau isi koordinat di Pengaturan › Sholat." : "Allow Location or enter coordinates in Settings › Prayer.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text(PrayerService.hijriDate).font(.caption2).foregroundColor(.secondary)
                Spacer(minLength: 0)
                HStack {
                    Toggle("Adzan", isOn: $adzan).toggleStyle(.switch).controlSize(.mini)
                    Toggle(L10n.lang == "id" ? "Notifikasi" : "Notify", isOn: $notify).toggleStyle(.switch).controlSize(.mini)
                }.font(.caption)
                if s.adzanPlaying { Button("Stop adzan") { s.stopAdzan() }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.small) }
            }
            .frame(width: 220)

            Card {
                let nextP = s.next?.0
                ForEach(Prayer.allCases) { p in
                    HStack {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.name)
                        Spacer()
                        if p.isFard {
                            Button { Prefs.set(!Prefs.bool(PrayerService.Key.adzanFor(p)), PrayerService.Key.adzanFor(p)); s.objectWillChange.send() } label: {
                                Image(systemName: Prefs.bool(PrayerService.Key.adzanFor(p)) ? "speaker.wave.2.fill" : "speaker.slash")
                                    .foregroundColor(Prefs.bool(PrayerService.Key.adzanFor(p)) ? .teal : .secondary)
                            }.buttonStyle(.plain).help("Adzan \(p.name)")
                        }
                        Text(s.today[p].map(KeepAwake.fmt) ?? "--:--").font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(p == nextP ? .teal : (p.isFard ? .white : .secondary))
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

// MARK: - Settings

struct PrayerSettings: View {
    @AppStorage(PrayerService.Key.enabled) var enabled = true
    @AppStorage(PrayerService.Key.method) var method = "kemenag"
    @AppStorage(PrayerService.Key.hanafi) var hanafi = false
    @AppStorage(PrayerService.Key.lat) var lat = 0.0
    @AppStorage(PrayerService.Key.lon) var lon = 0.0
    @AppStorage(PrayerService.Key.city) var city = ""
    @AppStorage(PrayerService.Key.adzan) var adzan = true
    @AppStorage(PrayerService.Key.adzanFile) var adzanFile = ""
    @AppStorage(PrayerService.Key.adzanFajrFile) var adzanFajrFile = ""
    @AppStorage(PrayerService.Key.adzanVolume) var volume = 0.8
    @AppStorage(PrayerService.Key.notify) var notify = true
    @AppStorage(PrayerService.Key.reminder) var reminder = 10
    @AppStorage(PrayerService.Key.pillMode) var pillMode = 1
    @AppStorage(PrayerService.Key.muteInFocus) var muteInFocus = false
    @ObservedObject var s = PrayerService.shared

    var body: some View {
        Form {
            Section("Waktu sholat") {
                Toggle("Tampilkan waktu sholat", isOn: $enabled)
                Picker("Metode perhitungan", selection: $method) { ForEach(CalcMethod.all) { Text($0.name).tag($0.id) } }
                Picker("Ashar", selection: $hanafi) { Text("Syafi'i / Jumhur").tag(false); Text("Hanafi").tag(true) }
                Picker("Countdown di notch", selection: $pillMode) {
                    Text("Selalu").tag(0); Text("30 menit sebelum").tag(1); Text("Tidak").tag(2)
                }
            }
            Section("Lokasi") {
                Text("Kosongkan (0) untuk memakai lokasi otomatis dari Location Services.").font(.caption).foregroundColor(.secondary)
                TextField("Latitude (mis. -0.8917 untuk Palu)", value: $lat, format: .number)
                TextField("Longitude (mis. 119.8707)", value: $lon, format: .number)
                TextField("Nama kota (opsional)", text: $city)
                if let c = s.coordinates { Text(String(format: "Dipakai: %.4f, %.4f", c.0, c.1)).font(.caption).foregroundColor(.secondary) }
            }
            Section("Adzan") {
                Toggle("Suara adzan saat masuk waktu", isOn: $adzan)
                HStack(spacing: 14) {
                    ForEach(Prayer.allCases.filter(\.isFard)) { p in AdzanToggle(prayer: p) }
                }.disabled(!adzan)
                fileRow("File adzan (MP3/M4A)", $adzanFile)
                fileRow("File adzan Subuh (opsional)", $adzanFajrFile)
                Slider(value: $volume, in: 0...1) { Text("Volume") }
                HStack {
                    Button("Tes adzan") { s.playAdzanSound(fajr: false) }
                    Button("Stop") { s.stopAdzan() }
                }
                Toggle("Bisukan adzan saat Focus / Do Not Disturb aktif", isOn: $muteInFocus)
                if adzanFile.isEmpty {
                    Text("Belum ada file adzan — saat masuk waktu hanya bunyi notifikasi singkat. Pilih file rekaman adzan milik Anda.")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Section("Notifikasi") {
                Toggle("Notifikasi saat masuk waktu sholat", isOn: $notify)
                Stepper(reminder == 0 ? "Pengingat sebelum waktu: mati" : "Pengingat \(reminder) menit sebelumnya", value: $reminder, in: 0...60, step: 5)
                Button("Buka pengaturan notifikasi macOS") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Section("Koreksi (menit)") {
                ForEach(Prayer.allCases) { p in OffsetRow(prayer: p) }
            }
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(binding.wrappedValue.isEmpty ? "—" : (binding.wrappedValue as NSString).lastPathComponent)
                .foregroundColor(.secondary).lineLimit(1)
            Button("Pilih…") {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.audio, .mp3, .mpeg4Audio]
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let u = p.url { binding.wrappedValue = u.path }
            }
            if !binding.wrappedValue.isEmpty { Button { binding.wrappedValue = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
        }
    }
}

struct AdzanToggle: View {
    let prayer: Prayer
    @AppStorage private var on: Bool
    init(prayer: Prayer) {
        self.prayer = prayer
        _on = AppStorage(wrappedValue: true, PrayerService.Key.adzanFor(prayer))
    }
    var body: some View { Toggle(prayer.name, isOn: $on).toggleStyle(.checkbox) }
}

struct OffsetRow: View {
    let prayer: Prayer
    @AppStorage private var offset: Double
    init(prayer: Prayer) {
        self.prayer = prayer
        _offset = AppStorage(wrappedValue: 0, PrayerService.Key.offsetFor(prayer))
    }
    var body: some View {
        Stepper("\(prayer.name): \(offset >= 0 ? "+" : "")\(Int(offset)) menit", value: $offset, in: -30...30, step: 1)
    }
}
