import AVFoundation
import AppKit
import Metal
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Knock to control (chassis/trackpad taps detected as sharp transients via the microphone)

final class KnockDetector {
    static let shared = KnockDetector()
    private let engine = AVAudioEngine()
    private var taps: [Date] = []
    private var lastSpike = Date.distantPast
    private var groupWork: DispatchWorkItem?
    private var running = false
    private var envelope: Float = 0

    func update() {
        if Prefs.bool(Prefs.Key.knockEnabled) { start() } else { stop() }
    }

    private func start() {
        guard !running else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            guard ok, let self else { return }
            DispatchQueue.main.async {
                let input = self.engine.inputNode
                let fmt = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, _ in self?.process(buf) }
                try? self.engine.start()
                self.running = true
            }
        }
    }

    private func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var peak: Float = 0
        var sum: Float = 0
        for i in 0..<n { let v = abs(ch[i]); peak = max(peak, v); sum += v }
        let mean = sum / Float(max(1, n))
        envelope = envelope * 0.95 + mean * 0.05
        // Sensitivity 0…1 → peak threshold and crest factor (knocks are short & very peaky).
        let s = Float(Prefs.double(Prefs.Key.knockSensitivity))
        let threshold: Float = 0.5 - 0.42 * s
        guard peak > threshold, peak > max(0.02, envelope) * (14 - 8 * s), Date().timeIntervalSince(lastSpike) > 0.09 else { return }
        lastSpike = Date()
        DispatchQueue.main.async { self.registerTap() }
    }

    private func registerTap() {
        taps.append(Date())
        groupWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = min(3, self.taps.count)
            self.taps.removeAll()
            let key = count == 1 ? Prefs.Key.knockSingle : count == 2 ? Prefs.Key.knockDouble : Prefs.Key.knockTriple
            Self.perform(Prefs.string(key))
        }
        groupWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    static let actions = ["none", "toggleNotch", "shelf", "clipboard", "caffeine", "playPause"]

    static func perform(_ action: String) {
        switch action {
        case "toggleNotch": AppState.shared.toggle()
        case "shelf": AppState.shared.open(.shelf)
        case "clipboard": AppState.shared.open(.clipboard)
        case "caffeine": KeepAwake.shared.toggle()
        case "playPause": MediaService.shared.playPause()
        default: break
        }
    }
}

// MARK: - Menu bar icon hiding (⌘-drag icons left of the separator; no private APIs)

final class MenuBarHider: NSObject {
    static let shared = MenuBarHider()
    private var toggleItem: NSStatusItem?
    private var separator: NSStatusItem?
    private var collapsed = false

    func update() {
        if Prefs.bool(Prefs.Key.menuBarHiding) {
            guard toggleItem == nil else { return }
            let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            t.autosaveName = "NotchHubToggle"
            t.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show/hide icons")
            t.button?.target = self
            t.button?.action = #selector(toggle)
            let s = NSStatusBar.system.statusItem(withLength: 8)
            s.autosaveName = "NotchHubSeparator"
            s.button?.title = "│"
            s.button?.appearsDisabled = true
            toggleItem = t; separator = s
        } else {
            if let t = toggleItem { NSStatusBar.system.removeStatusItem(t) }
            if let s = separator { NSStatusBar.system.removeStatusItem(s) }
            toggleItem = nil; separator = nil
        }
    }

    @objc func toggle() {
        collapsed.toggle()
        separator?.length = collapsed ? 10_000 : 8
        toggleItem?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.left", accessibilityDescription: nil)
    }
}

// MARK: - Menu bar detach (pop a panel into its own menu bar popover)

final class MenuBarDetach: NSObject {
    static let shared = MenuBarDetach()
    private var items: [String: (NSStatusItem, NSPopover)] = [:]

    func update() {
        sync("clipboard", Prefs.Key.detachClipboard, "doc.on.clipboard") { AnyView(ClipboardTab()) }
        sync("timer", Prefs.Key.detachTimer, "timer") { AnyView(TimerTab()) }
        sync("ai", Prefs.Key.detachAI, "sparkles") { AnyView(AITab()) }
    }

