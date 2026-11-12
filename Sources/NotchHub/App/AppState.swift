import AppKit
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home", prayer = "Prayer", media = "Media", shelf = "Shelf", clipboard = "Clipboard", timer = "Timer"
    case ai = "AI", system = "System", notifications = "Notifications"

    var id: String { rawValue }
    var title: String { L(rawValue) }
    var icon: String {
        switch self {
        case .home: return "house"
        case .prayer: return "moon.stars"
        case .media: return "music.note"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .timer: return "timer"
        case .ai: return "sparkles"
        case .system: return "cpu"
        case .notifications: return "bell"
        }
    }
}

/// A transient "island" — e.g. HUD, message, approval request — shown over the collapsed notch.
struct Island: Identifiable {
    enum Kind { case hud, info, message, call, approval, focus, battery, capsLock, download, build, shell, agent }
    let id = UUID()
    var kind: Kind
    var icon: String
    var title: String
    var subtitle: String = ""
    var progress: Double? = nil
    var tint: Color = .white
    var actions: [IslandAction] = []
    var duration: TimeInterval = 2.5
}

struct IslandAction: Identifiable {
    let id = UUID()
    var title: String
    var role: ButtonRole? = nil
    var handler: () -> Void
}

/// Persistent compact item living in the collapsed pill (music, timer, build, download...).
struct LiveActivity: Identifiable, Equatable {
    let id: String
    var icon: String
    var text: String
    var tint: Color = .white
    static func == (a: LiveActivity, b: LiveActivity) -> Bool { a.id == b.id && a.text == b.text && a.icon == b.icon }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isExpanded = false
    @Published var isPeeking = false
    @Published var tab: NotchTab = .home
    @Published var island: Island?
    @Published var islandQueue: [Island] = []
    @Published var activities: [String: LiveActivity] = [:]
    @Published var hiddenEverywhere = false
    @Published var isDropTargeted = false

    private var islandTimer: Timer?

    var sortedActivities: [LiveActivity] {
        activities.values.sorted { $0.id < $1.id }
    }

    func setActivity(_ a: LiveActivity?) {
        guard let a else { return }
        if activities[a.id] != a { activities[a.id] = a }
    }

    func clearActivity(_ id: String) {
        if activities[id] != nil { activities[id] = nil }
    }

    func show(_ island: Island) {
        // Low-priority alerts stay quiet while Focus / Do Not Disturb is on.
        if FocusWatcher.shared.isFocused && (island.kind == .info || island.kind == .download) { return }
        DispatchQueue.main.async {
            if self.island != nil, island.kind != .hud {
                // HUDs replace each other; other islands queue.
                if self.island?.kind == .hud { self.present(island) } else { self.islandQueue.append(island) }
                return
            }
            self.present(island)
        }
    }

    private func present(_ island: Island) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.island = island }
        NotchWindowController.shared?.refreshFrame()
        islandTimer?.invalidate()
        guard island.duration > 0 else { return }
        islandTimer = Timer.scheduledTimer(withTimeInterval: island.duration, repeats: false) { [weak self] _ in
            self?.dismissIsland()
        }
    }

    func dismissIsland() {
        islandTimer?.invalidate()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { island = nil }
        if !islandQueue.isEmpty {
            let next = islandQueue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.present(next) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NotchWindowController.shared?.refreshFrame() }
        }
    }

    func open(_ tab: NotchTab? = nil) {
        if let tab { self.tab = tab }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { isExpanded = true; isPeeking = false }
        NotchWindowController.shared?.refreshFrame()
    }

    func close() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { isExpanded = false; isPeeking = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { NotchWindowController.shared?.refreshFrame() }
    }

    func toggle() { isExpanded ? close() : open() }

    func nextTab(_ delta: Int) {
        let all = NotchTab.allCases
        guard let i = all.firstIndex(of: tab) else { return }
        let n = (i + delta + all.count) % all.count
        withAnimation(.easeInOut(duration: 0.2)) { tab = all[n] }
    }
}
