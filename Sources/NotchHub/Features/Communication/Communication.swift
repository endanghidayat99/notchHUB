import AppKit
import SwiftUI

// MARK: - Notification Center reader (Accessibility) → Message Island & Call Island
//
// macOS exposes no public API for incoming calls/messages. Like the original, we use Accessibility:
// observe the NotificationCenter UI process, read the banner text, and press its buttons on demand.

final class BannerWatcher {
    static let shared = BannerWatcher()
    private var observer: AXObserver?
    private var timer: Timer?
    private var seen = Set<String>()

    func start() {
        guard Prefs.bool(Prefs.Key.messageIsland) || Prefs.bool(Prefs.Key.callIsland) else { return }
        guard AX.trusted else { AX.promptIfNeeded(); return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.scan() }
    }

    private var ncApp: AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func scan() {
        guard let nc = ncApp else { return }
        let windows = (AX.attr(nc, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows {
            let texts = AX.texts(w).filter { $0.count > 0 }
            guard !texts.isEmpty else { continue }
            let key = texts.joined(separator: "|")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if seen.count > 200 { seen.removeAll() }
            classify(texts, window: w)
        }
    }

    private func classify(_ texts: [String], window: AXUIElement) {
        let joined = texts.joined(separator: " ")
        let lower = joined.lowercased()
        let callApps = ["facetime", "phone", "zoom", "teams", "whatsapp"]
        let isCall = callApps.contains { lower.contains($0) } && (lower.contains("call") || lower.contains("panggilan") || lower.contains("incoming") || lower.contains("ringing"))

        if isCall, Prefs.bool(Prefs.Key.callIsland) {
            let app = callApps.first { lower.contains($0) }?.capitalized ?? "Call"
            AppState.shared.show(Island(kind: .call, icon: "phone.fill", title: texts.first ?? app, subtitle: "\(app) — incoming call", tint: .green,
                                        actions: [IslandAction(title: L("Accept")) { AX.press(in: window, named: ["Accept", "Answer", "Terima", "Jawab", "Join"]) },
                                                  IslandAction(title: L("Decline"), role: .destructive) { AX.press(in: window, named: ["Decline", "Tolak", "Ignore"]) }],
                                        duration: 20))
            return
        }

        guard Prefs.bool(Prefs.Key.messageIsland), lower.contains("messages") || lower.contains("pesan") || lower.contains("imessage") || lower.contains("sms") else { return }
        let sender = texts.first(where: { !["Messages", "Pesan", "now", "sekarang"].contains($0) }) ?? "Message"
        let body = texts.last ?? ""
        var actions: [IslandAction] = [IslandAction(title: L("Reply")) { MessageReply.present(to: sender) }]
        // Verification codes get a Copy button.
        if let r = body.range(of: #"\b\d{4,8}\b"#, options: .regularExpression), lower.contains("code") || lower.contains("kode") || lower.contains("otp") || lower.contains("verif") {
            let code = String(body[r])
            actions.insert(IslandAction(title: "Copy \(code)") { ClipboardService.shared.copyText(code) }, at: 0)
        }
        AppState.shared.show(Island(kind: .message, icon: "message.fill", title: sender, subtitle: body, tint: .green, actions: actions, duration: 8))
    }
}

/// Inline reply sent through Messages' AppleScript dictionary.
enum MessageReply {
    static func present(to name: String) {
        let alert = NSAlert()
        alert.messageText = "Reply to \(name)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let text = field.stringValue.replacingOccurrences(of: "\"", with: "\\\"")
        let n = name.replacingOccurrences(of: "\"", with: "\\\"")
        AppleScript.runAsync("""
        tell application "Messages"
          set targetChat to missing value
          repeat with c in chats
            try
              if name of c contains "\(n)" then set targetChat to c
            end try
          end repeat
          if targetChat is missing value then
            set targetBuddy to first participant whose name contains "\(n)"
            send "\(text)" to targetBuddy
          else
            send "\(text)" to targetChat
          end if
        end tell
        """)
    }
}

// MARK: - Notification Mirror (requires Full Disk Access to read the usernoted database)

struct MirroredNotification: Identifiable {
    let id: Int
    let app: String
    let title: String
    let body: String
    let date: Date
}

final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()
    @Published var items: [MirroredNotification] = []
    @Published var error: String?

    var dbPath: String? {
        let darwinUser = Shell.run("/usr/bin/getconf", ["DARWIN_USER_DIR"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [darwinUser + "com.apple.notificationcenter/db2/db",
                          NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    func reload() {
        guard let path = dbPath else { error = "Grant Full Disk Access to NotchHub in System Settings › Privacy & Security."; return }
        error = nil
        DispatchQueue.global().async {
            let rows = SQLiteReader.rows(path: path, sql: """
                SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id
                ORDER BY r.delivered_date DESC LIMIT 60
                """)
            let parsed: [MirroredNotification] = rows.compactMap { row in
                guard let id = row[0] as? Int, let app = row[1] as? String, let data = row[2] as? Data,
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let req = plist["req"] as? [String: Any] else { return nil }
                let date = Date(timeIntervalSinceReferenceDate: (row[3] as? Double) ?? Double((row[3] as? Int) ?? 0))
                return MirroredNotification(id: id, app: app.components(separatedBy: ".").last ?? app,
                                            title: req["titl"] as? String ?? "", body: req["body"] as? String ?? "", date: date)
            }
            DispatchQueue.main.async { self.items = parsed }
        }
    }
}

struct NotificationsTab: View {
    @ObservedObject var m = NotificationMirror.shared
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Notification Center").font(.headline)
                Spacer()
                Button { m.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            if let e = m.error {
                Text(e).font(.caption).foregroundColor(.orange)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(m.items) { n in
                        HStack(alignment: .top) {
                            Image(systemName: "app.badge").foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack { Text(n.app).font(.caption.bold()); Spacer(); Text(n.date, style: .relative).font(.caption2).foregroundColor(.secondary) }
                                if !n.title.isEmpty { Text(n.title).font(.system(size: 12, weight: .semibold)) }
                                Text(n.body).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }
                }
            }
        }
        .onAppear { m.reload() }
    }
}