    private func sync(_ id: String, _ key: String, _ icon: String, view: () -> AnyView) {
        if Prefs.bool(key) {
            guard items[id] == nil else { return }
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: id)
            it.button?.target = self
            it.button?.action = #selector(clicked(_:))
            it.button?.identifier = NSUserInterfaceItemIdentifier(id)
            let p = NSPopover()
            p.behavior = .transient
            p.contentSize = NSSize(width: 600, height: 260)
            p.contentViewController = NSHostingController(rootView: view().padding(14).frame(width: 600, height: 260).preferredColorScheme(.dark))
            items[id] = (it, p)
        } else if let entry = items[id] {
            NSStatusBar.system.removeStatusItem(entry.0)
            items[id] = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let p = items[id]?.1 else { return }
        if p.isShown { p.performClose(nil) } else { p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY) }
    }
}

// MARK: - System stats

final class SystemStats: ObservableObject {
    static let shared = SystemStats()
    @Published var cpu: Double = 0
    @Published var memUsed: Double = 0
    @Published var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published var netIn: Double = 0
    @Published var netOut: Double = 0
    @Published var cpuHistory: [Double] = []
    private var prevTicks: (UInt64, UInt64)?
    private var prevNet: (UInt64, UInt64, Date)?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }

    private func sample() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if r == KERN_SUCCESS {
            let user = UInt64(load.cpu_ticks.0), sys = UInt64(load.cpu_ticks.1), idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
            let busy = user + sys + nice, total = busy + idle
            if let p = prevTicks, total > p.1 { cpu = Double(busy - p.0) / Double(total - p.1) }
            prevTicks = (busy, total)
            cpuHistory = Array((cpuHistory + [cpu]).suffix(40))
        }

        var vm = vm_statistics64()
        var vcount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vcount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vcount) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * page
            memUsed = used / 1_073_741_824
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var rx: UInt64 = 0, tx: UInt64 = 0
        if getifaddrs(&ifaddr) == 0 {
            var p = ifaddr
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"), let data = cur.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        if let pn = prevNet {
            let dt = Date().timeIntervalSince(pn.2)
            if dt > 0, rx >= pn.0, tx >= pn.1 { netIn = Double(rx - pn.0) / dt; netOut = Double(tx - pn.1) / dt }
        }
        prevNet = (rx, tx, Date())
    }

    static func rate(_ bps: Double) -> String {
        bps > 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576) : String(format: "%.0f KB/s", bps / 1024)
    }
}

// MARK: - External display brightness (DDC/CI via m1ddc on Apple silicon; off by default)

enum ExternalDisplay {
    static var tool: String? { Shell.which("m1ddc") }

    static func setBrightness(_ v: Int, display: Int = 1) {
        guard Prefs.bool(Prefs.Key.ddcEnabled), let t = tool else { return }
        Shell.runAsync(t, ["display", "\(display)", "set", "luminance", "\(max(0, min(100, v)))"]) { _, _ in }
    }
}

// MARK: - Extra brightness on XDR / HDR displays (EDR overlay with multiply blend)

final class ExtraBrightness {
    static let shared = ExtraBrightness()
    private var windows: [NSWindow] = []
    private var timer: Timer?

    func update() {
        stop()
        guard Prefs.bool(Prefs.Key.extraBrightness) else { return }
        for s in NSScreen.screens where s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01 {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = EDRView(frame: NSRect(origin: .zero, size: s.frame.size), screen: s)
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.windows.forEach { ($0.contentView as? EDRView)?.render() }
        }
    }

