import AppKit
import SwiftUI

struct ClipboardTab: View {
    @ObservedObject var c = ClipboardService.shared
    @Local private var query = ""
    @Local private var showSnippets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search clipboard (also text inside images)…", text: $query).textFieldStyle(.plain)
                if c.stack.count > 1 { ChipButton(title: "Paste stack (\(c.stack.count))", icon: "square.stack.3d.up") { c.pasteStack() } }
                ChipButton(title: "Snippets", icon: "text.badge.plus", active: showSnippets) { showSnippets.toggle() }
                Menu {
                    Button("Import from Maccy") { _ = c.importMaccy() }
                    Button("Import from Alfred") { _ = c.importAlfred() }
                    Divider()
                    Button("Clear unpinned", role: .destructive) { c.clearUnpinned() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

            if showSnippets { SnippetsEditor() } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(c.search(query)) { item in ClipCard(item: item) }
                    }
                }
            }
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    @ObservedObject var c = ClipboardService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.kind == .image ? "photo" : item.kind == .file ? "doc" : item.url != nil ? "link" : "text.alignleft")
                Text(item.sourceApp ?? "").lineLimit(1)
                Spacer()
                if item.pinned { Image(systemName: "pin.fill").foregroundColor(.yellow) }
            }
            .font(.system(size: 9)).foregroundColor(.secondary)

            Group {
                if item.kind == .image, let img = c.image(for: item) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 90)
                } else if let color = item.hexColor {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color)).frame(height: 50)
                    Text(item.text).font(.system(size: 11, design: .monospaced))
                } else if item.url != nil {
                    // Link card
                    Text(item.linkTitle ?? item.url?.host ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(item.text).font(.system(size: 10)).foregroundColor(.blue).lineLimit(2)
                } else {
                    Text(item.kind == .file ? (item.text as NSString).lastPathComponent : item.text)
                        .font(.system(size: 11)).lineLimit(6)
                }
            }
            Spacer(minLength: 0)
            // Smart actions
            HStack(spacing: 6) {
                Button { c.copy(item) } label: { Image(systemName: "doc.on.doc") }.help(L("Copy"))
                Button { c.copy(item, paste: true) } label: { Image(systemName: "arrow.down.doc") }.help("Paste")
                if let u = item.url { Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }.help("Open link") }
                if let e = item.email, let u = URL(string: "mailto:\(e)") { Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "envelope") }.help("Compose email") }
                if let col = item.hexColor {
                    Button { c.copyText("rgb(\(Int(col.redComponent * 255)), \(Int(col.greenComponent * 255)), \(Int(col.blueComponent * 255)))") } label: { Image(systemName: "paintpalette") }.help("Copy as RGB")
                }
                if item.kind == .file { Button { ShelfService.shared.add([URL(fileURLWithPath: item.text)]) } label: { Image(systemName: "tray.and.arrow.down") }.help("Add to shelf") }
                Spacer()
                Button { c.togglePin(item) } label: { Image(systemName: item.pinned ? "pin.slash" : "pin") }.help(L("Pin"))
                Button { c.delete(item) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.plain).font(.system(size: 11))
        }
        .padding(8)
        .frame(width: 170, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .onTapGesture(count: 2) { c.copy(item, paste: true) }
        .onDrag {
            switch item.kind {
            case .file: return NSItemProvider(contentsOf: URL(fileURLWithPath: item.text)) ?? NSItemProvider()
            case .image: return c.image(for: item).map { NSItemProvider(object: $0) } ?? NSItemProvider()
            case .text: return NSItemProvider(object: item.text as NSString)
            }
        }
    }
}

struct SnippetsEditor: View {
    @ObservedObject var c = ClipboardService.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($c.snippets) { $s in
                    HStack(alignment: .top) {
                        TextField("Name", text: $s.name).frame(width: 120)
                        TextField("Body", text: $s.body, axis: .vertical)
                        Button { c.copyText(s.body, paste: true) } label: { Image(systemName: "arrow.down.doc") }
                        Button { c.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                    }
                    .textFieldStyle(.roundedBorder).buttonStyle(.plain).font(.system(size: 11))
                }
                Button("Add snippet") { c.snippets.append(Snippet(name: "New", body: "")) }
            }
        }
    }
}
