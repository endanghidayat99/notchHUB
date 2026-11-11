import AppKit
import SwiftUI

extension NSScreen {
    var hasNotch: Bool {
        if #available(macOS 12.0, *) { return safeAreaInsets.top > 0 }
        return false
    }

    /// Physical notch size, or a sensible default for pill mode.
    var notchSize: CGSize {
        if #available(macOS 12.0, *), hasNotch, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea {
            return CGSize(width: frame.width - l.width - r.width, height: safeAreaInsets.top)
        }
        return CGSize(width: 190, height: 30)
    }

    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}

/// Window that never activates the app when clicked but can still become key (for text fields).
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shared layout maths used both by SwiftUI views and the window controller (for hit-testing).
final class NotchGeometry: ObservableObject {
    static let shared = NotchGeometry()
    @Published var notch: CGSize = CGSize(width: 190, height: 32)
    @Published var isPill = false

    static let wing: CGFloat = 74
    static let islandSize = CGSize(width: 380, height: 64)
    static let peekExtra = CGSize(width: 120, height: 34)

    func contentSize(state: AppState) -> CGSize {
        let w = CGFloat(Prefs.double(Prefs.Key.panelWidth))
        let h = CGFloat(Prefs.double(Prefs.Key.panelHeight))
        if state.isExpanded { return CGSize(width: max(w, notch.width + 40), height: h + notch.height) }
        if state.island != nil {
            return CGSize(width: max(Self.islandSize.width, notch.width + 60), height: notch.height + Self.islandSize.height)
        }
        if state.isDropTargeted { return CGSize(width: notch.width + 200, height: notch.height + 70) }
        if state.isPeeking { return CGSize(width: notch.width + Self.peekExtra.width, height: notch.height + Self.peekExtra.height) }
        let n = state.activities.count
        let wings: CGFloat = n == 0 ? 0 : Self.wing * 2 + CGFloat(max(0, n - 2)) * 46
        return CGSize(width: notch.width + wings, height: notch.height)
    }
}

final class NotchWindowController: NSObject {
    static weak var shared: NotchWindowController?

    let panel: NotchPanel
    private let state = AppState.shared
    private let geo = NotchGeometry.shared
    private var monitors: [Any] = []
    private var outsideSince: Date?
    private var hoverSince: Date?
    private var scrollAccum: CGFloat = 0
    private var fullscreenTimer: Timer?
    private var blackBar: NSWindow?
    private let maxSize = CGSize(width: 1000, height: 640)

