# NotchHub — feature parity matrix vs. Notchy

Legend: ✅ implemented · 🟡 partial / different approach · ❌ not possible with public APIs (explained) · 🗑 removed by request

## Core notch
| Feature | Status | Notes |
|---|---|---|
| Dynamic Island notch (hover peek, click open) | ✅ | `NotchWindowController`, `NotchRootView` |
| Pill mode (size, height offset, display, fullscreen) | ✅ | Settings › General |
| Liquid-glass resizable panel + live preview | ✅ | NSVisualEffectView + gradient |
| Gestures: swipe tabs, hover open, top-edge, auto-collapse (each toggleable) | ✅ | |
| Multiple live activities in collapsed pill | ✅ | music, timer, caffeine, meeting, download, agent, shell, build, privacy |
| Timer mascots | ✅ | emoji rides the progress |
| Custom idle Lottie (speed/scale/offset) | ✅ | Lottie SPM |
| Hide the notch (black menu bar) | ✅ | desktop-level black strip |

## Music & media
| Now Playing (Spotify/Music: art, scrub, shuffle, repeat, volume, Favorite) | ✅ | Apple Events |
| Floating player (4 sizes) + menu bar full player | ✅ | |
| Browser playback speed (Chrome/Brave/Edge/Vivaldi/Safari) | ✅ | needs "Allow JavaScript from Apple Events" |
| Peek on hover | ✅ | |
| Synced lyrics (LRCLIB) word highlight | 🟡 | LRCLIB is line-timed; words are interpolated |
| Live audio spectrum | ✅ | ScreenCaptureKit audio + Goertzel bands |
| Audio output switcher | ✅ | CoreAudio |
| Sound mixer per-app 150% + 3-band EQ | ❌ | needs process taps + DSP driver; not in this build |
| AirPods manager (case, per-bud, connect) | ✅ | system_profiler + IOBluetooth |
| Device battery (Magic devices, 3rd-party BT) | ✅ | IORegistry BatteryPercent |

## Productivity
| Pomodoro (chaining, streaks, 7-day chart, repeat, break reminders) | ✅ | |
| Drift-free stopwatch from the pill | ✅ | wall-clock derived |
| Focus mode island / quiet alerts | 🟡 | no public API; reads DND store when Full Disk Access granted |
| Keep Awake (∞ / duration / until time) | ✅ | IOPMAssertion |
| Quick notes | 🗑 | removed by request (2026-11-12)  |
| Apple Reminders | 🗑 | removed by request (2026-11-12)  |
| Calendar (iCloud/Google/Exchange, one-line add, countdown) | 🗑 | removed by request (2026-11-12)  |
| Live weather | ✅ | Open-Meteo |
| Stocks (watchlist, charts, ticker, alerts, pre/after-hours) | 🗑 | removed by request (2026-11-12)  |
| Teleprompter (Cuely) | 🗑 | removed by request (2026-11-12)  |
| Camera mirror | 🗑 | removed by request (2026-11-12)  |

## Clipboard & text
| Clipboard history (pins, smart actions, link cards, Maccy/Alfred import) | ✅ | |
| Rapid-copy stacking + auto-paste | ✅ | auto-paste needs Accessibility |
| OCR + search inside images | ✅ | Vision |
| Snippets | ✅ | |
| Search 9 engines + custom, translate as you type, quick math, save video | ✅ | command palette only; video via yt-dlp if installed |
| Command palette ⌃⌥K, ⌘1–9 tabs | ✅ | Carbon hotkey |

## Files & shelf
| File shelf (drop, drag out, shake-to-open, persistent selection) | ✅ | |
| Zip / unzip (ditto) | ✅ | |
| Image/PDF convert, background removal, video/audio convert | ✅ | bg removal macOS 14+ |
| AirDrop with feedback | ✅ | |
| Drive eject | ✅ | |
| Download alerts (any browser) | ✅ | watches ~/Downloads |

