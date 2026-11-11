import AppKit
import Charts
import IOKit.pwr_mgt
import SwiftUI

/// Pomodoro with session chaining, countdown, repeat timer, drift-free stopwatch, streaks and focus history.
final class TimerService: ObservableObject {
    static let shared = TimerService()

    enum Mode: String, CaseIterable { case pomodoro = "Pomodoro", countdown = "Timer", stopwatch = "Stopwatch" }
    enum Phase { case work, shortBreak, longBreak }

    @Published var mode: Mode = .pomodoro
    @Published var phase: Phase = .work
    @Published var isRunning = false
    @Published var remaining: TimeInterval = 25 * 60
    @Published var total: TimeInterval = 25 * 60
    @Published var elapsed: TimeInterval = 0          // stopwatch
    @Published var completedPomodoros = 0
    @Published var repeatTimer = false
    @Published var history: [String: Double] = [:]     // day -> focus minutes

    private var endDate: Date?
    private var stopwatchStart: Date?
    private var stopwatchAccum: TimeInterval = 0
    private var tick: Timer?
    private var breakReminder: Timer?

    init() {
        history = Store.load([String: Double].self, "focusHistory") ?? [:]
        resetPhase()
    }

    var progress: Double {
        switch mode {
        case .stopwatch: return (elapsed.truncatingRemainder(dividingBy: 60)) / 60
        default: return total > 0 ? 1 - remaining / total : 0
        }
    }

    var display: String { mode == .stopwatch ? formatDuration(elapsed) : formatDuration(remaining) }

    /// Consecutive days with at least one completed focus session.
    var streak: Int {
        var d = Date(), n = 0
        while (history[d.dayKey] ?? 0) > 0 { n += 1; d = Calendar.current.date(byAdding: .day, value: -1, to: d)! }
        return n
    }

    var last7Days: [(String, Double)] {
        (0..<7).reversed().map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let f = DateFormatter(); f.dateFormat = "EEE"
            return (f.string(from: d), history[d.dayKey] ?? 0)
        }
    }

    func setCountdown(minutes: Double) {
        mode = .countdown
        total = minutes * 60; remaining = total
        start()
    }

    func start() {
        isRunning = true
        if mode == .stopwatch {
            stopwatchStart = Date()
        } else {
            endDate = Date().addingTimeInterval(remaining)
        }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func pause() {
        isRunning = false
        tick?.invalidate()
        if mode == .stopwatch, let s = stopwatchStart { stopwatchAccum += Date().timeIntervalSince(s); stopwatchStart = nil }
        update()
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        pause()
        stopwatchAccum = 0; elapsed = 0
        if mode == .pomodoro { phase = .work }
        resetPhase()
        AppState.shared.clearActivity("1-timer")
    }

    func resetPhase() {
        switch mode {
        case .pomodoro:
            let m: Int
            switch phase {
            case .work: m = Prefs.int(Prefs.Key.pomodoroWork)
            case .shortBreak: m = Prefs.int(Prefs.Key.pomodoroBreak)
            case .longBreak: m = Prefs.int(Prefs.Key.pomodoroLongBreak)
            }
            total = Double(max(1, m) * 60); remaining = total
        case .countdown: remaining = total
        case .stopwatch: elapsed = stopwatchAccum
        }
    }

    private func update() {
        if mode == .stopwatch {
            // Drift-free: always derived from wall-clock, never accumulated ticks.
            elapsed = stopwatchAccum + (stopwatchStart.map { Date().timeIntervalSince($0) } ?? 0)
        } else if let end = endDate, isRunning {
            remaining = max(0, end.timeIntervalSinceNow)
            if remaining <= 0 { finished() }
        }
        if isRunning || elapsed > 0 {
            let icon = mode == .pomodoro ? (phase == .work ? "brain.head.profile" : "cup.and.saucer") : (mode == .stopwatch ? "stopwatch" : "timer")
            AppState.shared.setActivity(LiveActivity(id: "1-timer", icon: icon, text: display, tint: phase == .work ? .orange : .mint))
        }
    }

    private func finished() {
        pause()
        NSSound(named: "Glass")?.play()
        if mode == .pomodoro {
            if phase == .work {
                completedPomodoros += 1
                logFocus(minutes: total / 60)
                phase = completedPomodoros % 4 == 0 ? .longBreak : .shortBreak
                AppState.shared.show(Island(kind: .info, icon: "checkmark.seal.fill", title: "Focus session done", subtitle: "Time for a break", tint: .green, duration: 4))
            } else {
                phase = .work
                AppState.shared.show(Island(kind: .info, icon: "brain.head.profile", title: "Break over", subtitle: "Back to focus", tint: .orange, duration: 4))
            }
            resetPhase()
            if Prefs.bool(Prefs.Key.pomodoroChain) { start() }
        } else {
            AppState.shared.show(Island(kind: .info, icon: "timer", title: "Timer finished", tint: .orange, duration: 5))
            if mode == .countdown { logFocus(minutes: total / 60) }
            remaining = total
            if repeatTimer { start() } else { AppState.shared.clearActivity("1-timer") }
        }
    }

    private func logFocus(minutes: Double) {
        history[Date().dayKey, default: 0] += minutes
        Store.save(history, "focusHistory")
    }

    /// Custom break reminders every N minutes (0 = off).
    func configureBreakReminder() {
        breakReminder?.invalidate()
        let m = Prefs.int(Prefs.Key.breakReminderMinutes)
        guard m > 0 else { return }
        breakReminder = Timer.scheduledTimer(withTimeInterval: Double(m * 60), repeats: true) { _ in
            AppState.shared.show(Island(kind: .info, icon: "figure.walk", title: "Take a break", subtitle: "Stand up, stretch, rest your eyes", tint: .mint, duration: 6))
        }
    }
}

