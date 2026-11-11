import AppKit
import Foundation
import Security
import UserNotifications

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String] = [], input: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        if let input {
            let inPipe = Pipe()
            p.standardInput = inPipe
            inPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
            try? inPipe.fileHandleForWriting.close()
        }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func runAsync(_ launchPath: String, _ args: [String] = [], completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = run(launchPath, args)
            DispatchQueue.main.async { completion(r.status, r.out) }
        }
    }

    /// Finds an executable on common Homebrew / system paths.
    static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - AppleScript

enum AppleScript {
    private static let queue = DispatchQueue(label: "notchhub.applescript")

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    static func runAsync(_ source: String, completion: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        queue.async {
            let r = run(source)
            DispatchQueue.main.async { completion?(r) }
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String = "", sound: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "dev.notchhub.app"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - JSON persistence

enum Store {
    static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("NotchHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = dir.appendingPathComponent(name + ".json")
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Accessibility helpers

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Depth-first collect of all string values / titles under an element.
    static func texts(_ el: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 12 else { return [] }
        var out: [String] = []
        if let v = attr(el, kAXValueAttribute) as? String, !v.isEmpty { out.append(v) }
        if let t = attr(el, kAXTitleAttribute) as? String, !t.isEmpty { out.append(t) }
        if let d = attr(el, kAXDescriptionAttribute) as? String, !d.isEmpty { out.append(d) }
        for c in children(el) { out += texts(c, depth: depth + 1) }
        return out
    }

    /// Finds the first button whose title/description matches one of the names and presses it.
    @discardableResult
    static func press(in el: AXUIElement, named names: [String], depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        let role = attr(el, kAXRoleAttribute) as? String
        let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? ""
        if role == kAXButtonRole as String, names.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        }
        for c in children(el) where press(in: c, named: names, depth: depth + 1) { return true }
        return false
    }
}

// MARK: - Synthetic keys

enum Keys {
    static func pasteCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func tap(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        d?.flags = flags
        let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        u?.flags = flags
        d?.post(tap: .cghidEventTap)
        u?.post(tap: .cghidEventTap)
    }
}

// MARK: - Misc

extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
}

extension Date {
    var dayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}

func formatDuration(_ s: TimeInterval) -> String {
    let t = max(0, Int(s.rounded()))
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