    func stop() {
        timer?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

final class EDRView: NSView {
    private let metal = CAMetalLayer()
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private weak var screenRef: NSScreen?

    init(frame: NSRect, screen: NSScreen) {
        screenRef = screen
        super.init(frame: frame)
        wantsLayer = true
        layer = metal
        metal.device = device
        metal.pixelFormat = .rgba16Float
        metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metal.compositingFilter = "multiplyBlendMode"
        metal.isOpaque = false
        metal.drawableSize = CGSize(width: 64, height: 64)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Steps back in Low Power Mode, on low battery or under thermal pressure.
    var level: Double {
        var l = Prefs.double(Prefs.Key.extraBrightnessLevel)
        let headroom = Double(screenRef?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { l = min(l, 1.15) }
        if BatteryService.shared.hasBattery && !BatteryService.shared.charging && BatteryService.shared.level < 20 { l = 1 }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { l = 1 }
        return max(1, min(l, headroom))
    }

    func render() {
        guard let d = metal.nextDrawable(), let cb = queue?.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = d.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        let l = level
        rp.colorAttachments[0].clearColor = MTLClearColor(red: l, green: l, blue: l, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        cb.present(d)
        cb.commit()
    }
}

// MARK: - Window snapping (drag window to the notch) & modifier-drag move/resize

final class WindowSnapper {
    static let shared = WindowSnapper()
    private var monitors: [Any] = []
    private var dragging = false
    private var lastPoint: NSPoint?

    func update() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        guard Prefs.bool(Prefs.Key.windowSnapping) else { return }
        if !AX.trusted { AX.promptIfNeeded() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in self?.dragging = true }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.mouseUp() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.modifierDrag(e) }) { monitors.append(m) }
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func mouseUp() {
        defer { dragging = false }
        guard dragging, let screen = NotchWindowController.shared?.targetScreen else { return }
        let p = NSEvent.mouseLocation
        let notchW = NotchGeometry.shared.notch.width + 80
        let zone = NSRect(x: screen.frame.midX - notchW / 2, y: screen.frame.maxY - 40, width: notchW, height: 40)
        guard zone.contains(p), let win = focusedWindow() else { return }
        let vf = screen.visibleFrame
        let rel = (p.x - zone.minX) / zone.width
        let target: NSRect
        if rel < 0.33 { target = NSRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height) }
        else if rel > 0.66 { target = NSRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height) }
        else { target = vf }
        setFrame(win, target)
        AppState.shared.show(Island(kind: .hud, icon: rel < 0.33 ? "rectangle.lefthalf.filled" : rel > 0.66 ? "rectangle.righthalf.filled" : "rectangle.fill", title: "Window tiled", duration: 1))
    }

    /// ⌃⌥ + move = move window under cursor, ⌃⌥⇧ + move = resize.
    private func modifierDrag(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let move = f == [.control, .option]
        let resize = f == [.control, .option, .shift]
        guard move || resize else { lastPoint = nil; return }
        let p = NSEvent.mouseLocation
        defer { lastPoint = p }
        guard let last = lastPoint, let win = windowUnderCursor() else { return }
        let dx = p.x - last.x, dy = p.y - last.y
        guard var pos = axPoint(win, kAXPositionAttribute), var size = axSize(win) else { return }
        if move { pos.x += dx; pos.y -= dy; setAX(win, kAXPositionAttribute, pos) }
        else { size.width = max(200, size.width + dx); size.height = max(120, size.height - dy); setAXSize(win, size) }
    }

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = AX.attr(el, kAXFocusedWindowAttribute) else { return nil }
        return (w as! AXUIElement)
    }

    private func windowUnderCursor() -> AXUIElement? {
        let p = NSEvent.mouseLocation
        var el: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(primaryHeight - p.y), &el)
        guard let el else { return nil }
        if (AX.attr(el, kAXRoleAttribute) as? String) == kAXWindowRole as String { return el }
        guard let w = AX.attr(el, kAXWindowAttribute) else { return nil }
        return (w as! AXUIElement)
    }

    private func axPoint(_ w: AXUIElement, _ a: String) -> CGPoint? {
        guard let v = AX.attr(w, a) else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }

    private func axSize(_ w: AXUIElement) -> CGSize? {
        guard let v = AX.attr(w, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &s)
        return s
    }

    private func setAX(_ w: AXUIElement, _ a: String, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, a as CFString, v) }
    }

    private func setAXSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    private func setFrame(_ w: AXUIElement, _ r: NSRect) {
        // AX uses top-left origin coordinates.
        setAX(w, kAXPositionAttribute, CGPoint(x: r.minX, y: primaryHeight - r.maxY))
        setAXSize(w, r.size)
    }
}

/// Simple wrapping chip grid.
struct FlowChips<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}
