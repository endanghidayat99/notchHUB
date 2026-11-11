import AVFoundation
import AppKit
import Combine
import Charts
import SwiftUI

// MARK: - Stocks

struct Quote: Identifiable {
    var id: String { symbol }
    let symbol: String
    var price: Double
    var prevClose: Double
    var state: String          // PRE / OPEN / POST / CLOSED
    var points: [Double]
    var change: Double { price - prevClose }
    var pct: Double { prevClose == 0 ? 0 : change / prevClose * 100 }
}

final class StocksService: ObservableObject {
    static let shared = StocksService()
    @Published var quotes: [Quote] = []
    @Published var tickerIndex = 0
    @Published var alerts: [String: Double] = Store.load([String: Double].self, "priceAlerts") ?? [:] { didSet { Store.save(alerts, "priceAlerts") } }
    private var timer: Timer?
    private var rotate: Timer?
    private var firedAlerts = Set<String>()

    var symbols: [String] {
        Prefs.string(Prefs.Key.stocksWatchlist).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        rotate = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, !self.quotes.isEmpty else { return }
            self.tickerIndex = (self.tickerIndex + 1) % self.quotes.count
        }
    }

    func refresh() {
        let syms = symbols
        var results: [String: Quote] = [:]
        let group = DispatchGroup()
        for s in syms {
            group.enter()
            let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s.urlEncoded)?range=1d&interval=5m&includePrePost=true")!
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { d, _, _ in
                defer { group.leave() }
                guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let chart = o["chart"] as? [String: Any], let res = (chart["result"] as? [[String: Any]])?.first,
                      let meta = res["meta"] as? [String: Any] else { return }
                let price = meta["regularMarketPrice"] as? Double ?? 0
                let prev = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
                var closes: [Double] = []
                if let ind = res["indicators"] as? [String: Any], let q = (ind["quote"] as? [[String: Any]])?.first,
                   let c = q["close"] as? [Any] { closes = c.compactMap { $0 as? Double } }
                let state = Self.marketState(meta)
                let last = closes.last ?? price
                results[s] = Quote(symbol: s, price: state == "OPEN" ? price : last, prevClose: prev, state: state, points: closes)
            }.resume()
        }
        group.notify(queue: .main) {
            self.quotes = syms.compactMap { results[$0] }
            self.checkAlerts()
        }
    }

    static func marketState(_ meta: [String: Any]) -> String {
        guard let p = meta["currentTradingPeriod"] as? [String: Any] else { return "OPEN" }
        let now = Date().timeIntervalSince1970
        func range(_ k: String) -> (Double, Double)? {
            guard let d = p[k] as? [String: Any], let s = d["start"] as? Double, let e = d["end"] as? Double else { return nil }
            return (s, e)
        }
        if let r = range("regular"), now >= r.0 && now < r.1 { return "OPEN" }
        if let r = range("pre"), now >= r.0 && now < r.1 { return "PRE" }
        if let r = range("post"), now >= r.0 && now < r.1 { return "POST" }
        return "CLOSED"
    }

    private func checkAlerts() {
        for q in quotes {
            guard let target = alerts[q.symbol] else { continue }
            let key = "\(q.symbol)@\(target)"
            let crossed = (q.prevClose < target && q.price >= target) || (q.prevClose > target && q.price <= target)
            if crossed && !firedAlerts.contains(key) {
                firedAlerts.insert(key)
                AppState.shared.show(Island(kind: .info, icon: "bell.badge.fill", title: "\(q.symbol) hit \(target)", subtitle: String(format: "Now %.2f", q.price), tint: .yellow, duration: 6))
                Notifier.post("\(q.symbol) price alert", String(format: "Reached %.2f", q.price))
            }
        }
    }

    var tickerText: String? {
        guard !quotes.isEmpty else { return nil }
        let q = quotes[tickerIndex % quotes.count]
        return String(format: "%@ %.2f %@%.1f%%", q.symbol, q.price, q.pct >= 0 ? "▲" : "▼", abs(q.pct))
    }
}

