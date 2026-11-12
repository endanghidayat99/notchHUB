import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home tab

struct HomeTab: View {
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var battery = BatteryService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NowPlayingCard(artSize: 92).frame(width: 300)
            VStack(spacing: 8) {
                Card {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Date(), style: .time).font(.system(size: 26, weight: .bold, design: .rounded))
                            Text(Date(), style: .date).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Image(systemName: weather.symbol).font(.system(size: 22)).symbolRenderingMode(.multicolor)
                            Text(weather.temp.map { "\(Int($0.rounded()))°" } ?? "--").font(.headline)
                            Text(weather.place).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Card {
                    if let n = PrayerService.shared.next {
                        Label("\(n.0.name) \(KeepAwake.fmt(n.1))", systemImage: n.0.icon).font(.caption).foregroundColor(.teal)
                    }
                    if battery.hasBattery { Label("\(battery.level)%\(battery.charging ? " ⚡︎" : "")", systemImage: "battery.100").font(.caption) }
                }
            }
            VStack(spacing: 6) {
                quick("cup.and.saucer.fill", "Caffeine", KeepAwake.shared.active) { KeepAwake.shared.toggle() }
                quick("mic.slash.fill", "Mute mic", AudioDevices.shared.micMuted) { AudioDevices.shared.setMicMuted(!AudioDevices.shared.micMuted) }
                quick("eyedropper", "Color", false) { CaptureTools.pickColor() }
                quick("camera.viewfinder", "Capture", false) { CaptureTools.captureArea() }
                quick("text.viewfinder", "Ask", false) { ScreenAsk.shared.begin() }
            }.frame(width: 96)
        }
    }

    private func quick(_ icon: String, _ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 16); Text(title).font(.system(size: 11)); Spacer() }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }
}

// MARK: - System tab

struct SystemTab: View {
    @ObservedObject var stats = SystemStats.shared
    @ObservedObject var audio = AudioDevices.shared
    @AppStorage(Prefs.Key.ddcEnabled) var ddc = false
    @Local private var kb: Double = Double(KeyboardBacklight.get())
    @Local private var brightness: Double = Double(Brightness.get() ?? 0.5)
    @Local private var ext: Double = 50

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Card(title: "Stats") {
                statRow("cpu", "CPU", String(format: "%.0f%%", stats.cpu * 100), stats.cpu)
                statRow("memorychip", "Memory", String(format: "%.1f / %.0f GB", stats.memUsed, stats.memTotal), stats.memUsed / max(1, stats.memTotal))
                HStack { Image(systemName: "arrow.down"); Text(SystemStats.rate(stats.netIn)); Spacer(); Image(systemName: "arrow.up"); Text(SystemStats.rate(stats.netOut)) }
                    .font(.system(size: 11).monospacedDigit())
                SparkLine(values: stats.cpuHistory).stroke(Color.green, lineWidth: 1.5).frame(height: 30)
            }
            Card(title: "Controls") {
                slider("sun.max.fill", $brightness) { Brightness.set(Float($0)) }
                if KeyboardBacklight.available { slider("light.max", $kb) { KeyboardBacklight.set(Float($0)) } }
                slider(audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) })) { _ in }
                if ddc {
                    if ExternalDisplay.tool != nil {
                        HStack { Image(systemName: "display"); Slider(value: $ext, in: 0...100) { e in if !e { ExternalDisplay.setBrightness(Int(ext)) } } }
                    } else { Text("External display: install m1ddc (brew install m1ddc)").font(.caption2).foregroundColor(.secondary) }
                }
            }
            Card(title: "Batteries") { BatteryList() }
        }
    }

    private func statRow(_ icon: String, _ label: String, _ value: String, _ frac: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Image(systemName: icon); Text(label); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 11))
            ProgressView(value: min(1, max(0, frac))).tint(frac > 0.85 ? .red : .green)
        }
    }

    private func slider(_ icon: String, _ v: Binding<Double>, _ onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18)
            Slider(value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = $0; onChange($0) }), in: 0...1)
        }
    }
}

struct SparkLine: Shape {
    let values: [Double]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(values.count - 1), y: r.maxY - r.height * CGFloat(min(1, max(0, v))))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Desktop widgets (windows on the desktop layer)

enum DesktopWidgetKind: String, CaseIterable, Codable {
    case clock = "Clock", worldClock = "World Clock", nowPlaying = "Now Playing", weather = "Weather", sun = "Sunrise & Sunset"
    case batteries = "Batteries", system = "System", photo = "Photo", timer = "Timer"
}

