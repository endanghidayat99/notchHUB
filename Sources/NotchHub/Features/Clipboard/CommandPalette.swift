import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Global hotkey (Carbon RegisterEventHotKey — no Accessibility permission needed)

final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = UInt32(HotKey.handlers.count + 1)
        HotKey.handlers[id] = handler
        HotKey.installHandler()
        let hkID = EventHotKeyID(signature: OSType(0x4E484B59), id: id) // 'NHKY'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Search, translate, quick math, video saving

enum SearchTools {
    static let engines: [(String, String)] = [
        ("Google", "https://www.google.com/search?q=%s"),
        ("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        ("Bing", "https://www.bing.com/search?q=%s"),
        ("Brave", "https://search.brave.com/search?q=%s"),
        ("Kagi", "https://kagi.com/search?q=%s"),
        ("Perplexity", "https://www.perplexity.ai/search?q=%s"),
        ("YouTube", "https://www.youtube.com/results?search_query=%s"),
        ("GitHub", "https://github.com/search?q=%s"),
        ("Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s"),
    ]

    static var allEngines: [(String, String)] {
        let custom = Prefs.string(Prefs.Key.customSearchURL)
        return custom.contains("%s") ? engines + [("Custom", custom)] : engines
    }

    static func search(_ q: String, engine: String) {
        guard let tpl = allEngines.first(where: { $0.0 == engine })?.1 ?? engines.first?.1,
              let url = URL(string: tpl.replacingOccurrences(of: "%s", with: q.urlEncoded)) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Translation via Google's public gtx endpoint (no key). Target language from Settings.
    static func translate(_ text: String, to target: String? = nil, completion: @escaping (String) -> Void) {
        let tl = target ?? Prefs.string(Prefs.Key.translateTarget)
        guard !text.isEmpty, let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(tl)&dt=t&q=\(text.urlEncoded)") else { return }
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let arr = try? JSONSerialization.jsonObject(with: d) as? [Any], let parts = arr.first as? [Any] else { return }
            let s = parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
            DispatchQueue.main.async { completion(s) }
        }.resume()
    }

    /// Saves a video from a link using yt-dlp if installed (brew install yt-dlp).
    static func saveVideo(_ link: String) {
        guard let ytdlp = Shell.which("yt-dlp") else {
            AppState.shared.show(Island(kind: .info, icon: "exclamationmark.triangle", title: "yt-dlp not installed", subtitle: "brew install yt-dlp", tint: .orange, duration: 4))
            return
        }
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        AppState.shared.setActivity(LiveActivity(id: "4-video", icon: "arrow.down.circle", text: "Video…", tint: .blue))
        Shell.runAsync(ytdlp, ["-P", dest, link]) { status, _ in
            AppState.shared.clearActivity("4-video")
            AppState.shared.show(Island(kind: .download, icon: status == 0 ? "checkmark.circle.fill" : "xmark.circle", title: status == 0 ? "Video saved" : "Video download failed", subtitle: dest, tint: status == 0 ? .green : .red))
        }
    }
}

/// Tiny safe arithmetic evaluator (+ - * / ^ % parentheses). NSExpression would crash on bad input.
struct MathEval {
    private var chars: [Character]
    private var i = 0
    init(_ s: String) { chars = Array(s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: ",", with: ".")) }

    static func evaluate(_ s: String) -> Double? {
        guard s.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%×x")) != nil,
              s.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
              s.allSatisfy({ "0123456789.+-*/^%()x×, ".contains($0) }) else { return nil }
        var p = MathEval(s)
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    private mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }
    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while let c = peek(), c == "+" || c == "-" { i += 1; guard let r = term() else { return nil }; v = c == "+" ? v + r : v - r }
        return v
    }
    private mutating func term() -> Double? {
        guard var v = power() else { return nil }
        while let c = peek(), c == "*" || c == "/" || c == "%" {
            i += 1; guard let r = power() else { return nil }
            v = c == "*" ? v * r : c == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
        }
        return v
    }
    private mutating func power() -> Double? {
        guard let b = factor() else { return nil }
        if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
        return b
    }
    private mutating func factor() -> Double? {
        if peek() == "-" { i += 1; return factor().map { -$0 } }
        if peek() == "(" { i += 1; let v = expr(); guard peek() == ")" else { return nil }; i += 1; return v }
        var s = ""
        while let c = peek(), c.isNumber || c == "." { s.append(c); i += 1 }
        return Double(s)
    }
}

// MARK: - Command palette (⌃⌥K)

struct PaletteCommand: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let run: () -> Void
}

final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()
    private var window: NSPanel?
    private var hotKey: HotKey?

    func registerHotKey() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.toggle() }
    }

    func toggle() { window?.isVisible == true ? hide() : show() }

    func show() {
        let size = CGSize(width: 620, height: 380)
        let w = window ?? NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.level = .modalPanel
        w.delegate = self
        w.contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.hide() }).preferredColorScheme(.dark))
        if let s = NSScreen.main { w.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.midY)) }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { hide() }
}

struct PaletteView: View {
    let close: () -> Void
    @Local private var query = ""
    @Local private var selection = 0
    @Local private var translation = ""
    @Local private var fileResults: [String] = []
    @FocusState private var focused: Bool

