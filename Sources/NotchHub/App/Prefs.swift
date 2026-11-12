import Foundation
import SwiftUI

/// All user-facing settings. Views bind with @AppStorage(Prefs.Key.x); services read via Prefs.bool etc.
enum Prefs {
    enum Key {
        // Core
        static let forcePillMode = "forcePillMode"
        static let pillWidth = "pillWidth"
        static let pillHeight = "pillHeight"
        static let pillYOffset = "pillYOffset"
        static let targetDisplay = "targetDisplay"           // 0 = main, n = index
        static let hideInFullscreen = "hideInFullscreen"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
        static let hoverToOpen = "hoverToOpen"
        static let hoverTopEdge = "hoverTopEdge"
        static let swipeTabs = "swipeTabs"
        static let autoCollapse = "autoCollapse"
        static let peekOnHover = "peekOnHover"
        static let hideNotch = "hideNotch"
        static let timerMascot = "timerMascot"               // "" = off
        static let idleLottiePath = "idleLottiePath"
        static let idleLottieSpeed = "idleLottieSpeed"
        static let idleLottieScale = "idleLottieScale"
        static let idleLottieYOffset = "idleLottieYOffset"
        static let hiddenFromCapture = "hiddenFromCapture"
        static let hiddenEverywhere = "hiddenEverywhere"
        static let language = "language"                     // "system", "en", "id"
        // Media
        static let lyricsEnabled = "lyricsEnabled"
        static let spectrumEnabled = "spectrumEnabled"
        static let floatingPlayer = "floatingPlayer"
        static let floatingPlayerSize = "floatingPlayerSize" // 0..3
        static let menuBarPlayer = "menuBarPlayer"
        // System
        static let hudEnabled = "hudEnabled"
        static let hudStyle = "hudStyle"                     // 0 notch, 1 edge bar, 2 circular
        static let hudSize = "hudSize"
        static let replaceSystemHUD = "replaceSystemHUD"
        static let batteryHUD = "batteryHUD"
        static let fullChargeLevel = "fullChargeLevel"
        static let fullChargeSound = "fullChargeSound"
        static let capsLockHUD = "capsLockHUD"
        static let privacyIndicator = "privacyIndicator"
        static let knockEnabled = "knockEnabled"
        static let knockSensitivity = "knockSensitivity"
        static let knockSingle = "knockSingle"
        static let knockDouble = "knockDouble"
        static let knockTriple = "knockTriple"
        static let menuBarHiding = "menuBarHiding"
        static let ddcEnabled = "ddcEnabled"
        static let extraBrightness = "extraBrightness"
        static let extraBrightnessLevel = "extraBrightnessLevel"
        static let hyperKey = "hyperKey"
        static let hyperEscape = "hyperEscape"
        static let windowSnapping = "windowSnapping"
        static let keystrokeHUD = "keystrokeHUD"
        static let detachClipboard = "detachClipboard"
        static let detachTimer = "detachTimer"
        static let detachAI = "detachAI"
        // Productivity
        static let pomodoroWork = "pomodoroWork"
        static let pomodoroBreak = "pomodoroBreak"
        static let pomodoroLongBreak = "pomodoroLongBreak"
        static let pomodoroChain = "pomodoroChain"
        static let breakReminderMinutes = "breakReminderMinutes"
        static let weatherLat = "weatherLat"
        static let weatherLon = "weatherLon"
        static let focusIsland = "focusIsland"
        // Clipboard / search
        static let clipboardLimit = "clipboardLimit"
        static let autoPaste = "autoPaste"
        static let ocrClipboard = "ocrClipboard"
        static let translateTarget = "translateTarget"
        static let customSearchURL = "customSearchURL"
        // Files
        static let downloadAlerts = "downloadAlerts"
        static let screenshotShelf = "screenshotShelf"
        static let shakeToShelf = "shakeToShelf"
        // AI / dev
        static let developerAPI = "developerAPI"
        static let notchApprovals = "notchApprovals"
        static let anthropicModel = "anthropicModel"
        // Communication
        static let messageIsland = "messageIsland"
        static let callIsland = "callIsland"
        static let notificationMirror = "notificationMirror"
        // Updates
        static let updateFeedURL = "updateFeedURL"
        static let betaChannel = "betaChannel"
    }