final class DesktopWidgets: ObservableObject {
    static let shared = DesktopWidgets()
    @Published var enabled: Set<DesktopWidgetKind> = Set(Store.load([DesktopWidgetKind].self, "widgets") ?? []) {
        didSet { Store.save(Array(enabled), "widgets"); sync() }
    }
    @Published var photoPath: String = Prefs.string("widgetPhoto") { didSet { Prefs.set(photoPath, "widgetPhoto"); sync() } }
    private var windows: [DesktopWidgetKind: NSWindow] = [:]

    func sync() {
        for k in DesktopWidgetKind.allCases {
            if enabled.contains(k) {
                guard windows[k] == nil else { continue }
                let size = CGSize(width: 200, height: k == .worldClock ? 180 : 120)
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                w.isMovableByWindowBackground = true
                w.setFrameAutosaveName("NotchHubWidget-\(k.rawValue)")
                if w.frame.origin == .zero, let s = NSScreen.main {
                    let idx = CGFloat(DesktopWidgetKind.allCases.firstIndex(of: k) ?? 0)
                    w.setFrameOrigin(NSPoint(x: s.visibleFrame.minX + 20 + (idx.truncatingRemainder(dividingBy: 4)) * 215, y: s.visibleFrame.maxY - 140 - floor(idx / 4) * 200))
                }
                w.contentView = NSHostingView(rootView: DesktopWidgetView(kind: k).frame(width: size.width, height: size.height).preferredColorScheme(.dark))
                w.orderFront(nil)
                windows[k] = w
            } else if let w = windows[k] {
                w.orderOut(nil); windows[k] = nil
            }
        }
    }
}

struct DesktopWidgetView: View {
    let kind: DesktopWidgetKind
    @ObservedObject var weather = WeatherService.shared
    @ObservedObject var widgets = DesktopWidgets.shared
    @ObservedObject var timer = TimerService.shared
    @ObservedObject var stats = SystemStats.shared

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            content.padding(12).foregroundColor(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder var content: some View {
        switch kind {
        case .clock:
            VStack { Text(Date(), style: .time).font(.system(size: 34, weight: .bold, design: .rounded)); Text(Date(), style: .date).font(.caption) }
        case .worldClock:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(["Asia/Jakarta", "Asia/Makassar", "Europe/London", "America/New_York", "Asia/Tokyo"], id: \.self) { tz in
                    HStack { Text(tz.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ")); Spacer(); Text(Self.time(in: tz)).monospacedDigit() }.font(.system(size: 12))
                }
            }
        case .nowPlaying: NowPlayingCard(artSize: 70, showExtras: false)
        case .weather:
            VStack { Image(systemName: weather.symbol).font(.system(size: 30)).symbolRenderingMode(.multicolor); Text(weather.temp.map { "\(Int($0.rounded()))°" } ?? "--").font(.title); Text(weather.place).font(.caption) }
        case .sun:
            VStack(alignment: .leading, spacing: 6) {
                Label(weather.sunrise.map(KeepAwake.fmt) ?? "--", systemImage: "sunrise.fill")
                Label(weather.sunset.map(KeepAwake.fmt) ?? "--", systemImage: "sunset.fill")
            }.font(.title3).symbolRenderingMode(.multicolor)
        case .batteries: BatteryList()
        case .system:
            VStack(alignment: .leading) {
                Text(String(format: "CPU %.0f%%", stats.cpu * 100)); Text(String(format: "RAM %.1f GB", stats.memUsed)); Text("↓ \(SystemStats.rate(stats.netIn))")
            }.font(.system(size: 13, design: .monospaced))
        case .photo:
            if let img = NSImage(contentsOfFile: widgets.photoPath) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).padding(-12) } else { Text("Choose a photo in Settings › Widgets").font(.caption) }
        case .timer:
            VStack { Text(timer.display).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()); Button(timer.isRunning ? L("Pause") : L("Start")) { timer.toggle() } }
        }
    }

    static func time(in tz: String) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.timeZone = TimeZone(identifier: tz); return f.string(from: Date())
    }
}

struct DesktopWidgetSettings: View {
    @ObservedObject var w = DesktopWidgets.shared
    var body: some View {
        VStack(alignment: .leading) {
            FlowChips(items: DesktopWidgetKind.allCases.map(\.rawValue)) { name in
                let k = DesktopWidgetKind(rawValue: name)!
                ChipButton(title: name, icon: w.enabled.contains(k) ? "checkmark" : "plus", active: w.enabled.contains(k)) {
                    if w.enabled.contains(k) { w.enabled.remove(k) } else { w.enabled.insert(k) }
                }
            }
            Button("Choose photo…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let u = p.url { w.photoPath = u.path }
            }
            Text("Drag widgets anywhere on the desktop. Lock-screen widgets are not possible with public macOS APIs.").font(.caption2).foregroundColor(.secondary)
        }
    }
}
