import AppKit
import Carbon.HIToolbox
import IOKit.ps
import SwiftUI

// MARK: - Brightness (DisplayServices, loaded dynamically)

enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static var builtinDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(builtinDisplay, &v) == 0 ? v : nil
    }

    static func set(_ v: Float) { _ = setFn?(builtinDisplay, min(1, max(0, v))) }
}

// MARK: - Keyboard backlight (CoreBrightness KeyboardBrightnessClient via ObjC runtime)

enum KeyboardBacklight {
    private static let client: NSObject? = {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static var keyboardID: UInt64 {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let c = client, c.responds(to: sel), let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber], let f = ids.first else { return 1 }
        return f.uint64Value
    }

    static var available: Bool { client != nil }

    static func get() -> Float {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let c = client, c.responds(to: sel) else { return 0 }
        typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, keyboardID)
    }

    static func set(_ v: Float) {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let c = client, c.responds(to: sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, min(1, max(0, v)), keyboardID)
    }
}

// MARK: - Event tap hub: media keys (HUD replacement), Hyper key, cleaning lock

final class EventTapHub {
    static let shared = EventTapHub()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var interceptMediaKeys = false
    var hyperEnabled = false
    var cleaningLock = false
    private var hyperDown = false
    private var hyperUsed = false

    func update() {
        interceptMediaKeys = Prefs.bool(Prefs.Key.replaceSystemHUD)
        hyperEnabled = Prefs.bool(Prefs.Key.hyperKey)
        HyperKey.applyMapping(hyperEnabled)
        let needed = interceptMediaKeys || hyperEnabled || cleaningLock
        if needed && tap == nil { install() }
    }

