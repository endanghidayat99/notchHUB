import AppKit
import SQLite3
import SwiftUI
import Vision

struct ClipItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image, file }
    var id = UUID()
    var kind: Kind
    var text: String = ""            // text, file path, or OCR text for images
    var imageFile: String? = nil     // PNG stored in app support
    var date = Date()
    var pinned = false
    var linkTitle: String? = nil
    var sourceApp: String? = nil

    var url: URL? {
        guard kind == .text, let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }
    var hexColor: NSColor? { NSColor(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var email: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil ? t : nil
    }
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var body: String
}

final class ClipboardService: ObservableObject {
    static let shared = ClipboardService()

    @Published var items: [ClipItem] = Store.load([ClipItem].self, "clipboard") ?? [] { didSet { scheduleSave() } }
    @Published var snippets: [Snippet] = Store.load([Snippet].self, "snippets") ?? [Snippet(name: "Email signature", body: "Best regards,\nEndang")] { didSet { Store.save(snippets, "snippets") } }
    @Published var stack: [String] = []    // rapid-copy stacking

    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var lastCopy = Date.distantPast
    private var ignoreNext = false
    private var saveWork: DispatchWorkItem?
    private lazy var imageDir: URL = {
        let d = Store.dir.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [items] in Store.save(items, "clipboard") }
        saveWork = w
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if ignoreNext { ignoreNext = false; return }
        // Respect password managers' "concealed" marker.
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let f = urls.first {
            add(ClipItem(kind: .file, text: f.path, sourceApp: app))
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            // Rapid-copy stacking: copies within 3 seconds accumulate into a stack.
            if Date().timeIntervalSince(lastCopy) < 3 { stack.append(s) } else { stack = [s] }
            lastCopy = Date()
            var item = ClipItem(kind: .text, text: s, sourceApp: app)
            if item.url != nil { fetchTitle(for: &item) }
            add(item)
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let name = UUID().uuidString + ".png"
            try? png.write(to: imageDir.appendingPathComponent(name))
            let item = ClipItem(kind: .image, imageFile: name, sourceApp: app)
            add(item)
            if Prefs.bool(Prefs.Key.ocrClipboard) { ocr(item) }
        }
    }

    private func add(_ item: ClipItem) {
        if item.kind != .image, let i = items.firstIndex(where: { $0.kind == item.kind && $0.text == item.text }) {
            var existing = items.remove(at: i)
            existing.date = Date()
            items.insert(existing, at: 0)
            return
        }
        items.insert(item, at: 0)
        let limit = max(20, Prefs.int(Prefs.Key.clipboardLimit))
        while items.filter({ !$0.pinned }).count > limit, let last = items.lastIndex(where: { !$0.pinned }) {
            if let f = items[last].imageFile { try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(f)) }
            items.remove(at: last)
        }
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        return NSImage(contentsOf: imageDir.appendingPathComponent(f))
    }

    // MARK: OCR (Apple Vision, on-device)

    func ocr(_ item: ClipItem) {
        guard let img = image(for: item), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        OCR.recognize(cg) { [weak self] text in
            guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[i].text = text
        }
    }

    private func fetchTitle(for item: inout ClipItem) {
        guard let url = item.url else { return }
        let id = item.id
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let html = String(data: d.prefix(200_000), encoding: .utf8) ?? String(data: d.prefix(200_000), encoding: .isoLatin1),
                  let r = html.range(of: #"<title[^>]*>([^<]{1,200})</title>"#, options: [.regularExpression, .caseInsensitive]) else { return }
            let title = String(html[r]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].linkTitle = title }
            }
        }.resume()
    }

    // MARK: Actions

    func copy(_ item: ClipItem, paste: Bool? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        ignoreNext = true
        switch item.kind {
        case .text: pb.setString(item.text, forType: .string)
        case .file: pb.writeObjects([URL(fileURLWithPath: item.text) as NSURL])
        case .image: if let img = image(for: item) { pb.writeObjects([img]) }
        }
        changeCount = pb.changeCount
        if paste ?? Prefs.bool(Prefs.Key.autoPaste) { autoPaste() }
    }

    func copyText(_ s: String, paste: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        if paste { autoPaste() }
    }

    func pasteStack() { copyText(stack.joined(separator: "\n"), paste: true); stack = [] }

    /// Auto-paste: close the notch so the previous app regains focus, then send ⌘V (needs Accessibility).
    func autoPaste() {
        AppState.shared.close()
        guard AX.trusted else { AX.promptIfNeeded(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Keys.pasteCommandV() }
    }

    func togglePin(_ item: ClipItem) {
        if let i = items.firstIndex(of: item) { items[i].pinned.toggle() }
    }

    func delete(_ item: ClipItem) { items.removeAll { $0.id == item.id } }

    func clearUnpinned() { items.removeAll { !$0.pinned } }

    func search(_ q: String) -> [ClipItem] {
        let sorted = items.sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.linkTitle ?? "").localizedCaseInsensitiveContains(q) }
    }

    // MARK: Import from Maccy / Alfred (SQLite)

    @discardableResult
    func importMaccy() -> Int {
        let path = NSHomeDirectory() + "/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"
        let rows = SQLiteReader.strings(path: path, sql: "SELECT ZVALUE FROM ZHISTORYITEMCONTENT WHERE ZTYPE = 'public.utf8-plain-text' ORDER BY Z_PK DESC LIMIT 500")
        for r in rows.reversed() where !items.contains(where: { $0.text == r }) { items.insert(ClipItem(kind: .text, text: r, sourceApp: "Maccy"), at: 0) }
        return rows.count
    }

    @discardableResult
    func importAlfred() -> Int {
        let path = NSHomeDirectory() + "/Library/Application Support/Alfred/Databases/clipboard.alfdb"
        let rows = SQLiteReader.strings(path: path, sql: "SELECT item FROM clipboard WHERE dataType = 0 ORDER BY ts DESC LIMIT 500")
        for r in rows.reversed() where !items.contains(where: { $0.text == r }) { items.insert(ClipItem(kind: .text, text: r, sourceApp: "Alfred"), at: 0) }
        return rows.count
    }
}

enum SQLiteReader {
    static func strings(path: String, sql: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) == SQLITE_BLOB, let b = sqlite3_column_blob(stmt, 0) {
                let d = Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, 0)))
                if let s = String(data: d, encoding: .utf8) { out.append(s) }
            } else if let c = sqlite3_column_text(stmt, 0) {
                out.append(String(cString: c))
            }
        }
        return out
    }

    static func rows(path: String, sql: String) -> [[Any?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let b = sqlite3_column_blob(stmt, i)
                    row.append(b.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, i))) })
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }
}

enum OCR {
    static func recognize(_ cg: CGImage, completion: @escaping (String) -> Void) {
        let req = VNRecognizeTextRequest { r, _ in
            let text = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            DispatchQueue.main.async { completion(text) }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cg).perform([req])
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 { r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255; a = 1 }
        else { r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255; b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255 }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
