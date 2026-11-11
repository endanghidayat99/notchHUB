import AppKit
import Lottie
import SwiftUI

/// Notch silhouette: concave flares at the top corners blending into the menu bar, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = min(topRadius, r.width / 4)
        let b = min(bottomRadius, r.height / 2, r.width / 4)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct NotchRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var geo: NotchGeometry

    var body: some View {
        let size = geo.contentSize(state: state)
        let expanded = state.isExpanded
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // "Liquid glass": a real blur under a black gradient so the top merges with the hardware notch.
                if expanded {
                    VisualEffect(material: .hudWindow)
                    LinearGradient(colors: [.black, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
                content(size: size)
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape(expanded: expanded, size: size))
            .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                ShelfService.shared.handleDrop(providers)
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: 1000, height: 640, alignment: .top)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: size)
    }

    private func shape(expanded: Bool, size: CGSize) -> AnyShape {
        if geo.isPill && !expanded {
            return AnyShape(RoundedRectangle(cornerRadius: size.height / 2, style: .continuous))
        }
        if geo.isPill { return AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
        return AnyShape(NotchShape(topRadius: 8, bottomRadius: expanded ? 24 : (state.island != nil ? 20 : 10)))
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if state.isExpanded {
            ExpandedView()
        } else if let island = state.island {
            IslandView(island: island)
        } else if state.isDropTargeted {
            DropZoneView()
        } else {
            CollapsedView()
        }
    }
}

// MARK: - Collapsed pill with live activities

struct CollapsedView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var geo: NotchGeometry
    @ObservedObject var media = MediaService.shared
    @ObservedObject var timer = TimerService.shared
    @AppStorage(Prefs.Key.idleLottiePath) var lottiePath = ""
    @AppStorage(Prefs.Key.timerMascot) var mascot = "🐢"

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    let acts = state.sortedActivities
                    if let first = acts.first { ActivityChip(a: first) } else { Spacer() }
                    Spacer(minLength: geo.isPill ? 8 : geo.notch.width)
                    if acts.count > 1 {
                        ForEach(acts.dropFirst()) { ActivityChip(a: $0) }
                    } else if media.isPlaying && SpectrumService.shared.running {
                        SpectrumBars(compact: true).frame(width: 40, height: 14)
                    } else { Spacer() }
                }
                .padding(.horizontal, 12)
                if state.activities.isEmpty, !lottiePath.isEmpty {
                    IdleLottie(path: lottiePath).frame(height: geo.notch.height - 4)
                }
                if timer.isRunning, !mascot.isEmpty {
                    GeometryReader { g in
                        Text(mascot).font(.system(size: 12))
                            .position(x: 12 + (g.size.width - 24) * timer.progress, y: g.size.height - 6)
                    }
                }
            }
            .frame(height: geo.notch.height)
            if state.isPeeking { PeekView().transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }
}

struct ActivityChip: View {
    let a: LiveActivity
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: a.icon).foregroundColor(a.tint)
            Text(a.text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundColor(.white)
        .frame(maxWidth: 120)
    }
}

/// Minimal transport controls shown while hovering ("Peek on Hover").
struct PeekView: View {
    @ObservedObject var media = MediaService.shared
    var body: some View {
        HStack(spacing: 18) {
            if media.hasTrack {
                Text(media.title).font(.caption).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                Button { media.previous() } label: { Image(systemName: "backward.fill") }
                Button { media.playPause() } label: { Image(systemName: media.isPlaying ? "pause.fill" : "play.fill") }
                Button { media.next() } label: { Image(systemName: "forward.fill") }
            } else {
                Text(Date(), style: .time).font(.caption.monospacedDigit())
                Text(L("Nothing playing")).font(.caption).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .frame(height: NotchGeometry.peekExtra.height)
    }
}

struct DropZoneView: View {
    @EnvironmentObject var geo: NotchGeometry
    var body: some View {
        VStack {
            Spacer().frame(height: geo.notch.height)
            Label(L("Drop files here"), systemImage: "tray.and.arrow.down.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundColor(.white.opacity(0.5)))
                .padding(8)
        }
    }
}

struct IslandView: View {
    let island: Island
    @EnvironmentObject var geo: NotchGeometry
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: geo.notch.height)
            HStack(spacing: 10) {
                Image(systemName: island.icon).font(.system(size: 20, weight: .semibold)).foregroundColor(island.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(island.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !island.subtitle.isEmpty {
                        Text(island.subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                    }
                    if let p = island.progress {
                        ProgressView(value: min(max(p, 0), 1)).tint(island.tint).controlSize(.small)
                    }
                }
                Spacer()
                ForEach(island.actions) { a in
                    Button(a.title) { a.handler(); state.dismissIsland() }
                        .buttonStyle(.borderedProminent)
                        .tint(a.role == .destructive ? .red : .accentColor)
                        .controlSize(.small)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: NotchGeometry.islandSize.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { if island.actions.isEmpty { state.dismissIsland() } }
    }
}

/// Custom idle animation from a user supplied Lottie JSON.
struct IdleLottie: NSViewRepresentable {
    let path: String
    @AppStorage(Prefs.Key.idleLottieSpeed) var speed = 1.0
    @AppStorage(Prefs.Key.idleLottieScale) var scale = 1.0
    @AppStorage(Prefs.Key.idleLottieYOffset) var yOffset = 0.0

    func makeNSView(context: Context) -> LottieAnimationView {
        let v = LottieAnimationView(filePath: path)
        v.loopMode = .loop
        v.contentMode = .scaleAspectFit
        v.play()
        return v
    }

    func updateNSView(_ v: LottieAnimationView, context: Context) {
        v.animationSpeed = speed
        v.wantsLayer = true
        v.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: yOffset).scaledBy(x: scale, y: scale))
        if !v.isAnimationPlaying { v.play() }
    }
}
