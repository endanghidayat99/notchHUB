import AppKit
import Carbon
import ScreenCaptureKit
import SwiftUI

// MARK: - Screenshot shelf

final class ScreenshotShelf: ObservableObject {
    static let shared = ScreenshotShelf()
    @Published var shots: [URL] = []
    private var known = Set<String>()
    private var timer: Timer?
    private var pinned: [NSPanel] = []

    var folder: URL {
        let r = Shell.run("/usr/bin/defaults", ["read", "com.apple.screencapture", "location"])
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0, !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func start() {
        let f = folder
        known = Set((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [])
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll(f) }
    }

    private func poll(_ f: URL) {
        guard Prefs.bool(Prefs.Key.screenshotShelf) else { return }
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [])
        let new = now.subtracting(known).filter { !$0.hasPrefix(".") && ["png", "jpg", "mov", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
        known = now
        for n in new.sorted() {
            let u = f.appendingPathComponent(n)
            shots.insert(u, at: 0)
            AppState.shared.show(Island(kind: .info, icon: "camera.viewfinder", title: "Screenshot staged", subtitle: n, tint: .white,
                                        actions: [IslandAction(title: L("Pin")) { self.pin(u) }, IslandAction(title: "Open") { AppState.shared.open(.shelf) }], duration: 4))
        }
    }

    func dismiss(_ u: URL) { shots.removeAll { $0 == u } }

    /// Pin a capture as a floating, always-on-top window.
    func pin(_ u: URL) {
        guard let img = NSImage(contentsOf: u) else { return }
        let maxW: CGFloat = 420
        let scale = min(1, maxW / img.size.width)
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.title = u.lastPathComponent
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.contentView = NSHostingView(rootView: Image(nsImage: img).resizable().aspectRatio(contentMode: .fit))
        w.center()
        w.orderFrontRegardless()
        pinned.append(w)
    }

    /// Opens Preview's Markup toolbar on the capture.
    func markup(_ u: URL) {
        NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"), configuration: NSWorkspace.OpenConfiguration())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            AppleScript.runAsync("tell application \"System Events\" to tell process \"Preview\" to keystroke \"a\" using {command down, shift down}")
        }
    }
}

// MARK: - Capture / eyedropper

enum CaptureTools {
    /// Interactive window/area capture → clipboard + shelf.
    static func captureArea(window: Bool = false) {
        AppState.shared.close()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(Int(Date().timeIntervalSince1970)).png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Shell.runAsync("/usr/sbin/screencapture", (window ? ["-i", "-W", "-x"] : ["-i", "-x"]) + [dest.path]) { _, _ in
                guard FileManager.default.fileExists(atPath: dest.path), let img = NSImage(contentsOf: dest) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
                ShelfService.shared.add([dest])
                AppState.shared.show(Island(kind: .info, icon: "camera.fill", title: "Captured to clipboard & shelf", tint: .white, duration: 1.8))
            }
        }
    }

    /// NSColorSampler: system magnifier, no Screen Recording permission needed.
    static func pickColor() {
        AppState.shared.close()
        NSColorSampler().show { c in
            guard let c else { return }
            let hex = c.hexString
            ClipboardService.shared.copyText(hex)
            AppState.shared.show(Island(kind: .info, icon: "eyedropper.full", title: hex, subtitle: "Copied", tint: Color(nsColor: c), duration: 2))
        }
    }
}

// MARK: - Ask about the screen

final class ScreenAsk: ObservableObject {
    static let shared = ScreenAsk()
    @Published var image: NSImage?
    @Published var text = ""
    @Published var links: [URL] = []
    @Published var answer = ""
    @Published var asking = false
    private var window: NSPanel?
    private var imageURL: URL?

    func begin() {
        AppState.shared.close()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString).png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Shell.runAsync("/usr/sbin/screencapture", ["-i", "-x", dest.path]) { _, _ in
                guard let img = NSImage(contentsOf: dest), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.imageURL = dest
                self.image = img; self.answer = ""; self.text = "…"
                // On-device text reading (Vision).
                OCR.recognize(cg) { t in
                    self.text = t
                    let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                    self.links = det?.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap(\.url) ?? []
                }
                self.showWindow()
            }
        }
    }

    private func showWindow() {
        let w = window ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        w.title = "Ask about the screen"
        w.titlebarAppearsTransparent = true
        w.level = .floating
        w.contentView = NSHostingView(rootView: ScreenAskView().preferredColorScheme(.dark))
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Image leaves the Mac only here, and only with a saved Anthropic API key.
    func ask(_ question: String) {
        guard let key = Keychain.get("anthropicKey"), !key.isEmpty else { answer = "Save an Anthropic API key in Settings › AI first."; return }
        guard let u = imageURL, let png = try? Data(contentsOf: u) else { return }
        asking = true; answer = ""
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": Prefs.string(Prefs.Key.anthropicModel),
            "max_tokens": 1024,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
                ["type": "text", "text": question.isEmpty ? "Explain what is shown in this screenshot." : question],
            ]]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { d, _, err in
            var out = err?.localizedDescription ?? ""
            if let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let content = o["content"] as? [[String: Any]] { out = content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                else if let e = o["error"] as? [String: Any] { out = e["message"] as? String ?? "Error" }
            }
            DispatchQueue.main.async { self.answer = out; self.asking = false }
        }.resume()
    }
}

struct ScreenAskView: View {
    @ObservedObject var s = ScreenAsk.shared
    @Local private var question = ""
    @Local private var translated = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = s.image { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 140).cornerRadius(8) }
            ScrollView { Text(s.text).textSelection(.enabled).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
            HStack {
                Button(L("Copy")) { ClipboardService.shared.copyText(s.text) }
                Button(L("Search")) { SearchTools.search(s.text, engine: "Google") }
                Button(L("Translate")) { SearchTools.translate(s.text) { translated = $0 } }
                ForEach(s.links.prefix(3), id: \.self) { u in Button(u.host ?? "Link") { NSWorkspace.shared.open(u) } }
            }.controlSize(.small)
            if !translated.isEmpty { Text(translated).font(.system(size: 12)).foregroundColor(.mint).textSelection(.enabled) }
            Divider()
            HStack {
                TextField("Ask a question about this…", text: $question).textFieldStyle(.roundedBorder).onSubmit { s.ask(question) }
                Button(L("Ask")) { s.ask(question) }.buttonStyle(.borderedProminent)
                if s.asking { ProgressView().controlSize(.small) }
            }
            ScrollView { Text(s.answer).textSelection(.enabled).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(16)
        .padding(.top, 14)
    }
}

// MARK: - Keystroke HUD (password fields excluded via Secure Event Input)

final class KeystrokeHUD {
    static let shared = KeystrokeHUD()
    private var monitor: Any?
    private var buffer = ""
    private var clearWork: DispatchWorkItem?

    func update() {
        if Prefs.bool(Prefs.Key.keystrokeHUD) {
            guard monitor == nil else { return }
            if !AX.trusted { AX.promptIfNeeded() }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) }
        } else if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ e: NSEvent) {
        // Never show keys typed into secure (password) fields.
        if IsSecureEventInputEnabled() { return }
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) && (f.contains(.command) || f.contains(.control)) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        s += special[e.keyCode] ?? (e.charactersIgnoringModifiers?.uppercased() ?? "")
        buffer = String((buffer + (s.count > 1 ? " \(s) " : s)).suffix(28))
        AppState.shared.show(Island(kind: .hud, icon: "keyboard", title: buffer, tint: .white, duration: 1.2))
        clearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.buffer = "" }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }
}