    var commands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        if let v = MathEval.evaluate(q) {
            let s = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.6g", v)
            out.append(PaletteCommand(icon: "equal.circle", title: "= \(s)", subtitle: "Copy result") { ClipboardService.shared.copyText(s) })
        }
        if q.lowercased().hasPrefix("timer "), let m = Double(q.dropFirst(6)) {
            out.append(PaletteCommand(icon: "timer", title: "Start \(Int(m)) min timer", subtitle: "Timer") { TimerService.shared.setCountdown(minutes: m) })
        }
        if !translation.isEmpty {
            out.append(PaletteCommand(icon: "character.bubble", title: translation, subtitle: "Translation — copy") { ClipboardService.shared.copyText(translation) })
        }
        let builtin: [PaletteCommand] = NotchTab.allCases.map { t in
            PaletteCommand(icon: t.icon, title: "Open \(t.title)", subtitle: "Tab") { AppState.shared.open(t) }
        } + [
            PaletteCommand(icon: "cup.and.saucer", title: "Toggle Caffeine / Keep Awake", subtitle: "System") { KeepAwake.shared.toggle() },
            PaletteCommand(icon: "brain.head.profile", title: "Start Pomodoro", subtitle: "Timer") { let t = TimerService.shared; t.mode = .pomodoro; t.reset(); t.start() },
            PaletteCommand(icon: "stopwatch", title: "Start Stopwatch", subtitle: "Timer") { let t = TimerService.shared; t.mode = .stopwatch; t.reset(); t.start() },
            PaletteCommand(icon: "eyedropper", title: "Pick color", subtitle: "Capture") { CaptureTools.pickColor() },
            PaletteCommand(icon: "camera.viewfinder", title: "Capture area", subtitle: "Capture") { CaptureTools.captureArea() },
            PaletteCommand(icon: "text.viewfinder", title: "Ask about the screen", subtitle: "Capture") { ScreenAsk.shared.begin() },
            PaletteCommand(icon: "mic.slash", title: "Toggle mic mute", subtitle: "System") { AudioDevices.shared.setMicMuted(!AudioDevices.shared.micMuted) },
            PaletteCommand(icon: "keyboard", title: "Keyboard cleaning lock", subtitle: "System") { CleaningLock.shared.lockKeyboard() },
            PaletteCommand(icon: "rectangle.fill", title: "Clean screen", subtitle: "System") { CleaningLock.shared.cleanScreen() },
        ]
        let snippets = ClipboardService.shared.snippets.map { s in PaletteCommand(icon: "text.quote", title: s.name, subtitle: "Paste snippet") { ClipboardService.shared.copyText(s.body, paste: true) } }
        let clips = ClipboardService.shared.search(q).prefix(q.isEmpty ? 0 : 8).map { c in
            PaletteCommand(icon: "doc.on.clipboard", title: String(c.text.prefix(80)), subtitle: "Clipboard") { ClipboardService.shared.copy(c, paste: true) }
        }
        let files = fileResults.map { f in PaletteCommand(icon: "doc", title: (f as NSString).lastPathComponent, subtitle: f) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
        let all = builtin + snippets
        out += q.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(q) }
        out += clips + files
        if !q.isEmpty {
            out += SearchTools.allEngines.prefix(4).map { e in PaletteCommand(icon: "magnifyingglass", title: "Search \(e.0) for “\(q)”", subtitle: "Web") { SearchTools.search(q, engine: e.0) } }
            if q.hasPrefix("http") { out.append(PaletteCommand(icon: "arrow.down.circle", title: "Save video from link", subtitle: "yt-dlp") { SearchTools.saveVideo(q) }) }
        }
        return out
    }

    var body: some View {
        let cmds = commands
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundColor(.secondary)
                TextField("Type a command, math, “timer 5”, file name, clipboard text…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                    .onSubmit { run(cmds) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(cmds.enumerated()), id: \.element.id) { i, c in
                            HStack {
                                Image(systemName: c.icon).frame(width: 22)
                                Text(c.title).lineLimit(1)
                                Spacer()
                                Text(c.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Color.accentColor.opacity(0.35) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { c.run(); close() }
                            .id(i)
                        }
                    }.padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo($0) }
            }
        }
        .background(VisualEffect(material: .hudWindow))
        .onAppear { focused = true; query = ""; selection = 0 }
        .onChange(of: query) { q in
            selection = 0
            let current = q
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard current == query, q.count > 2 else { translation = ""; fileResults = []; return }
                // Translate as you type (prefix "tr ")
                if q.hasPrefix("tr ") { SearchTools.translate(String(q.dropFirst(3))) { translation = $0 } } else { translation = "" }
                DispatchQueue.global().async {
                    let r = Shell.run("/usr/bin/mdfind", ["-name", q, "-onlyin", NSHomeDirectory()])
                    let list = Array(r.out.split(separator: "\n").prefix(8).map(String.init))
                    DispatchQueue.main.async { if current == query { fileResults = list } }
                }
            }
        }
        .background(KeyCatcher(up: { selection = max(0, selection - 1) }, down: { selection = min(cmds.count - 1, selection + 1) }, escape: close))
    }

    private func run(_ cmds: [PaletteCommand]) {
        guard selection < cmds.count else { return }
        cmds[selection].run()
        close()
    }
}

/// Arrow-key / Esc handling for the palette.
struct KeyCatcher: NSViewRepresentable {
    let up: () -> Void, down: () -> Void, escape: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 126: up(); return nil
            case 125: down(); return nil
            case 53: escape(); return nil
            default: return e
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var monitor: Any?; deinit { if let monitor { NSEvent.removeMonitor(monitor) } } }
}
