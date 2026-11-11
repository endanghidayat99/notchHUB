import AppKit
import SwiftUI

struct NowPlayingCard: View {
    @ObservedObject var media = MediaService.shared
    var artSize: CGFloat = 86
    var showExtras = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let a = media.artwork { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
                else { ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").foregroundColor(.secondary) } }
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(media.hasTrack ? media.title : L("Nothing playing")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(media.artist).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                if media.hasTrack {
                    Slider(value: Binding(get: { media.position }, set: { media.seek($0) }), in: 0...max(1, media.duration))
                        .controlSize(.mini)
                    HStack {
                        Text(formatDuration(media.position)); Spacer(); Text("-" + formatDuration(media.duration - media.position))
                    }
                    .font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                }
                HStack(spacing: 14) {
                    Button { media.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundColor(media.shuffle ? .green : .secondary) }
                    Button { media.previous() } label: { Image(systemName: "backward.fill") }
                    Button { media.playPause() } label: { Image(systemName: media.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18)) }
                    Button { media.next() } label: { Image(systemName: "forward.fill") }
                    Button { media.toggleRepeat() } label: { Image(systemName: "repeat").foregroundColor(media.repeatOn ? .green : .secondary) }
                    if showExtras && media.player == .music {
                        Button { media.toggleFavorite() } label: { Image(systemName: media.favorited ? "star.fill" : "star") }
                    }
                }
                .buttonStyle(.plain)
                if showExtras {
                    HStack {
                        Image(systemName: "speaker.fill").font(.caption2)
                        Slider(value: Binding(get: { media.volume }, set: { media.setVolume($0) }), in: 0...100).controlSize(.mini)
                    }
                }
            }
        }
    }
}

struct MediaTab: View {
    @ObservedObject var media = MediaService.shared
    @ObservedObject var audio = AudioDevices.shared
    @ObservedObject var spectrum = SpectrumService.shared
    @AppStorage(Prefs.Key.lyricsEnabled) var lyricsOn = true
    @Local private var rate = 1.0
    @Local private var pane = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                NowPlayingCard()
                if spectrum.running { SpectrumBars().frame(height: 26) }
            }
            .frame(width: 290)

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $pane) {
                    Text("Lyrics").tag(0); Text("Output").tag(1); Text("Speed").tag(2); Text("Devices").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch pane {
                case 0:
                    if lyricsOn { LyricsView() } else { Text("Lyrics disabled in Settings").foregroundColor(.secondary) }
                case 1:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(audio.outputs) { d in
                                Button { audio.setDefault(d.id, output: true) } label: {
                                    HStack { Image(systemName: d.id == audio.defaultOutput ? "checkmark.circle.fill" : "circle"); Text(d.name) }
                                }.buttonStyle(.plain)
                            }
                            Divider()
                            HStack {
                                Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0...1)
                            }
                            Text("Per-app mixer & EQ: see Settings › Media (requires macOS 14.4 process taps).")
                                .font(.caption2).foregroundColor(.secondary)
                        }.font(.system(size: 12))
                    }
                case 2:
                    VStack(alignment: .leading) {
                        Text("Browser video speed: \(String(format: "%.2fx", rate))").font(.system(size: 12))
                        Slider(value: $rate, in: 0.25...4, step: 0.25) { _ in media.setBrowserPlaybackRate(rate) }
                        HStack { ForEach([1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { r in ChipButton(title: "\(r)x", active: rate == r) { rate = r; media.setBrowserPlaybackRate(r) } } }
                        Text("Chrome, Brave, Edge, Vivaldi, Safari — enable “Allow JavaScript from Apple Events”.").font(.caption2).foregroundColor(.secondary)
                    }
                default:
                    BatteryList()
                }
            }
        }
    }
}

// MARK: - Floating player (4 sizes) & menu bar player

final class FloatingPlayer {
    static let shared = FloatingPlayer()
    private var window: NSPanel?

    static let sizes: [CGSize] = [CGSize(width: 220, height: 70), CGSize(width: 300, height: 110),
                                  CGSize(width: 380, height: 150), CGSize(width: 460, height: 190)]

    func update() {
        if Prefs.bool(Prefs.Key.floatingPlayer) { show() } else { window?.orderOut(nil); window = nil }
    }

    private func show() {
        let size = Self.sizes[min(3, max(0, Prefs.int(Prefs.Key.floatingPlayerSize)))]
        let w = window ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: NowPlayingCard(artSize: size.height - 24, showExtras: size.height > 100)
            .padding(12).preferredColorScheme(.dark).background(VisualEffect(material: .hudWindow)))
        w.setContentSize(size)
        if window == nil, let s = NSScreen.main { w.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - size.width - 20, y: s.visibleFrame.minY + 20)) }
        w.orderFrontRegardless()
        window = w
    }
}

final class MenuBarPlayer: NSObject {
    static let shared = MenuBarPlayer()
    private var item: NSStatusItem?
    private let popover = NSPopover()

    func update() {
        if Prefs.bool(Prefs.Key.menuBarPlayer) {
            guard item == nil else { return }
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing")
            it.button?.target = self
            it.button?.action = #selector(toggle)
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 360, height: 400)
            popover.contentViewController = NSHostingController(rootView: VStack(alignment: .leading) {
                NowPlayingCard(artSize: 110)
                Divider()
                LyricsView().frame(height: 220)
            }.padding(14).frame(width: 360).preferredColorScheme(.dark))
            item = it
        } else if let it = item {
            NSStatusBar.system.removeStatusItem(it); item = nil
        }
    }

    @objc private func toggle() {
        guard let b = item?.button else { return }
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
    }
}
