import AppKit
import SwiftUI

/// Now Playing for Spotify and Apple Music via Apple Events (official scripting dictionaries).
final class MediaService: ObservableObject {
    static let shared = MediaService()

    enum Player: String { case spotify = "Spotify", music = "Music" }

    @Published var player: Player?
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var shuffle = false
    @Published var repeatOn = false
    @Published var volume: Double = 50
    @Published var favorited = false
    @Published var artwork: NSImage?

    var hasTrack: Bool { !title.isEmpty }
    private var timer: Timer?
    private var lastArtworkKey = ""
    private let sep = "‖"

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        let spotifyOn = AppleScript.isRunning("com.spotify.client")
        let musicOn = AppleScript.isRunning("com.apple.Music")
        guard spotifyOn || musicOn else { clear(); return }

        let script: String
        let p: Player
        // Prefer whichever is actually playing.
        if spotifyOn && (!musicOn || player != .music) { p = .spotify } else { p = .music }
        if p == .spotify {
            script = """
            tell application "Spotify"
              try
                set t to current track
                return (player state as string) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & ((duration of t) / 1000 as string) & "\(sep)" & (player position as string) & "\(sep)" & (artwork url of t) & "\(sep)" & (shuffling as string) & "\(sep)" & (repeating as string) & "\(sep)" & (sound volume as string) & "\(sep)false"
              on error
                return "stopped"
              end try
            end tell
            """
        } else {
            script = """
            tell application "Music"
              try
                set t to current track
                set fav to "false"
                try
                  set fav to (favorited of t) as string
                on error
                  try
                    set fav to (loved of t) as string
                  end try
                end try
                return (player state as string) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (duration of t as string) & "\(sep)" & (player position as string) & "\(sep)" & "" & "\(sep)" & (shuffle enabled as string) & "\(sep)" & (song repeat as string) & "\(sep)" & (sound volume as string) & "\(sep)" & fav
              on error
                return "stopped"
              end try
            end tell
            """
        }
        AppleScript.runAsync(script) { [weak self] r in
            guard let self else { return }
            guard let s = r?.stringValue else { return }
            let parts = s.components(separatedBy: self.sep)
            guard parts.count >= 11 else {
                // A paused/stopped secondary player shouldn't wipe the other one.
                if p == .spotify, musicOn { self.player = .music } else { self.clear() }
                return
            }
            let num: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            self.player = p
            self.isPlaying = parts[0] == "playing"
            self.title = parts[1]
            self.artist = parts[2]
            self.album = parts[3]
            self.duration = num(parts[4])
            self.position = num(parts[5])
            self.shuffle = parts[7] == "true"
            self.repeatOn = parts[8] == "true" || parts[8] == "all" || parts[8] == "one"
            self.volume = num(parts[9])
            self.favorited = parts[10] == "true"
            self.updateArtwork(urlString: parts[6])
            self.publishActivity()
            LyricsService.shared.trackChanged(title: self.title, artist: self.artist, album: self.album, duration: self.duration)
        }
    }

    private func clear() {
        if title.isEmpty && player == nil { return }
        player = nil; title = ""; artist = ""; album = ""; isPlaying = false; artwork = nil
        AppState.shared.clearActivity("0-media")
    }

    private func publishActivity() {
        if isPlaying {
            AppState.shared.setActivity(LiveActivity(id: "0-media", icon: "waveform", text: title, tint: .green))
        } else {
            AppState.shared.clearActivity("0-media")
        }
    }

    private func updateArtwork(urlString: String) {
        let key = "\(title)|\(album)"
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key
        if player == .spotify, let url = URL(string: urlString) {
            URLSession.shared.dataTask(with: url) { d, _, _ in
                guard let d, let img = NSImage(data: d) else { return }
                DispatchQueue.main.async { self.artwork = img }
            }.resume()
        } else {
            AppleScript.runAsync("tell application \"Music\" to get raw data of artwork 1 of current track") { r in
                if let d = r?.data, let img = NSImage(data: d) { self.artwork = img } else { self.artwork = nil }
            }
        }
    }

    // MARK: Commands

    private func send(_ cmd: String) {
        guard let p = player else { return }
        AppleScript.runAsync("tell application \"\(p.rawValue)\" to \(cmd)") { [weak self] _ in self?.poll() }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(_ seconds: Double) { position = seconds; send("set player position to \(Int(seconds))") }
    func setVolume(_ v: Double) { volume = v; send("set sound volume to \(Int(v))") }

    func toggleShuffle() {
        guard let p = player else { return }
        send(p == .spotify ? "set shuffling to \(!shuffle)" : "set shuffle enabled to \(!shuffle)")
    }

    func toggleRepeat() {
        guard let p = player else { return }
        send(p == .spotify ? "set repeating to \(!repeatOn)" : "set song repeat to \(repeatOn ? "off" : "all")")
    }

    func toggleFavorite() {
        guard player == .music else { return }
        AppleScript.runAsync("""
        tell application "Music"
          try
            set favorited of current track to \(!favorited)
          on error
            set loved of current track to \(!favorited)
          end try
        end tell
        """) { [weak self] _ in self?.poll() }
    }

    // MARK: Browser playback speed

    static let browsers: [(bundle: String, name: String, safari: Bool)] = [
        ("com.google.Chrome", "Google Chrome", false),
        ("com.brave.Browser", "Brave Browser", false),
        ("com.microsoft.edgemac", "Microsoft Edge", false),
        ("com.vivaldi.Vivaldi", "Vivaldi", false),
        ("com.apple.Safari", "Safari", true),
    ]

    /// Sets playbackRate on every <video>/<audio> in the front tab of running browsers.
    /// Chrome-family requires View › Developer › "Allow JavaScript from Apple Events"; Safari requires Develop › same option.
    func setBrowserPlaybackRate(_ rate: Double) {
        let js = "document.querySelectorAll('video,audio').forEach(function(v){v.playbackRate=\(rate)});"
        for b in Self.browsers where AppleScript.isRunning(b.bundle) {
            let src = b.safari
                ? "tell application \"Safari\" to do JavaScript \"\(js)\" in current tab of front window"
                : "tell application \"\(b.name)\" to execute active tab of front window javascript \"\(js)\""
            AppleScript.runAsync(src)
        }
    }
}
