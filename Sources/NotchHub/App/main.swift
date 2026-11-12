import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        Notifier.requestAuth()

        controller = NotchWindowController()

        // Core services
        MediaService.shared.start()
        AudioDevices.shared.start()
        HUDService.shared.start()
        BatteryService.shared.start()
        BluetoothBattery.shared.start()
        ClipboardService.shared.start()
        DownloadWatcher.shared.start()
        ScreenshotShelf.shared.start()
        DriveService.shared.start()
        WeatherService.shared.start()
        SystemStats.shared.start()
        FocusWatcher.shared.start()
        PrayerService.shared.start()
        DesktopWidgets.shared.sync()
        CommandPalette.shared.registerHotKey()
        applySettings()
        Updater.shared.check()

        // Small menu bar entry so the app is always reachable.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "NotchHub")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notch", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Command Palette  ⌃⌥K", action: #selector(openPalette), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ n: Notification) {
        KeepAwake.shared.stop()
        if Prefs.bool(Prefs.Key.hyperKey) { HyperKey.applyMapping(false) }
    }

    @objc func openNotch() { AppState.shared.open() }
    @objc func openPalette() { CommandPalette.shared.show() }
    @objc func openSettings() { SettingsWindow.show() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