    private func install() {
        guard AX.trusted else { AX.promptIfNeeded(); return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) | (1 << 14) // NX_SYSDEFINED
        let cb: CGEventTapCallBack = { _, type, event, _ in
            EventTapHub.shared.handle(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Keyboard cleaning lock: swallow everything except ⌘⎋.
        if cleaningLock {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape), event.flags.contains(.maskCommand) {
                DispatchQueue.main.async { CleaningLock.shared.unlock() }
            }
            return nil
        }

        // Media / system-defined keys.
        if type.rawValue == 14, interceptMediaKeys, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            let code = Int((ns.data1 & 0xFFFF0000) >> 16)
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            let handled: Set<Int> = [0, 1, 7, 2, 3, 21, 22]
            guard handled.contains(code) else { return Unmanaged.passUnretained(event) }
            if down { DispatchQueue.main.async { HUDService.shared.mediaKey(code, fine: ns.modifierFlags.contains([.shift, .option])) } }
            return nil // suppress → no stock macOS HUD
        }

        // Hyper key: Caps Lock is remapped to F18 by hidutil; F18 acts as ⌃⌥⇧⌘.
        if hyperEnabled {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == Int64(kVK_F18) {
                if type == .keyDown { if !hyperDown { hyperDown = true; hyperUsed = false } ; return nil }
                if type == .keyUp {
                    hyperDown = false
                    if !hyperUsed && Prefs.bool(Prefs.Key.hyperEscape) { DispatchQueue.main.async { Keys.tap(CGKeyCode(kVK_Escape)) } }
                    return nil
                }
            }
            if hyperDown && (type == .keyDown || type == .keyUp) {
                hyperUsed = true
                event.flags.insert([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

enum HyperKey {
    static func applyMapping(_ on: Bool) {
        let json = on
            ? #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
            : #"{"UserKeyMapping":[]}"#
        Shell.runAsync("/usr/bin/hidutil", ["property", "--set", json]) { _, _ in }
    }
}

// MARK: - HUDs

final class HUDService: ObservableObject {
    static let shared = HUDService()
    @Published var edgeValue: Double?
    @Published var edgeIcon = "speaker.wave.2.fill"
    private var lastBrightness: Float?
    private var lastCaps = false
    private var timer: Timer?
    private var edgeWindow: NSPanel?
    private var edgeHide: DispatchWorkItem?

    func start() {
        AudioDevices.shared.onVolumeChange = { [weak self] v, m in self?.showVolume(v, muted: m) }
        lastBrightness = Brightness.get()
        lastCaps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        // Brightness changes (keys, Control Center, ambient) → HUD.
        if Prefs.bool(Prefs.Key.hudEnabled), let b = Brightness.get() {
            if let last = lastBrightness, abs(last - b) > 0.004 { show(icon: "sun.max.fill", value: Double(b), title: "Brightness") }
            lastBrightness = b
        }
        // Caps Lock without Input Monitoring: read the combined session modifier state.
        if Prefs.bool(Prefs.Key.capsLockHUD), !Prefs.bool(Prefs.Key.hyperKey) {
            let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
            if caps != lastCaps {
                lastCaps = caps
                AppState.shared.show(Island(kind: .capsLock, icon: caps ? "capslock.fill" : "capslock", title: caps ? "Caps Lock On" : "Caps Lock Off", tint: caps ? .green : .secondary, duration: 1.2))
            }
        }
    }

    func mediaKey(_ code: Int, fine: Bool) {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let a = AudioDevices.shared
        switch code {
        case 0: a.setVolume(a.volume + step)
        case 1: a.setVolume(a.volume - step)
        case 7: a.setMute(!a.muted)
        case 2: Brightness.set((Brightness.get() ?? 0.5) + step)
        case 3: Brightness.set((Brightness.get() ?? 0.5) - step)
        case 21: KeyboardBacklight.set(KeyboardBacklight.get() + step); show(icon: "light.max", value: Double(KeyboardBacklight.get()), title: "Keyboard")
        case 22: KeyboardBacklight.set(KeyboardBacklight.get() - step); show(icon: "light.min", value: Double(KeyboardBacklight.get()), title: "Keyboard")
        default: break
        }
    }

    func showVolume(_ v: Float, muted: Bool) {
        guard Prefs.bool(Prefs.Key.hudEnabled) else { return }
        let icon = muted || v == 0 ? "speaker.slash.fill" : v < 0.33 ? "speaker.wave.1.fill" : v < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        show(icon: icon, value: muted ? 0 : Double(v), title: "Volume")
    }

    func show(icon: String, value: Double, title: String) {
        switch Prefs.int(Prefs.Key.hudStyle) {
        case 1, 2: showEdge(icon: icon, value: value, circular: Prefs.int(Prefs.Key.hudStyle) == 2)
        default: AppState.shared.show(Island(kind: .hud, icon: icon, title: title, progress: value, tint: .white, duration: 1.4))
        }
    }

    /// Alternative HUD styles: edge-pinned bar or circular gauge.
    private func showEdge(icon: String, value: Double, circular: Bool) {
        edgeIcon = icon
        edgeValue = value
        let scale = CGFloat(max(0.6, Prefs.double(Prefs.Key.hudSize)))
        let size = circular ? CGSize(width: 110 * scale, height: 110 * scale) : CGSize(width: 44 * scale, height: 220 * scale)
        guard let s = NSScreen.main else { return }
        let origin = circular ? NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY + 120)
                              : NSPoint(x: s.frame.maxX - size.width - 12, y: s.frame.midY - size.height / 2)
        let w = edgeWindow ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver; p.backgroundColor = .clear; p.isOpaque = false; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        w.contentView = NSHostingView(rootView: EdgeHUDView(circular: circular).preferredColorScheme(.dark))
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.orderFrontRegardless()
        edgeWindow = w
        edgeHide?.cancel()
        let work = DispatchWorkItem { w.orderOut(nil) }
        edgeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

struct EdgeHUDView: View {
    let circular: Bool
    @ObservedObject var hud = HUDService.shared
    var body: some View {
        let v = hud.edgeValue ?? 0
        ZStack {
            if circular {
                Circle().fill(.black.opacity(0.75))
                Circle().trim(from: 0, to: v).stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90)).padding(10)
                Image(systemName: hud.edgeIcon).font(.system(size: 26))
            } else {
                Capsule().fill(.black.opacity(0.75))
                VStack {
                    GeometryReader { g in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule().fill(Color.white).frame(height: g.size.height * v)
                        }
                    }.padding(.horizontal, 14).padding(.top, 14)
                    Image(systemName: hud.edgeIcon).padding(.bottom, 12)
                }
            }
        }
        .foregroundColor(.white)
        .animation(.easeOut(duration: 0.15), value: v)
    }
}

// MARK: - Battery HUD + Full Charge island

final class BatteryService: ObservableObject {
    static let shared = BatteryService()
    @Published var level = 100
    @Published var charging = false
    @Published var hasBattery = false
    private var lastLevel = 100
    private var lastCharging = false
    private var firedFull = false
    private var firedLow = Set<Int>()

    func start() {
        read(initial: true)
        let loop = IOPSNotificationCreateRunLoopSource({ _ in DispatchQueue.main.async { BatteryService.shared.read(initial: false) } }, nil)?.takeRetainedValue()
        if let loop { CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode) }
    }

    func read(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            level = max > 0 ? cur * 100 / max : cur
            charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        guard !initial else { lastLevel = level; lastCharging = charging; return }

        if Prefs.bool(Prefs.Key.batteryHUD) {
            if charging != lastCharging {
                AppState.shared.show(Island(kind: .battery, icon: charging ? "battery.100.bolt" : "battery.75", title: charging ? "Charging" : "On battery",
                                            subtitle: "\(level)%", progress: Double(level) / 100, tint: charging ? .green : .white, duration: 2))
            }
            for threshold in [20, 10, 5] where !charging && level <= threshold && lastLevel > threshold && !firedLow.contains(threshold) {
                firedLow.insert(threshold)
                AppState.shared.show(Island(kind: .battery, icon: "battery.25", title: "Low battery", subtitle: "\(level)% remaining",
                                            progress: Double(level) / 100, tint: .red, duration: 5))
            }
            if charging { firedLow.removeAll() }
        }
        let target = Prefs.int(Prefs.Key.fullChargeLevel)
        if charging, level >= target, !firedFull {
            firedFull = true
            if Prefs.bool(Prefs.Key.fullChargeSound) { NSSound(named: "Hero")?.play() }
            AppState.shared.show(Island(kind: .battery, icon: "battery.100.bolt", title: "Charged to \(level)%", subtitle: "You can unplug now", tint: .green, duration: 5))
        }
        if !charging || level < target - 2 { firedFull = false }
        lastLevel = level; lastCharging = charging
    }
}

// MARK: - Keyboard cleaning lock & clean screen

final class CleaningLock {
    static let shared = CleaningLock()
    private var blackWindows: [NSWindow] = []

    func lockKeyboard() {
        guard AX.trusted else { AX.promptIfNeeded(); return }
        EventTapHub.shared.cleaningLock = true
        EventTapHub.shared.update()
        AppState.shared.show(Island(kind: .info, icon: "keyboard.badge.ellipsis", title: "Keyboard locked for cleaning", subtitle: "Press ⌘⎋ to unlock", tint: .yellow, duration: 0))
    }

    func unlock() {
        EventTapHub.shared.cleaningLock = false
        AppState.shared.dismissIsland()
        AppState.shared.show(Island(kind: .info, icon: "keyboard", title: "Keyboard unlocked", tint: .green, duration: 1.5))
        blackWindows.forEach { $0.orderOut(nil) }
        blackWindows.removeAll()
    }

    /// Blacks out every display (click anywhere or ⌘⎋ to exit).
    func cleanScreen() {
        lockKeyboard()
        for s in NSScreen.screens {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .black
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: Color.black.onTapGesture(count: 2) { CleaningLock.shared.unlock() }
                .overlay(Text("Double-click or ⌘⎋ to exit").foregroundColor(.gray).padding(), alignment: .bottom))
            w.orderFrontRegardless()
            blackWindows.append(w)
        }
    }
}