struct StocksTab: View {
    @ObservedObject var s = StocksService.shared
    @AppStorage(Prefs.Key.stocksWatchlist) var watchlist = ""
    @Local private var alertSym = ""
    @Local private var alertPrice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Watchlist (comma separated)", text: $watchlist).textFieldStyle(.roundedBorder).onSubmit { s.refresh() }
                Button { s.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 8) {
                    ForEach(s.quotes) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(q.symbol).font(.system(size: 12, weight: .bold))
                                if q.state != "OPEN" { Text(q.state == "PRE" ? "Pre-market" : q.state == "POST" ? "After-hours" : "Closed").font(.system(size: 9)).padding(.horizontal, 4).background(Capsule().fill(Color.white.opacity(0.15))) }
                                Spacer()
                                Text(String(format: "%.2f", q.price)).font(.system(size: 12).monospacedDigit())
                            }
                            Text(String(format: "%+.2f (%+.2f%%)", q.change, q.pct)).font(.caption2).foregroundColor(q.change >= 0 ? .green : .red)
                            Chart(Array(q.points.enumerated()), id: \.offset) { p in
                                LineMark(x: .value("t", p.offset), y: .value("p", p.element)).foregroundStyle(q.change >= 0 ? Color.green : Color.red)
                            }
                            .chartXAxis(.hidden).chartYAxis(.hidden)
                            .chartYScale(domain: (q.points.min() ?? 0)...(max((q.points.max() ?? 1), (q.points.min() ?? 0) + 0.01)))
                            .frame(height: 34)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    }
                }
            }
            HStack {
                TextField("Symbol", text: $alertSym).frame(width: 80)
                TextField("Alert price", text: $alertPrice).frame(width: 90)
                Button("Set alert") { if let p = Double(alertPrice) { s.alerts[alertSym.uppercased()] = p; alertSym = ""; alertPrice = "" } }
                ForEach(s.alerts.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    ChipButton(title: "\(k) \(v)", icon: "xmark") { s.alerts[k] = nil }
                }
            }.textFieldStyle(.roundedBorder).font(.caption)
        }
    }
}

// MARK: - Teleprompter ("Cuely") — script scrolling right under the webcam

final class Teleprompter: ObservableObject {
    static let shared = Teleprompter()
    @Published var script: String = Prefs.string("teleprompterScript") { didSet { Prefs.set(script, "teleprompterScript") } }
    @Published var speed: Double = 30     // points per second
    @Published var running = false
    private var window: NSPanel?

    func toggle() { running ? stop() : start() }

    func start() {
        guard let s = NotchWindowController.shared?.targetScreen else { return }
        let size = CGSize(width: 520, height: 150)
        let w = NSPanel(contentRect: NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - s.menuBarHeight - size.height - 6, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.sharingType = .none     // never appears in the shared screen / recording
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: TeleprompterView().preferredColorScheme(.dark))
        w.orderFrontRegardless()
        window = w
        running = true
    }

    func stop() { window?.orderOut(nil); window = nil; running = false }
}

struct TeleprompterView: View {
    @ObservedObject var t = Teleprompter.shared
    @Local private var offset: CGFloat = 0
    @Local private var paused = false
    let tick = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            Text(t.script.isEmpty ? "Add your script in the Tools tab." : t.script)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(width: g.size.width - 30)
                .offset(y: g.size.height - offset)
                .frame(maxWidth: .infinity)
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
        .onReceive(tick) { _ in if !paused { offset += t.speed / 30 } }
        .onTapGesture { paused.toggle() }
        .overlay(alignment: .topTrailing) {
            HStack {
                Button { t.speed = max(5, t.speed - 5) } label: { Image(systemName: "tortoise.fill") }
                Button { t.speed += 5 } label: { Image(systemName: "hare.fill") }
                Button { offset = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                Button { t.stop() } label: { Image(systemName: "xmark.circle.fill") }
            }.buttonStyle(.plain).foregroundColor(.secondary).padding(8)
        }
    }
}

// MARK: - Camera mirror

final class CameraMirror: NSObject, ObservableObject {
    static let shared = CameraMirror()
    let session = AVCaptureSession()
    @Published var running = false

    func toggle() { running ? stop() : start() }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            DispatchQueue.global().async {
                if self.session.inputs.isEmpty, let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) {
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.session.commitConfiguration()
                }
                self.session.startRunning()
                DispatchQueue.main.async { self.running = true }
            }
        }
    }

    func stop() { DispatchQueue.global().async { self.session.stopRunning() }; running = false }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))   // mirror
        v.layer = l
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Focus mode watcher

/// macOS has no public Focus API. When Full Disk Access is granted we read the DoNotDisturb assertion store.
final class FocusWatcher {
    static let shared = FocusWatcher()
    private(set) var isFocused = false
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let data = o["data"] as? [[String: Any]] else { return }
        let active = data.contains { (($0["storeAssertionRecords"] as? [Any])?.isEmpty == false) }
        if active != isFocused {
            isFocused = active
            if Prefs.bool(Prefs.Key.focusIsland) {
                AppState.shared.show(Island(kind: .focus, icon: active ? "moon.fill" : "moon", title: active ? "Focus on" : "Focus off", tint: .indigo, duration: 1.8))
            }
        }
    }
}
