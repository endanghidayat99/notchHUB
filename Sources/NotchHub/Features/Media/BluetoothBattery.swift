import Foundation
import IOBluetooth
import SwiftUI

struct BTDeviceBattery: Identifiable, Hashable {
    var id: String { address.isEmpty ? name : address }
    let name: String
    let address: String
    var level: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var connected: Bool
    var isAirPods: Bool { left != nil || right != nil || name.localizedCaseInsensitiveContains("airpods") }
}

/// Batteries for AirPods (per bud + case), Magic peripherals and third-party BT HID devices.
final class BluetoothBattery: ObservableObject {
    static let shared = BluetoothBattery()
    @Published var devices: [BTDeviceBattery] = []
    private var timer: Timer?
    private var lastCaseSeen = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            var list = Self.fromSystemProfiler()
            // Apple / HID peripherals publish BatteryPercent in the IORegistry.
            for (name, pct) in Self.fromIORegistry() where !list.contains(where: { $0.name == name }) {
                list.append(BTDeviceBattery(name: name, address: "", level: pct, connected: true))
            }
            DispatchQueue.main.async {
                let hadCase = self.devices.contains { $0.caseLevel != nil }
                self.devices = list
                let hasCase = list.contains { $0.caseLevel != nil }
                if hasCase && !hadCase, let a = list.first(where: { $0.caseLevel != nil }) {
                    // Case detection: AirPods case opened near the Mac.
                    AppState.shared.show(Island(kind: .info, icon: "airpodspro", title: a.name,
                                                subtitle: "L \(a.left.map { "\($0)%" } ?? "–")  R \(a.right.map { "\($0)%" } ?? "–")  Case \(a.caseLevel.map { "\($0)%" } ?? "–")",
                                                duration: 4))
                }
            }
        }
    }

    private static func pct(_ v: Any?) -> Int? {
        guard let s = v as? String else { return v as? Int }
        return Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    static func fromSystemProfiler() -> [BTDeviceBattery] {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let d = r.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [BTDeviceBattery] = []
        for section in arr {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                guard let devs = section[key] as? [[String: Any]] else { continue }
                for entry in devs {
                    for (name, infoAny) in entry {
                        guard let info = infoAny as? [String: Any] else { continue }
                        let addr = info["device_address"] as? String ?? ""
                        let dev = BTDeviceBattery(name: name, address: addr,
                                                  level: pct(info["device_batteryLevelMain"]),
                                                  left: pct(info["device_batteryLevelLeft"]),
                                                  right: pct(info["device_batteryLevelRight"]),
                                                  caseLevel: pct(info["device_batteryLevelCase"]),
                                                  connected: connected)
                        if connected || dev.isAirPods { out.append(dev) }
                    }
                }
            }
        }
        return out
    }

    static func fromIORegistry() -> [(String, Int)] {
        let r = Shell.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-l"])
        var out: [(String, Int)] = []
        var name: String?
        for line in r.out.components(separatedBy: .newlines) {
            if line.contains("\"Product\" =") {
                name = line.components(separatedBy: "= ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            if line.contains("\"BatteryPercent\" ="), let n = name,
               let v = Int(line.components(separatedBy: "= ").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                out.append((n, v)); name = nil
            }
        }
        return out
    }

    /// One-tap connect (AirPods or any paired device).
    func connect(_ d: BTDeviceBattery) {
        guard !d.address.isEmpty, let dev = IOBluetoothDevice(addressString: d.address) else { return }
        DispatchQueue.global().async {
            let r = d.connected ? dev.closeConnection() : dev.openConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
            if r != kIOReturnSuccess { NSLog("BT connect result \(r)") }
        }
    }
}

struct BatteryList: View {
    @ObservedObject var bt = BluetoothBattery.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if bt.devices.isEmpty { Text("No Bluetooth devices").font(.caption).foregroundColor(.secondary) }
            ForEach(bt.devices) { d in
                HStack {
                    Image(systemName: d.isAirPods ? "airpodspro" : "keyboard")
                    Text(d.name).lineLimit(1)
                    Spacer()
                    if d.isAirPods {
                        Text("L \(d.left.map(String.init) ?? "–")  R \(d.right.map(String.init) ?? "–")  C \(d.caseLevel.map(String.init) ?? "–")")
                            .font(.caption.monospacedDigit())
                    } else if let l = d.level { Text("\(l)%").font(.caption.monospacedDigit()) }
                    if !d.address.isEmpty {
                        Button(d.connected ? "Disconnect" : "Connect") { bt.connect(d) }.controlSize(.mini)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }
}