    static func registerDefaults() {
        PrayerService.registerDefaults()
        UserDefaults.standard.register(defaults: [
            Key.pillWidth: 190.0, Key.pillHeight: 30.0, Key.pillYOffset: 4.0,
            Key.targetDisplay: 0, Key.hideInFullscreen: true,
            Key.panelWidth: 640.0, Key.panelHeight: 260.0,
            Key.hoverToOpen: true, Key.hoverTopEdge: true, Key.swipeTabs: true,
            Key.autoCollapse: true, Key.peekOnHover: true,
            Key.timerMascot: "🐢", Key.idleLottieSpeed: 1.0, Key.idleLottieScale: 1.0, Key.idleLottieYOffset: 0.0,
            Key.language: "system",
            Key.lyricsEnabled: true, Key.spectrumEnabled: false, Key.floatingPlayerSize: 1,
            Key.hudEnabled: true, Key.hudStyle: 0, Key.hudSize: 1.0, Key.replaceSystemHUD: false,
            Key.batteryHUD: true, Key.fullChargeLevel: 100, Key.fullChargeSound: true,
            Key.capsLockHUD: true, Key.privacyIndicator: true,
            Key.knockSensitivity: 0.5, Key.knockSingle: "none", Key.knockDouble: "toggleNotch", Key.knockTriple: "playPause",
            Key.extraBrightnessLevel: 1.5, Key.hyperEscape: true,
            Key.pomodoroWork: 25, Key.pomodoroBreak: 5, Key.pomodoroLongBreak: 15, Key.pomodoroChain: true,
            Key.breakReminderMinutes: 0,
            Key.focusIsland: true,
            Key.clipboardLimit: 200, Key.autoPaste: false, Key.ocrClipboard: true,
            Key.translateTarget: "id", Key.customSearchURL: "",
            Key.downloadAlerts: true, Key.screenshotShelf: true, Key.shakeToShelf: true,
            Key.notchApprovals: true,
            Key.anthropicModel: "claude-sonnet-4-5",
            Key.messageIsland: false, Key.callIsland: true,
            Key.updateFeedURL: "",
        ])
    }

    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func double(_ k: String) -> Double { UserDefaults.standard.double(forKey: k) }
    static func int(_ k: String) -> Int { UserDefaults.standard.integer(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func set(_ v: Any?, _ k: String) { UserDefaults.standard.set(v, forKey: k) }
}

/// Minimal bilingual localisation (English + Bahasa Indonesia). Follows macOS language unless overridden.
enum L10n {
    static var lang: String {
        let pref = Prefs.string(Prefs.Key.language)
        if pref == "en" || pref == "id" { return pref }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("id") ? "id" : "en"
    }

    private static let id: [String: String] = [
        "Home": "Beranda", "Prayer": "Sholat", "Media": "Media", "Shelf": "Rak", "Clipboard": "Papan Klip", "Timer": "Timer",
        "AI": "AI", "System": "Sistem", "Tools": "Alat",
        "Notifications": "Notifikasi", "Settings": "Pengaturan", "Nothing playing": "Tidak ada yang diputar",
        "Drop files here": "Letakkan file di sini", "Start": "Mulai", "Pause": "Jeda", "Reset": "Atur Ulang",
        "Focus": "Fokus", "Break": "Istirahat", "Stopwatch": "Stopwatch", "Keep Awake": "Tetap Terjaga",
        "Search": "Cari", "Translate": "Terjemahkan", "Copy": "Salin", "Pin": "Sematkan", "Quit": "Keluar",
        "Reply": "Balas", "Accept": "Terima", "Decline": "Tolak", "Allow": "Izinkan", "Deny": "Tolak",
        "Today": "Hari ini", "No events": "Tidak ada acara", "Add": "Tambah", "Zip": "Zip", "Unzip": "Unzip",
        "Convert": "Konversi", "Eject": "Keluarkan", "Ask": "Tanya", "Run": "Jalankan",
    ]

    static func t(_ s: String) -> String { lang == "id" ? (id[s] ?? s) : s }
}

func L(_ s: String) -> String { L10n.t(s) }
