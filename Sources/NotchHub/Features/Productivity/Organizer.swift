import AppKit
import CoreLocation
import EventKit
import SwiftUI

// MARK: - Quick notes

struct QuickNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published var notes: [QuickNote] = Store.load([QuickNote].self, "notes") ?? [] { didSet { Store.save(notes, "notes") } }
    func add(_ t: String) { guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }; notes.insert(QuickNote(text: t), at: 0) }
}

struct NotesTab: View {
    @ObservedObject var store = NotesStore.shared
    @ObservedObject var cal = CalendarService.shared
    @Local private var draft = ""
    @Local private var reminder = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(title: L("Notes")) {
                HStack {
                    TextField("Jot something…", text: $draft).textFieldStyle(.roundedBorder).onSubmit { store.add(draft); draft = "" }
                    Button(L("Add")) { store.add(draft); draft = "" }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($store.notes) { $n in
                            HStack(alignment: .top) {
                                TextField("", text: $n.text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12))
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                Button { store.notes.removeAll { $0.id == n.id } } label: { Image(systemName: "trash") }
                            }.buttonStyle(.plain).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
            }
            Card(title: "Reminders (iCloud)") {
                HStack {
                    TextField("New reminder", text: $reminder).textFieldStyle(.roundedBorder).onSubmit { cal.addReminder(reminder); reminder = "" }
                    Button(L("Add")) { cal.addReminder(reminder); reminder = "" }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cal.reminders, id: \.calendarItemIdentifier) { r in
                            HStack {
                                Button { cal.complete(r) } label: { Image(systemName: "circle") }.buttonStyle(.plain)
                                Text(r.title ?? "").font(.system(size: 12)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(width: 230)
        }
    }
}

// MARK: - Calendar & Reminders (EventKit: iCloud, Google, Exchange accounts configured in macOS)

final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var reminders: [EKReminder] = []
    @Published var authorized = false
    private var timer: Timer?

    func start() {
        let done: (Bool, Error?) -> Void = { [weak self] ok, _ in DispatchQueue.main.async { self?.authorized = ok; self?.reload() } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
            store.requestFullAccessToReminders { [weak self] _, _ in DispatchQueue.main.async { self?.reloadReminders() } }
        } else {
            store.requestAccess(to: .event, completion: done)
            store.requestAccess(to: .reminder) { [weak self] _, _ in DispatchQueue.main.async { self?.reloadReminders() } }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.updateCountdown() }
    }

    func reload() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        reloadReminders()
        updateCountdown()
    }

    func reloadReminders() {
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] r in
            DispatchQueue.main.async { self?.reminders = Array((r ?? []).prefix(30)) }
        }
    }

    var nextMeeting: EKEvent? { events.first { !$0.isAllDay && $0.endDate > Date() } }

    /// Meeting countdown activity in the collapsed pill when a meeting starts within 30 minutes.
    private func updateCountdown() {
        guard let e = nextMeeting else { AppState.shared.clearActivity("3-meeting"); return }
        let mins = Int(e.startDate.timeIntervalSinceNow / 60)
        if mins <= 30 && mins >= 0 {
            AppState.shared.setActivity(LiveActivity(id: "3-meeting", icon: "calendar", text: "\(e.title ?? "") in \(mins)m", tint: .red))
            if mins == 1 { AppState.shared.show(Island(kind: .info, icon: "calendar.badge.clock", title: e.title ?? "Meeting", subtitle: "Starts in 1 minute", tint: .red, duration: 6)) }
        } else if mins < 0 {
            AppState.shared.setActivity(LiveActivity(id: "3-meeting", icon: "calendar", text: "Now: \(e.title ?? "")", tint: .red))
        } else {
            AppState.shared.clearActivity("3-meeting")
        }
    }

    /// One-line event entry: "Lunch with Sari tomorrow 12:30" — natural-language date detection.
    func addEvent(_ line: String) {
        guard !line.isEmpty, let cal = store.defaultCalendarForNewEvents else { return }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let ns = line as NSString
        let match = detector?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        let start = match?.date ?? Date().addingTimeInterval(3600)
        var title = line
        if let m = match { title = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespaces) }
        let e = EKEvent(eventStore: store)
        e.title = title.isEmpty ? line : title
        e.startDate = start
        let dur: TimeInterval = (match?.duration ?? 0) > 0 ? (match?.duration ?? 3600) : 3600
        e.endDate = start.addingTimeInterval(dur)
        e.calendar = cal
        try? store.save(e, span: .thisEvent)
        reload()
    }

    func addReminder(_ text: String) {
        guard !text.isEmpty, let cal = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = text
        r.calendar = cal
        try? store.save(r, commit: true)
        reloadReminders()
    }

    func complete(_ r: EKReminder) {
        r.isCompleted = true
        try? store.save(r, commit: true)
        reloadReminders()
    }
}

struct CalendarTab: View {
    @ObservedObject var cal = CalendarService.shared
    @Local private var line = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add event: “Standup tomorrow 9:00”", text: $line).textFieldStyle(.roundedBorder).onSubmit { cal.addEvent(line); line = "" }
                Button(L("Add")) { cal.addEvent(line); line = "" }
            }
            if let n = cal.nextMeeting {
                Label { Text("Next: \(n.title ?? "") — ") + Text(n.startDate, style: .relative) } icon: { Image(systemName: "clock") }.font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if cal.events.isEmpty { Text(L("No events")).foregroundColor(.secondary) }
                    ForEach(cal.events, id: \.eventIdentifier) { e in
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 4, height: 26)
                            VStack(alignment: .leading) {
                                Text(e.title ?? "").font(.system(size: 12, weight: .semibold))
                                Text(e.isAllDay ? "All day" : "\(KeepAwake.fmt(e.startDate)) – \(KeepAwake.fmt(e.endDate))").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(e.calendar.source.title).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Weather (Open-Meteo, keyless)

final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()
    @Published var temp: Double?
    @Published var code = 0
    @Published var place = ""
    @Published var sunrise: Date?
    @Published var sunset: Date?
    private let lm = CLLocationManager()
    private var timer: Timer?

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        if Prefs.double(Prefs.Key.weatherLat) != 0 { fetch() } else { lm.requestWhenInUseAuthorization(); lm.requestLocation() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.fetch() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Prefs.set(l.coordinate.latitude, Prefs.Key.weatherLat)
        Prefs.set(l.coordinate.longitude, Prefs.Key.weatherLon)
        CLGeocoder().reverseGeocodeLocation(l) { p, _ in DispatchQueue.main.async { self.place = p?.first?.locality ?? "" } }
        fetch()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func fetch() {
        let lat = Prefs.double(Prefs.Key.weatherLat), lon = Prefs.double(Prefs.Key.weatherLon)
        guard lat != 0 || lon != 0 else { return }
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=sunrise,sunset&timezone=auto&forecast_days=1")!
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let cur = o["current"] as? [String: Any]
            let daily = o["daily"] as? [String: Any]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let tz = o["timezone"] as? String { f.timeZone = TimeZone(identifier: tz) }
            DispatchQueue.main.async {
                self.temp = cur?["temperature_2m"] as? Double
                self.code = cur?["weather_code"] as? Int ?? 0
                self.sunrise = (daily?["sunrise"] as? [String])?.first.flatMap { f.date(from: $0) }
                self.sunset = (daily?["sunset"] as? [String])?.first.flatMap { f.date(from: $0) }
            }
        }.resume()
    }

    var symbol: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1...3: return "cloud.sun.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
