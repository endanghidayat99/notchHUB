import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        AppState.shared.close()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "NotchHub " + L("Settings")
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MediaSettings().tabItem { Label("Media", systemImage: "music.note") }
            SystemSettings().tabItem { Label("System", systemImage: "cpu") }
            ProductivitySettings().tabItem { Label("Productivity", systemImage: "checklist") }
            PrayerSettings().tabItem { Label(L10n.lang == "id" ? "Sholat" : "Prayer", systemImage: "moon.stars") }
            Form { Section("Desktop widgets") { DesktopWidgetSettings() } }.formStyle(.grouped)
                .tabItem { Label("Widgets", systemImage: "square.grid.3x2") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            DeveloperSettings().tabItem { Label("Developer", systemImage: "chevron.left.forwardslash.chevron.right") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// Re-applies service state after a settings change.
func applySettings() {
    NotchWindowController.shared?.reposition()
    FloatingPlayer.shared.update()
    MenuBarPlayer.shared.update()
    MenuBarHider.shared.update()
    MenuBarDetach.shared.update()
    EventTapHub.shared.update()
    KnockDetector.shared.update()
    ExtraBrightness.shared.update()
    WindowSnapper.shared.update()
    KeystrokeHUD.shared.update()
    DeveloperAPI.shared.update()
    TimerService.shared.configureBreakReminder()
    BannerWatcher.shared.start()
    if Prefs.bool(Prefs.Key.spectrumEnabled) { SpectrumService.shared.start() } else { SpectrumService.shared.stop() }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.Key.forcePillMode) var pill = false
    @AppStorage(Prefs.Key.pillWidth) var pillW = 190.0
    @AppStorage(Prefs.Key.pillHeight) var pillH = 30.0
    @AppStorage(Prefs.Key.pillYOffset) var pillY = 4.0
    @AppStorage(Prefs.Key.targetDisplay) var display = 0
    @AppStorage(Prefs.Key.hideInFullscreen) var hideFS = true
    @AppStorage(Prefs.Key.panelWidth) var panelW = 640.0
    @AppStorage(Prefs.Key.panelHeight) var panelH = 260.0
    @AppStorage(Prefs.Key.hoverToOpen) var hoverOpen = true
    @AppStorage(Prefs.Key.hoverTopEdge) var topEdge = true
    @AppStorage(Prefs.Key.swipeTabs) var swipe = true
    @AppStorage(Prefs.Key.autoCollapse) var autoCollapse = true
    @AppStorage(Prefs.Key.peekOnHover) var peek = true
    @AppStorage(Prefs.Key.hideNotch) var hideNotch = false
    @AppStorage(Prefs.Key.timerMascot) var mascot = "🐢"
    @AppStorage(Prefs.Key.idleLottiePath) var lottie = ""
    @AppStorage(Prefs.Key.idleLottieSpeed) var lSpeed = 1.0
    @AppStorage(Prefs.Key.idleLottieScale) var lScale = 1.0
    @AppStorage(Prefs.Key.idleLottieYOffset) var lY = 0.0
    @AppStorage(Prefs.Key.language) var language = "system"
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Pill mode (for Macs without a notch / external displays)", isOn: $pill)
                if pill {
                    Slider(value: $pillW, in: 120...400) { Text("Pill width \(Int(pillW))") }
                    Slider(value: $pillH, in: 22...44) { Text("Pill height \(Int(pillH))") }
                    Slider(value: $pillY, in: 0...30) { Text("Height offset \(Int(pillY))") }
                }
                Picker("Display", selection: $display) {
                    Text("Automatic (built-in)").tag(0)
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, s in Text(s.localizedName).tag(i + 1) }
                }
                Toggle("Hide in fullscreen apps", isOn: $hideFS)
                Toggle("Hide the notch (black menu bar, tools stay active)", isOn: $hideNotch)
            }
            Section("Expanded panel — Liquid Glass") {
                Slider(value: $panelW, in: 480...960) { Text("Width \(Int(panelW))") }
                Slider(value: $panelH, in: 180...560) { Text("Height \(Int(panelH))") }
                Button("Live preview") { AppState.shared.open() }
            }
            Section("Gestures") {
                Toggle("Hover to open", isOn: $hoverOpen)
                Toggle("Hover top edge to expand", isOn: $topEdge)
                Toggle("Peek on hover (mini controls)", isOn: $peek)
                Toggle("Swipe to change tabs", isOn: $swipe)
                Toggle("Auto-collapse", isOn: $autoCollapse)
            }
            Section("Personality") {
                Picker("Timer mascot", selection: $mascot) { ForEach(["", "🐢", "🐇", "🐈", "🚀", "🦆", "🐌"], id: \.self) { Text($0.isEmpty ? "Off" : $0).tag($0) } }
                HStack {
                    TextField("Idle animation (Lottie JSON path)", text: $lottie)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
                        if p.runModal() == .OK, let u = p.url { lottie = u.path }
                    }
                }
                if !lottie.isEmpty {
                    Slider(value: $lSpeed, in: 0.1...3) { Text("Speed \(String(format: "%.1f", lSpeed))") }
                    Slider(value: $lScale, in: 0.3...2) { Text("Scale \(String(format: "%.1f", lScale))") }
                    Slider(value: $lY, in: -15...15) { Text("Vertical offset \(Int(lY))") }
                }
            }
            Section("App") {
                Picker("Language", selection: $language) { Text("System").tag("system"); Text("English").tag("en"); Text("Bahasa Indonesia").tag("id") }
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MediaSettings: View {
    @AppStorage(Prefs.Key.lyricsEnabled) var lyrics = true
    @AppStorage(Prefs.Key.spectrumEnabled) var spectrum = false
    @AppStorage(Prefs.Key.floatingPlayer) var floating = false
    @AppStorage(Prefs.Key.floatingPlayerSize) var size = 1
    @AppStorage(Prefs.Key.menuBarPlayer) var menuBar = false

    var body: some View {
        Form {
            Section("Now Playing") {
                Toggle("Synced lyrics (LRCLIB, free)", isOn: $lyrics)
                Toggle("Live audio spectrum (needs Screen & System Audio Recording)", isOn: $spectrum).onChange(of: spectrum) { _ in applySettings() }
                Toggle("Floating player", isOn: $floating).onChange(of: floating) { _ in applySettings() }
                Picker("Floating player size", selection: $size) { Text("S").tag(0); Text("M").tag(1); Text("L").tag(2); Text("XL").tag(3) }
                    .pickerStyle(.segmented).onChange(of: size) { _ in FloatingPlayer.shared.update() }
                Toggle("Full player in the menu bar", isOn: $menuBar).onChange(of: menuBar) { _ in applySettings() }
            }
            Section("Sound mixer") {
                Text("Per-app volume up to 150% and the 3-band EQ require Core Audio process taps (macOS 14.4+) and an audio driver; not included in this build. Output switching, master volume and mic mute are available in the Media tab.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct SystemSettings: View {
    @AppStorage(Prefs.Key.hudEnabled) var hud = true
    @AppStorage(Prefs.Key.hudStyle) var hudStyle = 0
    @AppStorage(Prefs.Key.hudSize) var hudSize = 1.0
    @AppStorage(Prefs.Key.replaceSystemHUD) var replaceHUD = false
    @AppStorage(Prefs.Key.batteryHUD) var battery = true
    @AppStorage(Prefs.Key.fullChargeLevel) var fullLevel = 100
    @AppStorage(Prefs.Key.fullChargeSound) var fullSound = true
    @AppStorage(Prefs.Key.capsLockHUD) var caps = true
    @AppStorage(Prefs.Key.privacyIndicator) var privacy = true
    @AppStorage(Prefs.Key.knockEnabled) var knock = false
    @AppStorage(Prefs.Key.knockSensitivity) var knockSens = 0.5
    @AppStorage(Prefs.Key.knockSingle) var k1 = "none"
    @AppStorage(Prefs.Key.knockDouble) var k2 = "toggleNotch"
    @AppStorage(Prefs.Key.knockTriple) var k3 = "playPause"
    @AppStorage(Prefs.Key.menuBarHiding) var mbHide = false
    @AppStorage(Prefs.Key.ddcEnabled) var ddc = false
    @AppStorage(Prefs.Key.extraBrightness) var extra = false
    @AppStorage(Prefs.Key.extraBrightnessLevel) var extraLevel = 1.5
    @AppStorage(Prefs.Key.hyperKey) var hyper = false
    @AppStorage(Prefs.Key.hyperEscape) var hyperEsc = true
    @AppStorage(Prefs.Key.windowSnapping) var snapping = false
    @AppStorage(Prefs.Key.detachClipboard) var dClip = false
    @AppStorage(Prefs.Key.detachTimer) var dTimer = false
    @AppStorage(Prefs.Key.detachAI) var dAI = false

    var body: some View {
        Form {
            Section("HUDs") {
                Toggle("Volume / brightness HUD", isOn: $hud)
                Picker("Style", selection: $hudStyle) { Text("Notch").tag(0); Text("Edge bar").tag(1); Text("Circular gauge").tag(2) }.pickerStyle(.segmented)
                if hudStyle > 0 { Slider(value: $hudSize, in: 0.6...1.8) { Text("Size") } }
                Toggle("Hide the stock macOS HUD (intercepts media keys; needs Accessibility)", isOn: $replaceHUD)
                Toggle("Battery HUD (charging / low battery)", isOn: $battery)
                Stepper("Full Charge island at \(fullLevel)%", value: $fullLevel, in: 80...100, step: 5)
                Toggle("Full charge sound", isOn: $fullSound)
                Toggle("Caps Lock HUD", isOn: $caps)
                Toggle("Camera / mic privacy indicator", isOn: $privacy)
            }
            Section("Knock to control (microphone transient detection)") {
                Toggle("Enable", isOn: $knock)
                Slider(value: $knockSens, in: 0...1) { Text("Sensitivity") }
                Picker("Single tap", selection: $k1) { ForEach(KnockDetector.actions, id: \.self) { Text($0).tag($0) } }
                Picker("Double tap", selection: $k2) { ForEach(KnockDetector.actions, id: \.self) { Text($0).tag($0) } }
                Picker("Triple tap", selection: $k3) { ForEach(KnockDetector.actions, id: \.self) { Text($0).tag($0) } }
            }
            Section("Keyboard & windows") {
                Toggle("Hyper key (Caps Lock → ⌃⌥⇧⌘)", isOn: $hyper)
                Toggle("Quick press of Caps Lock sends Escape", isOn: $hyperEsc)
                Toggle("Window snapping (drag to notch; ⌃⌥-move, ⌃⌥⇧-resize)", isOn: $snapping)
                HStack {
                    Button("Keyboard cleaning lock") { CleaningLock.shared.lockKeyboard() }
                    Button("Clean screen") { CleaningLock.shared.cleanScreen() }
                }
            }
            Section("Displays") {
                Toggle("Extra brightness on XDR / HDR displays", isOn: $extra)
                if extra { Slider(value: $extraLevel, in: 1...2.5) { Text("Boost \(String(format: "%.1f×", extraLevel))") } }
                Toggle("External display control (DDC/CI via m1ddc, Apple silicon)", isOn: $ddc)
            }
            Section("Menu bar") {
                Toggle("Menu bar icon hiding (⌘-drag icons left of the │ separator)", isOn: $mbHide)
                Toggle("Detach Clipboard", isOn: $dClip)
                Toggle("Detach Timer", isOn: $dTimer)
                Toggle("Detach Agents (AI)", isOn: $dAI)
            }
            Button("Apply") { applySettings() }
        }
        .formStyle(.grouped)
        .onDisappear { applySettings() }
    }
}

struct ProductivitySettings: View {
    @AppStorage(Prefs.Key.pomodoroWork) var work = 25
    @AppStorage(Prefs.Key.pomodoroBreak) var brk = 5
    @AppStorage(Prefs.Key.pomodoroLongBreak) var longBrk = 15
    @AppStorage(Prefs.Key.pomodoroChain) var chain = true
    @AppStorage(Prefs.Key.breakReminderMinutes) var reminder = 0
    @AppStorage(Prefs.Key.focusIsland) var focus = true
    @AppStorage(Prefs.Key.clipboardLimit) var clipLimit = 200
    @AppStorage(Prefs.Key.autoPaste) var autoPaste = false
    @AppStorage(Prefs.Key.ocrClipboard) var ocr = true
    @AppStorage(Prefs.Key.translateTarget) var translate = "id"
    @AppStorage(Prefs.Key.customSearchURL) var custom = ""
    @AppStorage(Prefs.Key.downloadAlerts) var downloads = true
    @AppStorage(Prefs.Key.screenshotShelf) var shots = true
    @AppStorage(Prefs.Key.shakeToShelf) var shake = true
    @AppStorage(Prefs.Key.messageIsland) var messages = false
    @AppStorage(Prefs.Key.callIsland) var calls = true

    var body: some View {
        Form {
            Section("Pomodoro") {
                Stepper("Focus \(work) min", value: $work, in: 5...120, step: 5)
                Stepper("Break \(brk) min", value: $brk, in: 1...30)
                Stepper("Long break \(longBrk) min", value: $longBrk, in: 5...60, step: 5)
                Toggle("Chain sessions automatically", isOn: $chain)
                Stepper(reminder == 0 ? "Break reminders: off" : "Break reminder every \(reminder) min", value: $reminder, in: 0...180, step: 15)
                Toggle("Focus mode island", isOn: $focus)
            }
            Section("Clipboard & search") {
                Stepper("History size \(clipLimit)", value: $clipLimit, in: 20...2000, step: 20)
                Toggle("Auto-paste after choosing an item (Accessibility)", isOn: $autoPaste)
                Toggle("OCR copied images (on-device)", isOn: $ocr)
                TextField("Translate to (language code)", text: $translate)
                TextField("Custom search engine URL (use %s)", text: $custom)
            }
            Section("Files") {
                Toggle("Download alerts", isOn: $downloads)
                Toggle("Screenshot shelf", isOn: $shots)
                Toggle("Shake a dragged file to open the shelf", isOn: $shake)
            }
            Section("Communication (Accessibility)") {
                Toggle("Message island (Messages / SMS banners)", isOn: $messages)
                Toggle("Call island (FaceTime, Phone, Zoom, Teams, WhatsApp)", isOn: $calls)
            }
        }
        .formStyle(.grouped)
        .onDisappear { applySettings() }
    }
}

struct PrivacySettings: View {
    @AppStorage(Prefs.Key.hiddenFromCapture) var hidden = false
    @AppStorage(Prefs.Key.hiddenEverywhere) var everywhere = false
    var body: some View {
        Form {
            Section("Screen capture") {
                Toggle("Hidden from screen capture & screen sharing", isOn: $hidden)
                Toggle("Hidden everywhere (also hide on your own screen; hotkeys keep working)", isOn: $everywhere)
            }
            Section("Permissions") {
                permissionRow("Accessibility", "Auto-paste, HUD replacement, window snapping, keystroke HUD, islands", AX.trusted, "Privacy_Accessibility")
                permissionRow("Screen & System Audio Recording", "Audio spectrum", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture")
                permissionRow("Full Disk Access", "Notification Mirror, Focus detection", NotificationMirror.shared.dbPath != nil, "Privacy_AllFiles")
                permissionRow("Automation", "Spotify / Music / browsers / Messages", true, "Privacy_Automation")
            }
            Section("Data") {
                Text("No ads, no tracking, no analytics. Everything stays on this Mac, except: lyrics (LRCLIB), weather (Open-Meteo), stocks (Yahoo Finance), translation (Google), and screenshots you explicitly send with “Ask” (Anthropic API, your key).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Face Unlock") {
                Text("Not included. Unlocking macOS with your face would require storing your login password and injecting it at the lock screen, which this project deliberately does not do. Use Touch ID or an Apple Watch.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func permissionRow(_ name: String, _ why: String, _ granted: Bool, _ anchor: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading) { Text(name); Text(why).font(.caption).foregroundColor(.secondary) }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!) }
        }
    }
}

struct DeveloperSettings: View {
    @AppStorage(Prefs.Key.developerAPI) var api = false
    @AppStorage(Prefs.Key.notchApprovals) var approvals = true
    @AppStorage(Prefs.Key.anthropicModel) var model = "claude-sonnet-4-5"
    @Local private var apiKey = Keychain.get("anthropicKey") ?? ""
    @Local private var status = ""

    var body: some View {
        Form {
            Section("Developer API") {
                Toggle("Enable local API on 127.0.0.1:\(DeveloperAPI.port)", isOn: $api).onChange(of: api) { _ in DeveloperAPI.shared.update() }
                Toggle("Approve Claude Code permission prompts from the notch", isOn: $approvals)
                Text("Only asks when Claude Code itself would ask. Off = Claude Code shows its normal prompt.").font(.caption).foregroundColor(.secondary)
                HStack { Text("Token"); Text(DeveloperAPI.token).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                HStack {
                    Button("Copy MCP Configuration") {
                        let script = HookInstaller.writeScripts().appendingPathComponent("notchhub_mcp.py")
                        try? MCPScript.source.write(to: script, atomically: true, encoding: .utf8)
                        ClipboardService.shared.copyText(DeveloperAPI.mcpConfiguration(scriptPath: script.path))
                        status = "MCP config copied to clipboard"
                    }
                    Button("Install Claude Code hooks") { api = true; DeveloperAPI.shared.update(); status = HookInstaller.installClaudeHooks() }
                    Button("Write shell / Codex / Xcode scripts") {
                        let d = HookInstaller.writeScripts()
                        status = "Wrote scripts to \(d.path). Add `source ~/.notchhub/shell.zsh` to ~/.zshrc; set notify = [\"\(d.path)/codex-notify.sh\"] in ~/.codex/config.toml; build with ~/.notchhub/nh-xcodebuild."
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
            }
            Section("Ask about the screen") {
                SecureField("Anthropic API key (stored in Keychain)", text: $apiKey).onSubmit { Keychain.set(apiKey, for: "anthropicKey") }
                TextField("Model", text: $model)
                Button("Save key") { Keychain.set(apiKey, for: "anthropicKey"); status = "Key saved to Keychain" }
            }
        }.formStyle(.grouped)
    }
}

struct AboutSettings: View {
    @AppStorage(Prefs.Key.updateFeedURL) var feed = ""
    @AppStorage(Prefs.Key.betaChannel) var beta = false
    @ObservedObject var updater = Updater.shared
    var body: some View {
        Form {
            Section {
                Text("NotchHub \(Updater.currentVersion)").font(.title2.bold())
                Text("A clean-room, open implementation of a Dynamic-Island-style notch hub for macOS 13+. Native SwiftUI.").foregroundColor(.secondary)
            }
            Section("Updates") {
                TextField("Update feed URL (JSON: {version, url, notes, beta})", text: $feed)
                Toggle("Beta channel", isOn: $beta)
                Button("Check now") { updater.check(manual: true) }
                if !updater.notes.isEmpty { Text(updater.notes).font(.caption).textSelection(.enabled) }
            }
            Section { Button("Quit NotchHub") { NSApp.terminate(nil) } }
        }.formStyle(.grouped)
    }
}

// MARK: - Updater (signed feed check; opens the release download)

final class Updater: ObservableObject {
    static let shared = Updater()
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    @Published var notes = ""

    func check(manual: Bool = false) {
        guard let url = URL(string: Prefs.string(Prefs.Key.updateFeedURL)), url.scheme == "https" else {
            if manual { notes = "Set an https update feed URL first." }
            return
        }
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let obj = try? JSONSerialization.jsonObject(with: d) else { return }
            let arr: [[String: Any]] = (obj as? [[String: Any]]) ?? ((obj as? [String: Any]).map { [$0] } ?? [])
            let allowBeta = Prefs.bool(Prefs.Key.betaChannel)
            let candidates = arr.filter { allowBeta || ($0["beta"] as? Bool) != true }
            guard let latest = candidates.max(by: { ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedAscending }),
                  let v = latest["version"] as? String else { return }
            DispatchQueue.main.async {
                if v.compare(Self.currentVersion, options: .numeric) == .orderedDescending {
                    self.notes = "Version \(v) available\n\n\(latest["notes"] as? String ?? "")"
                    if let s = latest["url"] as? String, let u = URL(string: s) {
                        AppState.shared.show(Island(kind: .info, icon: "arrow.down.app.fill", title: "NotchHub \(v) available", tint: .blue,
                                                    actions: [IslandAction(title: "Download") { NSWorkspace.shared.open(u) }], duration: 8))
                    }
                } else if manual { self.notes = "You're up to date (\(Self.currentVersion))." }
            }
        }.resume()
    }
}
