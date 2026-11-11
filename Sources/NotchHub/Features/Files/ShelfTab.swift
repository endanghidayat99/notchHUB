import AppKit
import SwiftUI

struct ShelfTab: View {
    @ObservedObject var shelf = ShelfService.shared
    @ObservedObject var drives = DriveService.shared
    @ObservedObject var shots = ScreenshotShelf.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ChipButton(title: L("Zip"), icon: "doc.zipper") { shelf.zip() }
                ChipButton(title: L("Unzip"), icon: "arrow.up.bin") { shelf.unzip() }
                Menu {
                    ForEach(ShelfService.ImageFormat.allCases, id: \.self) { f in Button("Image → \(f.rawValue.uppercased())") { shelf.convertImages(to: f) } }
                    Button("Remove background") { shelf.removeBackground() }
                    Divider()
                    Button("Video → MP4") { shelf.convertMedia(audioOnly: false, fileType: .mp4) }
                    Button("Video → MOV") { shelf.convertMedia(audioOnly: false, fileType: .mov) }
                    Button("Audio → M4A") { shelf.convertMedia(audioOnly: true) }
                } label: { Label(L("Convert"), systemImage: "arrow.triangle.2.circlepath") }
                    .menuStyle(.borderlessButton).frame(width: 100)
                ChipButton(title: "AirDrop", icon: "airplayaudio") { shelf.airdrop() }
                if shelf.busy { ProgressView().controlSize(.small) }
                Spacer()
                ForEach(drives.volumes, id: \.self) { v in ChipButton(title: v.lastPathComponent, icon: "eject.fill") { drives.eject(v) } }
                ChipButton(title: "Clear", icon: "trash") { shelf.clear() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if shelf.files.isEmpty && shots.shots.isEmpty {
                        Label(L("Drop files here"), systemImage: "tray.and.arrow.down")
                            .foregroundColor(.secondary).frame(width: 300, height: 110)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundColor(.secondary))
                    }
                    ForEach(shots.shots, id: \.self) { u in ShelfItem(url: u, isScreenshot: true) }
                    ForEach(shelf.files, id: \.self) { u in ShelfItem(url: u, isScreenshot: false) }
                }
            }
        }
    }
}

struct ShelfItem: View {
    let url: URL
    let isScreenshot: Bool
    @ObservedObject var shelf = ShelfService.shared

    var body: some View {
        let selected = shelf.selection.contains(url)
        VStack(spacing: 4) {
            Group {
                if isScreenshot, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 90, height: 64).clipped().cornerRadius(6)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 54, height: 54)
                }
            }
            Text(url.lastPathComponent).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center).frame(width: 90)
            HStack(spacing: 6) {
                if isScreenshot {
                    Button { ScreenshotShelf.shared.pin(url) } label: { Image(systemName: "pin") }.help("Pin above windows")
                    Button { ScreenshotShelf.shared.markup(url) } label: { Image(systemName: "pencil.tip.crop.circle") }.help("Mark up")
                    Button { ScreenshotShelf.shared.dismiss(url) } label: { Image(systemName: "xmark") }
                } else {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    Button { shelf.remove(url) } label: { Image(systemName: "xmark") }
                }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture { if selected { shelf.selection.remove(url) } else { shelf.selection.insert(url) } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}
