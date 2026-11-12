import AppKit
import SwiftUI

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
