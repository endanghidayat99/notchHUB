import AVFoundation
import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

final class ShelfService: NSObject, ObservableObject, NSSharingServiceDelegate {
    static let shared = ShelfService()

    @Published var files: [URL] = (Store.load([String].self, "shelf") ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } {
        didSet { Store.save(files.map(\.path), "shelf") }
    }
    @Published var selection = Set<URL>() { didSet { Store.save(selection.map(\.path), "shelfSelection") } }
    @Published var busy = false

    override init() {
        super.init()
        selection = Set((Store.load([String].self, "shelfSelection") ?? []).map { URL(fileURLWithPath: $0) })
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self.add([url]) }
            }
        }
        DispatchQueue.main.async {
            AppState.shared.isDropTargeted = false
            AppState.shared.show(Island(kind: .info, icon: "tray.and.arrow.down.fill", title: "Added to Shelf", subtitle: "\(providers.count) item(s)", tint: .blue, duration: 1.4))
        }
    }

    func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
    }

    func remove(_ u: URL) { files.removeAll { $0 == u }; selection.remove(u) }
    func clear() { files.removeAll(); selection.removeAll() }

    var targets: [URL] { selection.isEmpty ? files : files.filter { selection.contains($0) } }

    // MARK: Zip / Unzip (ditto)

    func zip() {
        let t = targets
        guard !t.isEmpty else { return }
        busy = true
        DispatchQueue.global().async {
            let dest: URL
            if t.count == 1 {
                dest = t[0].deletingPathExtension().appendingPathExtension("zip")
                Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", t[0].path, dest.path])
            } else {
                // Stage multiple files into a temp folder then compress it.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Archive-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                for f in t { try? FileManager.default.copyItem(at: f, to: tmp.appendingPathComponent(f.lastPathComponent)) }
                dest = t[0].deletingLastPathComponent().appendingPathComponent("Archive.zip")
                Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", tmp.path, dest.path])
            }
            DispatchQueue.main.async { self.busy = false; self.add([dest]); self.done("Zipped", dest) }
        }
    }

    func unzip() {
        let zips = targets.filter { $0.pathExtension.lowercased() == "zip" }
        guard !zips.isEmpty else { return }
        busy = true
        DispatchQueue.global().async {
            var outs: [URL] = []
            for z in zips {
                let dest = z.deletingPathExtension()
                Shell.run("/usr/bin/ditto", ["-x", "-k", z.path, dest.path])
                outs.append(dest)
            }
            DispatchQueue.main.async { self.busy = false; self.add(outs); self.done("Unzipped", outs.first) }
        }
    }

    // MARK: Converters (offline)

    enum ImageFormat: String, CaseIterable { case png, jpeg, tiff, heic
        var uti: CFString {
            switch self {
            case .png: return UTType.png.identifier as CFString
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .tiff: return UTType.tiff.identifier as CFString
            case .heic: return UTType.heic.identifier as CFString
            }
        }
        var ext: String { self == .jpeg ? "jpg" : rawValue }
    }

    func convertImages(to fmt: ImageFormat) {
        let t = targets
        busy = true
        DispatchQueue.global().async {
            var outs: [URL] = []
            for src in t {
                let images: [CGImage]
                if src.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: src) {
                    images = (0..<doc.pageCount).compactMap { doc.page(at: $0).flatMap(Self.render) }
                } else if let s = CGImageSourceCreateWithURL(src as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) {
                    images = [img]
                } else { continue }
                for (i, img) in images.enumerated() {
                    let name = src.deletingPathExtension().lastPathComponent + (images.count > 1 ? "-\(i + 1)" : "")
                    let dest = src.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(fmt.ext)
                    guard let d = CGImageDestinationCreateWithURL(dest as CFURL, fmt.uti, 1, nil) else { continue }
                    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    if CGImageDestinationFinalize(d) { outs.append(dest) }
                }
            }
            DispatchQueue.main.async { self.busy = false; self.add(outs); self.done("Converted \(outs.count) file(s)", outs.first) }
        }
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let r = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let img = NSImage(size: NSSize(width: r.width * scale, height: r.height * scale))
        img.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: img.size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Background removal with Vision foreground instance masks (macOS 14+).
    func removeBackground() {
        guard #available(macOS 14.0, *) else { done("Background removal needs macOS 14", nil); return }
        let t = targets
        busy = true
        DispatchQueue.global().async {
            var outs: [URL] = []
            for src in t {
                guard let s = CGImageSourceCreateWithURL(src as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
                let req = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cg)
                guard (try? handler.perform([req])) != nil, let res = req.results?.first,
                      let buf = try? res.generateMaskedImage(ofInstances: res.allInstances, from: handler, croppedToInstancesExtent: false) else { continue }
                let ci = CIImage(cvPixelBuffer: buf)
                let ctx = CIContext()
                let dest = src.deletingPathExtension().appendingPathExtension("nobg.png")
                if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
                    try? ctx.writePNGRepresentation(of: ci, to: dest, format: .RGBA8, colorSpace: cs)
                    outs.append(dest)
                }
            }
            DispatchQueue.main.async { self.busy = false; self.add(outs); self.done("Background removed", outs.first) }
        }
    }

    /// Video → MP4 / MOV, audio → M4A via AVFoundation presets.
    func convertMedia(audioOnly: Bool, fileType: AVFileType = .mp4) {
        let t = targets
        busy = true
        let group = DispatchGroup()
        var outs: [URL] = []
        for src in t {
            let asset = AVURLAsset(url: src)
            let preset = audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let ext = audioOnly ? "m4a" : (fileType == .mov ? "mov" : "mp4")
            let dest = src.deletingPathExtension().appendingPathExtension("converted.\(ext)")
            try? FileManager.default.removeItem(at: dest)
            ex.outputURL = dest
            ex.outputFileType = audioOnly ? .m4a : fileType
            group.enter()
            ex.exportAsynchronously {
                if ex.status == .completed { outs.append(dest) }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.busy = false; self.add(outs); self.done("Converted \(outs.count) file(s)", outs.first) }
    }

    // MARK: AirDrop

    func airdrop() {
        guard let svc = NSSharingService(named: .sendViaAirDrop) else { return }
        svc.delegate = self
        let t = targets
        if svc.canPerform(withItems: t) { svc.perform(withItems: t) }
    }

    func sharingService(_ s: NSSharingService, didShareItems items: [Any]) {
        AppState.shared.show(Island(kind: .info, icon: "checkmark.circle.fill", title: "AirDrop sent", subtitle: "\(items.count) item(s)", tint: .blue))
    }

    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        AppState.shared.show(Island(kind: .info, icon: "xmark.octagon.fill", title: "AirDrop failed", subtitle: error.localizedDescription, tint: .red))
    }

    func sharingService(_ s: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        NotchWindowController.shared?.interactiveRect ?? .zero
    }

    private func done(_ title: String, _ url: URL?) {
        AppState.shared.show(Island(kind: .info, icon: "checkmark.circle.fill", title: title, subtitle: url?.lastPathComponent ?? "", tint: .green, duration: 2))
    }
}

