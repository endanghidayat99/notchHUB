import CoreAudio
import CoreMediaIO
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isOutput: Bool
    let isInput: Bool
}

/// CoreAudio wrapper: device switching, master volume, mic mute, "in use" detection.
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    @Published var outputs: [AudioDevice] = []
    @Published var inputs: [AudioDevice] = []
    @Published var defaultOutput: AudioDeviceID = 0
    @Published var defaultInput: AudioDeviceID = 0
    @Published var volume: Float = 0
    @Published var muted = false
    @Published var micMuted = false
    @Published var micInUse = false
    @Published var cameraInUse = false

    var onVolumeChange: ((Float, Bool) -> Void)?
    private var pollTimer: Timer?

    func start() {
        refresh()
        addListener(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() }
        addListener(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
        addListener(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollUsage() }
    }

    // MARK: Generic property helpers

    private func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    private func addListener(_ obj: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ block: @escaping () -> Void) {
        var a = addr(selector, scope)
        AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main) { _, _ in block() }
    }

    private func getDeviceIDs() -> [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids
    }

    private func name(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "Device \(id)" }
        return n as String
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
        var a = addr(sel)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    func refresh() {
        let all = getDeviceIDs().map { id -> AudioDevice in
            AudioDevice(id: id, name: name(id),
                        isOutput: channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0,
                        isInput: channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0)
        }
        outputs = all.filter(\.isOutput)
        inputs = all.filter(\.isInput)
        let oldOut = defaultOutput
        defaultOutput = getDefault(kAudioHardwarePropertyDefaultOutputDevice)
        defaultInput = getDefault(kAudioHardwarePropertyDefaultInputDevice)
        if oldOut != defaultOutput {
            addListener(defaultOutput, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.readVolume(notify: true) }
            addListener(defaultOutput, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.readVolume(notify: true) }
        }
        readVolume(notify: false)
        micMuted = getMute(defaultInput, scope: kAudioDevicePropertyScopeInput)
    }

    func setDefault(_ id: AudioDeviceID, output: Bool) {
        var a = addr(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        refresh()
    }

    // MARK: Volume

    private func scalar(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var a = addr(kAudioDevicePropertyVolumeScalar, scope, el)
            guard AudioObjectHasProperty(id, &a) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    private func readVolume(notify: Bool) {
        let v = scalar(defaultOutput, scope: kAudioDevicePropertyScopeOutput) ?? 0
        let m = getMute(defaultOutput, scope: kAudioDevicePropertyScopeOutput)
        let changed = abs(v - volume) > 0.001 || m != muted
        volume = v; muted = m
        if notify && changed { onVolumeChange?(v, m) }
    }

    func setVolume(_ v: Float) {
        let val = min(1, max(0, v))
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            guard AudioObjectHasProperty(defaultOutput, &a) else { continue }
            var f = Float32(val)
            AudioObjectSetPropertyData(defaultOutput, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &f)
        }
        if muted && val > 0 { setMute(false) }
        readVolume(notify: true)
    }

    private func getMute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var a = addr(kAudioDevicePropertyMute, scope)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m)
        return m != 0
    }

    func setMute(_ on: Bool) {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var m: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(defaultOutput, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        readVolume(notify: true)
    }

    /// Mutes the default input for all apps (falls back to input volume 0 when the device has no mute control).
    func setMicMuted(_ on: Bool) {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(defaultInput, &a) {
            var m: UInt32 = on ? 1 : 0
            AudioObjectSetPropertyData(defaultInput, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        } else {
            var va = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
            var f: Float32 = on ? 0 : 0.75
            AudioObjectSetPropertyData(defaultInput, &va, 0, nil, UInt32(MemoryLayout<Float32>.size), &f)
        }
        micMuted = on
        AppState.shared.show(Island(kind: .hud, icon: on ? "mic.slash.fill" : "mic.fill", title: on ? "Microphone muted" : "Microphone on",
                                    tint: on ? .red : .green, duration: 1.5))
    }

    // MARK: Privacy indicator

    private func pollUsage() {
        guard Prefs.bool(Prefs.Key.privacyIndicator) else { return }
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var mic = false
        for d in inputs {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d.id, &a, 0, nil, &size, &running) == noErr, running != 0 { mic = true; break }
        }
        let cam = Self.cameraRunning()
        if mic != micInUse || cam != cameraInUse {
            micInUse = mic; cameraInUse = cam
            if mic || cam {
                let icon = cam ? "video.fill" : "mic.fill"
                AppState.shared.setActivity(LiveActivity(id: "9-privacy", icon: icon, text: cam && mic ? "Cam + Mic" : (cam ? "Camera" : "Mic"),
                                                         tint: cam ? .green : .orange))
            } else {
                AppState.shared.clearActivity("9-privacy")
            }
        }
    }

    static func cameraRunning() -> Bool {
        var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                          mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                          mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, &size) == noErr else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, size, &used, &ids)
        for id in ids {
            var ra = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                               mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                               mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &ra, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}
