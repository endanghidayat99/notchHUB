import Foundation
import SwiftUI

/// Per-turn cost estimate for the Claude Code Stop hook (reads the turn's transcript locally).
enum AICost {
    // Approximate public list prices, USD per million tokens (input, output). Cache write = 1.25×, read = 0.1× input.
    static let prices: [(String, Double, Double)] = [
        ("opus-4-5", 5, 25), ("opus-4-6", 5, 25), ("opus", 15, 75), ("sonnet", 3, 15), ("haiku-4-5", 1, 5), ("haiku", 0.8, 4),
    ]

    static func price(_ model: String) -> (Double, Double) {
        let m = model.lowercased()
        return prices.first { m.contains($0.0) }.map { ($0.1, $0.2) } ?? (3, 15)
    }

    static func cost(_ usage: [String: Any], model: String) -> Double {
        let i = Double(usage["input_tokens"] as? Int ?? 0)
        let o = Double(usage["output_tokens"] as? Int ?? 0)
        let cw = Double(usage["cache_creation_input_tokens"] as? Int ?? 0)
        let cr = Double(usage["cache_read_input_tokens"] as? Int ?? 0)
        let p = price(model)
        return (i * p.0 + o * p.1 + cw * p.0 * 1.25 + cr * p.0 * 0.1) / 1_000_000
    }

    /// Cost of the last assistant turn in a transcript.
    static func lastTurnCost(transcript: String) -> Double {
        guard let s = try? String(contentsOfFile: (transcript as NSString).expandingTildeInPath, encoding: .utf8) else { return 0 }
        var total = 0.0
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if o["type"] as? String == "user", let m = o["message"] as? [String: Any], m["content"] is String { break }
            if let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] { total += cost(u, model: m["model"] as? String ?? "") }
        }
        return total
    }
}

/// AI tab: agent activity only (Claude Code / Codex hooks via the local Developer API).
struct AITab: View {
    @ObservedObject var agents = AgentCenter.shared

    var body: some View {
        Card(title: "Agents") {
            HStack {
                if let c = agents.lastTurnCost { Text(String(format: "Last Claude Code turn ≈ $%.3f", c)).font(.caption) }
                Spacer()
                if !agents.events.isEmpty {
                    Button("Clear") { agents.events.removeAll() }.buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if agents.events.isEmpty {
                        Text("Install hooks in Settings › Developer to see Claude Code / Codex activity.").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(agents.events.prefix(50)) { e in
                        HStack(alignment: .top) {
                            Image(systemName: e.icon).foregroundColor(.purple).frame(width: 16)
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(e.date, style: .time).font(.system(size: 9)).foregroundColor(.secondary)
                                }
                                if !e.detail.isEmpty { Text(e.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2) }
                            }
                        }
                    }
                }
            }
        }
    }
}