## Screen & capture
| Screenshot shelf (pin, markup) | ✅ | markup via Preview |
| Window/area capture → clipboard + shelf | ✅ | |
| Color eyedropper (no permission) | ✅ | NSColorSampler |
| Ask about the screen (OCR on-device, Ask via Anthropic key) | ✅ | |
| Window Watch (hash only) | 🗑 | removed by request (2026-11-12)  |
| Keystroke HUD (password fields excluded) | ✅ | Secure Event Input check |
| Hidden from screen capture / Hidden everywhere | ✅ | |

## System & hardware
| Volume / brightness HUD, hide stock HUD | ✅ | hide = media-key event tap |
| Alt HUD styles (edge bar / circular) | ✅ | |
| Battery HUD, Full Charge island (80–100%) | ✅ | stock low-battery alert can't be suppressed, ours is shown in addition |
| Caps Lock HUD (no Input Monitoring) | ✅ | |
| Camera/mic privacy indicator | ✅ | |
| Mic mute (all apps) | ✅ | |
| Knock to control | 🟡 | detected via microphone transients (no accelerometer API) |
| Menu bar icon hiding | ✅ | separator technique |
| Menu bar detach (Clipboard/Timer/Agents) | ✅ | |
| System stats CPU/mem/net | ✅ | |
| External display DDC brightness | 🟡 | via `m1ddc` CLI if installed |
| Keyboard backlight | 🟡 | CoreBrightness private class, loaded dynamically |
| Keyboard cleaning lock + clean screen | ✅ | |
| Extra brightness XDR/HDR (steps back on LPM/battery/heat) | ✅ | EDR overlay |
| Hyper key (+ Escape on tap) | ✅ | hidutil + event tap |
| Window snapping + modifier move/resize | ✅ | AX |
| App launcher | 🗑 | removed by request (2026-11-12)  |
| Apple Shortcuts grid | 🗑 | removed by request (2026-11-12)  |
| Desktop widgets (Clock…Photo, Timer) | 🟡 | desktop-level windows, not WidgetKit (needs an app extension/Xcode project) |
| Lock screen widgets | ❌ | no public API |

## Communication
| Call island (FaceTime/Phone/Zoom/Teams/WhatsApp, answer/decline) | 🟡 | reads & presses Notification Center banner via Accessibility; depends on banner layout |
| Message island + inline reply + OTP copy | 🟡 | same; reply via Messages AppleScript |
| Notification Mirror | ✅ | Full Disk Access; reads usernoted DB |

## AI & developer
| AI usage tracker | 🗑 | removed by request (2026-11-12) |
| Agent approvals (Claude Code Allow/Deny + answer questions) | ✅ | PreToolUse hook → local API |
| Codex approvals | ❌ | Codex has no blocking approval hook; turn-complete notifications only |
| Agent activity (turns, prompts, per-turn cost) | ✅ | hooks |
| Shell activity (zsh hook) | ✅ | |
| Xcode builds island | 🟡 | via `nh-xcodebuild` wrapper (xcodebuild); Xcode.app GUI builds not hooked |
| Notch Terminal (persistent login shell) | 🗑 | removed by request (2026-11-12)  |
| Developer API 127.0.0.1:9999 + token + Copy MCP config | ✅ | |

## Security / other
| Face Unlock | ❌ | deliberately not implemented (would store/inject your login password) |
| Privacy (no ads/tracking) | ✅ | no analytics at all |
| Automatic updates | 🟡 | JSON feed check + download link; not Sparkle |
| Localization | 🟡 | English + Bahasa Indonesia (not 134 languages) |
| macOS 13+, Apple silicon & Intel | ✅ | |

## Extra (not in Notchy)
| Feature | Status | Notes |
|---|---|---|
| Prayer times (Imsak–Isya, Hijri date, 8 calculation methods incl. Kemenag RI) | ✅ | offline astronomical calculation, per-prayer minute corrections |
| Countdown in notch (always / last 30 min / off) | ✅ | |
| Adzan on/off (global + per prayer, custom MP3, separate Subuh file, volume, mute in Focus) | ✅ | no adzan audio bundled — choose your own file |
| Notification at prayer time + reminder N minutes before | ✅ | scheduled system notifications |