// MARK: - Drives

final class DriveService: ObservableObject {
    static let shared = DriveService()
    @Published var volumes: [URL] = []

    func start() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            self?.refresh()
            if let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                AppState.shared.show(Island(kind: .info, icon: "externaldrive.fill", title: u.lastPathComponent, subtitle: "Drive connected", tint: .blue,
                                            actions: [IslandAction(title: L("Eject")) { self?.eject(u) }], duration: 4))
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).filter { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (v?.volumeIsEjectable == true || v?.volumeIsRemovable == true) && v?.volumeIsInternal != true
        }
    }

    func eject(_ u: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: u)
            AppState.shared.show(Island(kind: .info, icon: "eject.fill", title: "\(u.lastPathComponent) ejected", tint: .green))
        } catch {
            AppState.shared.show(Island(kind: .info, icon: "exclamationmark.triangle.fill", title: "Couldn't eject", subtitle: error.localizedDescription, tint: .orange))
        }
        refresh()
    }
}

// MARK: - Download alerts (works with any browser: watches ~/Downloads)

final class DownloadWatcher {
    static let shared = DownloadWatcher()
    private var known = Set<String>()
    private var partial = Set<String>()
    private var timer: Timer?
    private let partialExt = ["crdownload", "download", "part", "partial", "opdownload"]
    private var dir: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    func start() {
        known = Set(list())
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func list() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    private func poll() {
        guard Prefs.bool(Prefs.Key.downloadAlerts) else { return }
        let now = Set(list())
        let inProgress = now.filter { partialExt.contains(($0 as NSString).pathExtension.lowercased()) }
        if !inProgress.isEmpty {
            AppState.shared.setActivity(LiveActivity(id: "5-download", icon: "arrow.down.circle", text: "\(inProgress.count) downloading", tint: .blue))
        } else {
            AppState.shared.clearActivity("5-download")
        }
        let added = now.subtracting(known).filter { !partialExt.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
        for name in added {
            let url = dir.appendingPathComponent(name)
            AppState.shared.show(Island(kind: .download, icon: "arrow.down.circle.fill", title: "Download finished", subtitle: name, tint: .blue,
                                        actions: [IslandAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                                                  IslandAction(title: "Shelf") { ShelfService.shared.add([url]) }], duration: 5))
        }
        partial = inProgress
        known = now
    }
}
