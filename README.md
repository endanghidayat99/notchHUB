# NotchHub

A clean-room macOS notch hub (Dynamic-Island style) inspired by the public feature list of Notchy. Native Swift/SwiftUI, macOS 13+.
No code from Notchy was decompiled or copied. See **FEATURES.md** for the parity matrix.

📖 **Dokumentasi lengkap (Bahasa Indonesia): [docs/DOKUMENTASI.md](docs/DOKUMENTASI.md)**

## Build
```bash
cd ~/Workspace/NotchHub
swift build                    # debug build (fetches Lottie)
./scripts/build_app.sh          # → build/NotchHub.app (ad-hoc signed)
./scripts/build_app.sh --install  # also copy to /Applications
open build/NotchHub.app
```
Or open `Package.swift` in Xcode and Run.

## First run — permissions
Grant as needed (Settings › Privacy shows status):
- **Accessibility** – auto-paste, hide stock HUD, hyper key, window snapping, keystroke HUD, message/call islands
- **Screen & System Audio Recording** – audio spectrum, window watch
- **Full Disk Access** – notification mirror, focus detection
- **Automation** – Spotify, Music, browsers, Messages (prompted automatically)
- Calendar, Reminders, Location, Camera, Microphone (prompted on use)

Because the app is ad-hoc signed, permissions may need re-granting after each rebuild.

## Developer integrations
Settings › Developer:
- Enable the local API (127.0.0.1:9999, token in Keychain)
- **Install Claude Code hooks** – writes `~/.notchhub/hook.sh` and merges hooks into `~/.claude/settings.json` (backup kept)
- Shell activity: add `source ~/.notchhub/shell.zsh` to `~/.zshrc`
- Codex: `notify = ["~/.notchhub/codex-notify.sh"]` in `~/.codex/config.toml`
- Xcode builds: use `~/.notchhub/nh-xcodebuild` instead of `xcodebuild`
- **Copy MCP Configuration** – stdio bridge `~/.notchhub/notchhub_mcp.py`

## Hotkeys
- ⌃⌥K command palette · ⌘1–9 switch tabs · Esc close · ⌘⎋ unlock cleaning lock