    override init() {
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640))
        super.init()
        NotchWindowController.shared = self
        let host = NSHostingView(rootView: NotchRootView()
            .environmentObject(state)
            .environmentObject(geo))
        host.frame = NSRect(origin: .zero, size: maxSize)
        panel.contentView = host
        applyCaptureVisibility()
        reposition()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true
        installMonitors()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkFullscreen() }
        updateBlackBar()
    }

    var targetScreen: NSScreen {
        let idx = Prefs.int(Prefs.Key.targetDisplay)
        let screens = NSScreen.screens
        if idx > 0, idx <= screens.count { return screens[idx - 1] }
        // Prefer the built-in notched screen.
        return screens.first(where: { $0.hasNotch }) ?? NSScreen.main ?? screens[0]
    }

    @objc private func screensChanged() { reposition(); updateBlackBar() }

    @objc private func prefsChanged() {
        DispatchQueue.main.async {
            self.applyCaptureVisibility()
            self.reposition()
            self.updateBlackBar()
        }
    }

    func reposition() {
        let s = targetScreen
        let pill = Prefs.bool(Prefs.Key.forcePillMode) || !s.hasNotch
        geo.isPill = pill
        if pill {
            geo.notch = CGSize(width: Prefs.double(Prefs.Key.pillWidth), height: Prefs.double(Prefs.Key.pillHeight))
        } else {
            geo.notch = s.notchSize
        }
        let yOffset: CGFloat = pill ? CGFloat(Prefs.double(Prefs.Key.pillYOffset)) : 0
        let origin = NSPoint(x: s.frame.midX - maxSize.width / 2, y: s.frame.maxY - maxSize.height - yOffset)
        panel.setFrame(NSRect(origin: origin, size: maxSize), display: true)
    }

    /// Rect (screen coordinates) of the currently visible notch shape – used for hit testing.
    var interactiveRect: NSRect {
        let size = geo.contentSize(state: state)
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    func refreshFrame() { updateMouseThrough(NSEvent.mouseLocation) }

    private func applyCaptureVisibility() {
        let hidden = Prefs.bool(Prefs.Key.hiddenFromCapture) || Prefs.bool(Prefs.Key.hiddenEverywhere)
        panel.sharingType = hidden ? .none : .readOnly
        let everywhere = Prefs.bool(Prefs.Key.hiddenEverywhere)
        state.hiddenEverywhere = everywhere
        panel.alphaValue = everywhere ? 0 : 1
    }

    // MARK: Hide-the-notch black bar

    private func updateBlackBar() {
        if Prefs.bool(Prefs.Key.hideNotch) {
            let s = targetScreen
            let rect = NSRect(x: s.frame.minX, y: s.frame.maxY - s.menuBarHeight, width: s.frame.width, height: s.menuBarHeight)
            let w = blackBar ?? NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .black
            w.isOpaque = true
            w.ignoresMouseEvents = true
            // Sits on the wallpaper layer so the translucent menu bar renders black.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]
            w.setFrame(rect, display: true)
            w.orderFrontRegardless()
            blackBar = w
        } else {
            blackBar?.orderOut(nil)
            blackBar = nil
        }
    }

    // MARK: Fullscreen behaviour

    private func checkFullscreen() {
        guard Prefs.bool(Prefs.Key.hideInFullscreen), !state.hiddenEverywhere else { return }
        let s = targetScreen
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? s.frame.height
        let full = list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let owner = info[kCGWindowOwnerName as String] as? String, owner != "NotchHub" else { return false }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let flipped = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            return abs(flipped.width - s.frame.width) < 1 && abs(flipped.height - s.frame.height) < 1 && flipped.origin == s.frame.origin
        }
        let target: CGFloat = (full && !state.isExpanded && state.island == nil) ? 0 : 1
        if panel.alphaValue != target { panel.animator().alphaValue = target }
    }

    // MARK: Mouse handling

    private func installMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] e in self?.handleMouse(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] e in self?.handleMouse(e); return e }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.handleScroll(e); return e }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            guard let self else { return e }
            if !self.state.isExpanded, self.state.island == nil, self.interactiveRect.contains(NSEvent.mouseLocation) {
                self.state.open()
                return nil
            }
            return e
        }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return e }
            // ⌘1–9 switches tabs, Esc closes.
            if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                let all = NotchTab.allCases
                if n - 1 < all.count { self.state.tab = all[n - 1] }
                return nil
            }
            if e.keyCode == 53, self.state.isExpanded { self.state.close(); return nil }
            return e
        }) { monitors.append(l) }
    }

    private func handleScroll(_ e: NSEvent) {
        guard state.isExpanded, Prefs.bool(Prefs.Key.swipeTabs), e.window === panel else { return }
        guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        scrollAccum += e.scrollingDeltaX
        if abs(scrollAccum) > 60 {
            state.nextTab(scrollAccum > 0 ? -1 : 1)
            scrollAccum = 0
        }
        if e.phase == .ended || e.momentumPhase == .ended { scrollAccum = 0 }
    }

    private func handleMouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        if e.type == .leftMouseDragged { DragShakeDetector.shared.feed(p) }
        updateMouseThrough(p)

        let inside = interactiveRect.insetBy(dx: -6, dy: -6).contains(p)
        let s = targetScreen
        let atTopEdge = p.y >= s.frame.maxY - 2 && abs(p.x - s.frame.midX) < geo.notch.width
        let dragHasFiles = e.type == .leftMouseDragged && Self.dragPasteboardHasFiles

        if dragHasFiles {
            let near = NSRect(x: s.frame.midX - geo.notch.width / 2 - 120, y: s.frame.maxY - geo.notch.height - 90,
                              width: geo.notch.width + 240, height: geo.notch.height + 90).contains(p)
            if near != state.isDropTargeted { withAnimation(.spring()) { state.isDropTargeted = near } }
            return
        } else if state.isDropTargeted, e.type == .mouseMoved {
            withAnimation(.spring()) { state.isDropTargeted = false }
        }

        if state.isExpanded {
            if inside { outsideSince = nil; return }
            guard Prefs.bool(Prefs.Key.autoCollapse) else { return }
            if outsideSince == nil { outsideSince = Date() }
            if let t = outsideSince, Date().timeIntervalSince(t) > 0.5 {
                outsideSince = nil
                state.close()
            }
            return
        }

        if (inside || (atTopEdge && Prefs.bool(Prefs.Key.hoverTopEdge))) && state.island == nil {
            if Prefs.bool(Prefs.Key.peekOnHover), !state.isPeeking {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.isPeeking = true }
            }
            if hoverSince == nil { hoverSince = Date() }
            let wantsOpen = Prefs.bool(Prefs.Key.hoverToOpen) || (atTopEdge && Prefs.bool(Prefs.Key.hoverTopEdge))
            if wantsOpen, let t = hoverSince, Date().timeIntervalSince(t) > 0.45 {
                hoverSince = nil
                state.open()
            }
        } else {
            hoverSince = nil
            if state.isPeeking { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { state.isPeeking = false } }
        }
    }

    private func updateMouseThrough(_ p: NSPoint) {
        let inside = interactiveRect.contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    static var dragPasteboardHasFiles: Bool {
        let pb = NSPasteboard(name: .drag)
        return pb.types?.contains(.fileURL) ?? false
    }
}

/// Detects a "shake" (rapid horizontal direction reversals) while dragging files and opens the shelf.
final class DragShakeDetector {
    static let shared = DragShakeDetector()
    private var lastX: CGFloat = 0
    private var lastDir: CGFloat = 0
    private var reversals: [Date] = []

    func feed(_ p: NSPoint) {
        guard Prefs.bool(Prefs.Key.shakeToShelf), NotchWindowController.dragPasteboardHasFiles else { return }
        let dx = p.x - lastX
        lastX = p.x
        guard abs(dx) > 8 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if dir != lastDir {
            lastDir = dir
            reversals.append(Date())
            reversals = reversals.filter { Date().timeIntervalSince($0) < 0.6 }
            if reversals.count >= 4 {
                reversals.removeAll()
                DispatchQueue.main.async { AppState.shared.open(.shelf) }
            }
        }
    }
}
