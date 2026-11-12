import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var geo: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            // Header row lives beside the physical notch.
            HStack(spacing: 0) {
                tabStrip(Array(NotchTab.allCases.prefix(5)))
                Spacer(minLength: geo.isPill ? 12 : geo.notch.width + 8)
                tabStrip(Array(NotchTab.allCases.dropFirst(5)))
                Button { SettingsWindow.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundColor(.secondary).padding(.leading, 6)
            }
            .padding(.horizontal, 14)
            .frame(height: geo.notch.height)

            Group {
                switch state.tab {
                case .home: HomeTab()
                case .prayer: PrayerTab()
                case .media: MediaTab()
                case .shelf: ShelfTab()
                case .clipboard: ClipboardTab()
                case .timer: TimerTab()
                case .ai: AITab()
                case .system: SystemTab()
                case .notifications: NotificationsTab()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
            .id(state.tab)
        }
        .foregroundColor(.white)
    }

    private func tabStrip(_ tabs: [NotchTab]) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                Button { withAnimation(.easeInOut(duration: 0.18)) { state.tab = t } } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(state.tab == t ? Color.white.opacity(0.18) : .clear))
                }
                .buttonStyle(.plain)
                .foregroundColor(state.tab == t ? .white : .secondary)
                .help(t.title)
            }
        }
    }
}

/// Small reusable card container.
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).textCase(.uppercase) }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

struct ChipButton: View {
    let title: String
    var icon: String? = nil
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(active ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
