import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

// MARK: - Synced lyrics (LRCLIB, free & keyless)

struct LyricLine: Identifiable {
    let id = UUID()
    let time: Double
    let text: String
}

final class LyricsService: ObservableObject {
    static let shared = LyricsService()
    @Published var lines: [LyricLine] = []
    @Published var plain: String = ""
    @Published var loading = false
    private var key = ""

    func trackChanged(title: String, artist: String, album: String, duration: Double) {
        guard Prefs.bool(Prefs.Key.lyricsEnabled) else { return }
        let k = "\(title)|\(artist)"
        guard k != key, !title.isEmpty else { return }
        key = k
        lines = []; plain = ""; loading = true
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                            .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration)))]
        var req = URLRequest(url: comps.url!)
        req.setValue("NotchHub/1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] d, _, _ in
            guard let self else { return }
            var synced = "", plainText = ""
            if let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                synced = obj["syncedLyrics"] as? String ?? ""
                plainText = obj["plainLyrics"] as? String ?? ""
            }
            let parsed = Self.parseLRC(synced)
            DispatchQueue.main.async {
                guard self.key == k else { return }
                self.lines = parsed; self.plain = plainText; self.loading = false
            }
        }.resume()
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in s.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(time: mm * 60 + ss, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    func currentIndex(at t: Double) -> Int? {
        lines.lastIndex(where: { $0.time <= t + 0.25 })
    }
}

struct LyricsView: View {
    @ObservedObject var lyrics = LyricsService.shared
    @ObservedObject var media = MediaService.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if lyrics.loading { ProgressView().controlSize(.small) }
                    if lyrics.lines.isEmpty && !lyrics.plain.isEmpty {
                        Text(lyrics.plain).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    let idx = lyrics.currentIndex(at: media.position)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { i, line in
                        if i == idx {
                            WordHighlightLine(line: line, next: i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].time : line.time + 4,
                                              position: media.position)
                                .id(line.id)
                        } else {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(i < (idx ?? 0) ? 0.35 : 0.55))
                                .id(line.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lyrics.currentIndex(at: media.position)) { i in
                guard let i, i < lyrics.lines.count else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(lyrics.lines[i].id, anchor: .center) }
            }
        }
    }
}

/// LRCLIB provides line timing; words are highlighted by interpolating across the line's duration.
struct WordHighlightLine: View {
    let line: LyricLine
    let next: Double
    let position: Double

    var body: some View {
        let words = line.text.split(separator: " ").map(String.init)
        let span = max(0.5, next - line.time)
        let frac = min(1, max(0, (position - line.time) / span))
        let lit = Int((Double(words.count) * frac).rounded(.up))
        HStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                Text(w).foregroundColor(i < lit ? .white : .white.opacity(0.45))
            }
        }
        .font(.system(size: 15, weight: .bold))
    }
}

// MARK: - Live audio spectrum (system audio via ScreenCaptureKit + Goertzel bands)

final class SpectrumService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = SpectrumService()
    @Published var bands = [Float](repeating: 0, count: 24)
    @Published var running = false
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "notchhub.spectrum")
    private let freqs: [Float] = (0..<24).map { 40 * pow(2, Float($0) * 0.38) }

    func start() {
        guard stream == nil else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.sampleRate = 48000
                cfg.channelCount = 1
                cfg.width = 2; cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s
                await MainActor.run { self.running = true }
            } catch {
                NSLog("Spectrum unavailable: \(error)")
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        running = false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.stream = nil; self.running = false }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = abl.mBuffers.mData else { return }
        let n = min(1024, Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
        guard n > 64 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let sr: Float = 48000
        var out = [Float](repeating: 0, count: freqs.count)
        for (i, f) in freqs.enumerated() {
            let k = 2 * cos(2 * Float.pi * f / sr)
            var s1: Float = 0, s2: Float = 0
            for j in 0..<n {
                let s0 = samples[j] + k * s1 - s2
                s2 = s1; s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - k * s1 * s2
            out[i] = min(1, sqrt(max(0, power)) / Float(n) * 18)
        }
        DispatchQueue.main.async {
            self.bands = zip(self.bands, out).map { max($1, $0 * 0.82) }
        }
    }
}

struct SpectrumBars: View {
    var compact = false
    @ObservedObject var s = SpectrumService.shared
    var body: some View {
        GeometryReader { g in
            let bands = compact ? stride(from: 0, to: s.bands.count, by: 4).map { s.bands[$0] } : s.bands
            HStack(alignment: .bottom, spacing: compact ? 2 : 3) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, v in
                    Capsule().fill(LinearGradient(colors: [.green, .mint], startPoint: .bottom, endPoint: .top))
                        .frame(height: max(2, g.size.height * CGFloat(v)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