// MARK: - Keep Awake (caffeine)

final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published var active = false
    @Published var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func toggle() { active ? stop() : start(until: nil) }

    func start(minutes: Double) { start(until: Date().addingTimeInterval(minutes * 60)) }

    func start(until date: Date?) {
        stop()
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "NotchHub Keep Awake" as CFString, &assertion)
        guard r == kIOReturnSuccess else { return }
        active = true; until = date
        AppState.shared.setActivity(LiveActivity(id: "2-caffeine", icon: "cup.and.saucer.fill", text: date.map { "→" + Self.fmt($0) } ?? "∞", tint: .yellow))
        AppState.shared.show(Island(kind: .hud, icon: "cup.and.saucer.fill", title: "Keep Awake on", subtitle: date.map { "Until \(Self.fmt($0))" } ?? "Indefinitely", tint: .yellow, duration: 1.6))
        if let date {
            timer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        if active { IOPMAssertionRelease(assertion) }
        let was = active
        active = false; until = nil
        AppState.shared.clearActivity("2-caffeine")
        if was { AppState.shared.show(Island(kind: .hud, icon: "cup.and.saucer", title: "Keep Awake off", duration: 1.4)) }
    }

    static func fmt(_ d: Date) -> String { let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d) }
}

// MARK: - Timer tab

struct TimerTab: View {
    @ObservedObject var t = TimerService.shared
    @ObservedObject var caffeine = KeepAwake.shared
    @Local private var customMinutes = 10.0
    @Local private var untilDate = Date().addingTimeInterval(3600)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card {
                Picker("", selection: Binding(get: { t.mode }, set: { t.pause(); t.mode = $0; t.resetPhase() })) {
                    ForEach(TimerService.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                        Circle().trim(from: 0, to: t.progress).stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(t.display).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    }.frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 6) {
                        if t.mode == .pomodoro {
                            Text(t.phase == .work ? L("Focus") : L("Break")).font(.headline)
                            Text("🔥 \(t.streak)-day streak · \(t.completedPomodoros) today").font(.caption)
                        }
                        if t.mode == .countdown {
                            HStack { ForEach([1, 5, 10, 25, 60], id: \.self) { m in ChipButton(title: "\(m)m") { t.setCountdown(minutes: Double(m)) } } }
                            HStack {
                                Stepper("\(Int(customMinutes)) min", value: $customMinutes, in: 1...600)
                                Button(L("Start")) { t.setCountdown(minutes: customMinutes) }
                            }.font(.caption)
                            Toggle("Repeat", isOn: $t.repeatTimer).font(.caption)
                        }
                        HStack {
                            Button(t.isRunning ? L("Pause") : L("Start")) { t.toggle() }.buttonStyle(.borderedProminent)
                            Button(L("Reset")) { t.reset() }
                        }
                    }
                }
            }
            Card(title: "Focus · last 7 days") {
                Chart(t.last7Days, id: \.0) { d in
                    BarMark(x: .value("Day", d.0), y: .value("Min", d.1)).foregroundStyle(.orange.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 90)
                Divider()
                HStack {
                    Image(systemName: caffeine.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                    Text(L("Keep Awake")).font(.caption.bold())
                    Spacer()
                    Toggle("", isOn: Binding(get: { caffeine.active }, set: { $0 ? caffeine.start(until: nil) : caffeine.stop() })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                HStack {
                    ForEach([30, 60, 120], id: \.self) { m in ChipButton(title: "\(m)m") { caffeine.start(minutes: Double(m)) } }
                    DatePicker("", selection: $untilDate, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 80)
                    ChipButton(title: "Until") { caffeine.start(until: untilDate) }
                }
            }
        }
    }
}
