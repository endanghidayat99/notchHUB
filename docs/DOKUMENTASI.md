# NotchHub — Dokumentasi Fitur

Per 12 November 2026. Versi online: https://claude.ai/artifact/X7McbfkvHX2W8vVT8ctiLK

## Daftar isi

1. [Ringkasan & instalasi](#ringkasan--instalasi)
2. [Antarmuka notch](#antarmuka-notch)
3. [Waktu sholat](#waktu-sholat)
4. [Musik & media](#musik--media)
5. [Produktivitas](#produktivitas)
6. [Clipboard, pencarian & command palette](#clipboard-pencarian--command-palette)
7. [File shelf & konversi](#file-shelf--konversi)
8. [Layar & capture](#layar--capture)
9. [Sistem & hardware](#sistem--hardware)
10. [Komunikasi](#komunikasi)
11. [AI & developer tools](#ai--developer-tools)
12. [Privasi, keterbatasan & troubleshooting](#privasi-keterbatasan--troubleshooting)

## Ringkasan & instalasi

NotchHub mengubah notch MacBook (atau pill di Mac tanpa notch) menjadi pusat kontrol bergaya Dynamic Island: musik, timer, waktu sholat, clipboard, rak file, HUD sistem, dan alat developer. Aplikasi native Swift/SwiftUI, dibuat clean-room dari daftar fitur publik Notchy — tanpa menyalin kode Notchy.

**Persyaratan:** macOS 13 Ventura atau lebih baru, Apple silicon atau Intel. Proyek ada di `~/Workspace/NotchHub`.

**Build & install**

1. `cd ~/Workspace/NotchHub`
2. `./scripts/build_app.sh --install` — build release, menyematkan `Lottie.framework`, tanda tangan ad-hoc, lalu salin ke `/Applications`.
3. Jalankan `open /Applications/NotchHub.app`. Aplikasi tidak muncul di Dock; ikonnya kapsul di menu bar (Open Notch, Command Palette, Settings, Quit).

Build memakai Command Line Tools. Karena SDK baru menjadikan `@State` macro yang plugin-nya hanya ada di Xcode, kode memakai pengganti `@Local` (`UI/Local.swift`).

**Izin macOS** (status terlihat di Settings › Privacy)

| Izin | Dipakai untuk |
| --- | --- |
| Accessibility | auto-paste, sembunyikan HUD bawaan, Hyper key, window snapping, keystroke HUD, cleaning lock, message/call island |
| Screen & System Audio Recording | spektrum audio |
| Full Disk Access | Notification Mirror, deteksi Focus |
| Automation | Spotify, Music, browser (kecepatan video), Messages, Preview |
| Lokasi | cuaca, matahari terbit/terbenam, waktu sholat otomatis |
| Mikrofon | Knock to Control |
| Notifikasi | waktu sholat, download |

Karena ditandatangani ad-hoc, macOS bisa meminta izin ulang setiap kali di-build ulang.

## Antarmuka notch

Notch punya empat keadaan: **tertutup** (menyatu dengan notch fisik, menampilkan live activity di sisi kiri-kanan), **peek** saat kursor di atasnya (kontrol musik mini), **island** sementara (HUD, pemberitahuan, permintaan izin), dan **terbuka** (panel berisi tab).

**Gestur** — masing-masing bisa dimatikan di Settings › General › Gestures:

- Hover untuk peek, klik untuk membuka, hover di tepi atas layar untuk membuka
- Swipe horizontal dua jari untuk ganti tab
- Auto-collapse saat kursor keluar panel lebih dari 0,5 detik
- Seret file ke notch untuk menaruhnya di Shelf; goyang file saat menyeret untuk membuka Shelf

**Live activity di notch tertutup** (bisa beberapa sekaligus, pill melebar): lagu yang diputar, countdown waktu sholat, timer/Pomodoro, Keep Awake, download, Claude Code/Codex sedang bekerja, perintah shell lama, build Xcode, indikator kamera/mikrofon.

**Tampilan & personalisasi**

- **Pill mode** untuk Mac tanpa notch atau monitor eksternal: lebar, tinggi, offset vertikal, pilih display
- **Panel Liquid Glass** dengan lebar/tinggi yang bisa diubah dan tombol Live preview
- **Sembunyikan di aplikasi fullscreen**
- **Hide the notch**: menu bar dibuat hitam, alat notch tetap aktif
- **Timer mascot** (emoji yang berjalan mengikuti progres timer) dan **animasi idle Lottie** sendiri (kecepatan, skala, offset)
- **Bahasa**: mengikuti macOS, atau pilih English / Bahasa Indonesia
- **Launch at login**

**Tab** (ikon di kiri dan kanan notch): Beranda, Sholat, Media, Rak (Shelf), Papan Klip, Timer, AI, Sistem, Notifikasi.

**Hotkey**

| Tombol | Fungsi |
| --- | --- |
| ⌃⌥K | Command palette (dari mana saja) |
| ⌘1–⌘9 | Pindah ke tab ke-1 sampai ke-9 saat panel terbuka |
| Esc | Tutup panel |
| ⌘⎋ | Buka kunci Keyboard cleaning lock |

## Waktu sholat

Jadwal sholat dihitung offline di Mac dari koordinat lokasi; metode default Kemenag RI (Subuh 20°, Isya 18°, ihtiyat 2 menit, Imsak = Subuh − 10 menit). Fitur ini tambahan, tidak ada di Notchy.

**Tab Sholat** menampilkan Imsak, Subuh, Terbit, Dzuhur, Ashar, Maghrib, Isya; countdown ke sholat berikutnya; nama kota; tanggal Hijriah; ikon speaker untuk menyalakan/mematikan adzan per waktu; dan sakelar cepat Adzan serta Notifikasi. Waktu sholat berikutnya juga tampil di tab Beranda.

**Saat masuk waktu sholat**

1. Island "Waktunya sholat …" muncul di notch, tetap muncul meski Focus aktif.
2. Adzan diputar bila diaktifkan; island menampilkan tombol **Stop adzan** dan hilang sendiri saat adzan selesai.
3. Notifikasi macOS terkirim (dijadwalkan sistem, jadi tetap datang walau notch tersembunyi).

Pengingat island + notifikasi juga muncul N menit sebelum waktu (default 10 menit).

**Pengaturan** (Settings › Sholat)

| Opsi | Pilihan / default |
| --- | --- |
| Tampilkan waktu sholat | on |
| Metode perhitungan | Kemenag RI, JAKIM, MUIS, Muslim World League, ISNA, Mesir, Umm al-Qura, Karachi |
| Ashar | Syafi'i/Jumhur (default) atau Hanafi |
| Countdown di notch | Selalu / 30 menit sebelum (default) / Tidak |
| Lokasi | otomatis dari Location Services, atau isi latitude & longitude (Palu: −0.8917, 119.8707) + nama kota |
| Adzan | on/off global + per waktu (Subuh, Dzuhur, Ashar, Maghrib, Isya) |
| File adzan | MP3/M4A pilihan sendiri, opsional file khusus Subuh; volume; tombol Tes & Stop |
| Bisukan saat Focus/DND | off |
| Notifikasi saat masuk waktu | on |
| Pengingat sebelum waktu | 0–60 menit, default 10 |
| Koreksi | ±30 menit per waktu (menyamakan dengan jadwal masjid setempat) |

File suara adzan tidak disertakan di aplikasi. Sebelum memilih file, saat masuk waktu hanya terdengar bunyi notifikasi singkat. Contoh hasil untuk Palu, 11 November 2026: Subuh 04:21, Dzuhur 11:46, Ashar 15:09, Maghrib 17:51, Isya 19:03 WITA.

## Musik & media

Tab Media mengontrol Spotify dan Apple Music lewat Apple Events, plus audio sistem dan perangkat Bluetooth.

| Fitur | Cara pakai | Catatan |
| --- | --- | --- |
| Now Playing | cover album, judul, seek, shuffle, repeat, volume aplikasi, Favorite (Apple Music) | izin Automation diminta saat pertama dipakai |
| Peek on hover | arahkan kursor ke notch: prev / play-pause / next | |
| Floating player | Settings › Media; 4 ukuran S/M/L/XL, bisa digeser | |
| Player di menu bar | Settings › Media; ikon not balok, popover berisi player + lirik | |
| Lirik sinkron | sub-tab Lyrics; dari LRCLIB (gratis) | LRCLIB hanya menyimpan waktu per baris; sorotan per kata hanya perkiraan |
| Spektrum audio live | Settings › Media; bar di tab Media dan di notch | perlu izin Screen & System Audio Recording |
| Kecepatan video browser | sub-tab Speed: 0,25×–4× | Chrome, Brave, Edge, Vivaldi, Safari; aktifkan "Allow JavaScript from Apple Events" di browser |
| Pindah output audio | sub-tab Output; pilih speaker/headphone, volume & mute utama | |
| AirPods & baterai | sub-tab Devices: baterai kiri/kanan/case, tombol Connect/Disconnect; island saat case dibuka | |
| Baterai aksesori | Magic Mouse/Keyboard/Trackpad dan perangkat Bluetooth lain | |
| Sound mixer per aplikasi & EQ | tidak tersedia | butuh audio driver sendiri (lihat Keterbatasan) |

## Produktivitas

| Fitur | Letak | Yang bisa dilakukan |
| --- | --- | --- |
| Pomodoro | tab Timer | fokus/istirahat/istirahat panjang (default 25/5/15 menit), sesi berantai otomatis, streak harian, grafik fokus 7 hari |
| Timer & repeat | tab Timer › Timer | preset 1/5/10/25/60 menit atau custom, opsi Repeat; dari palette: ketik `timer 5` |
| Stopwatch | tab Timer › Stopwatch | akurat berdasarkan jam sistem (tidak melenceng), tampil di notch |
| Pengingat istirahat | Settings › Productivity | island "Take a break" tiap N menit |
| Keep Awake | tab Timer, Beranda, palette | cegah sleep tanpa batas, 30/60/120 menit, atau sampai jam tertentu |
| Cuaca | tab Beranda | suhu & kondisi dari Open-Meteo, berdasarkan lokasi |
| Focus mode | otomatis | island saat Focus berubah; pemberitahuan prioritas rendah ditahan saat DND (perlu Full Disk Access) |

## Clipboard, pencarian & command palette

Semua yang Anda salin (teks, gambar, file) tersimpan di tab Papan Klip, maksimal 200 item tak tersemat (bisa diubah 20–2.000). Isi yang ditandai concealed oleh password manager tidak dicatat.

**Papan Klip**

- Cari teks, termasuk teks di dalam gambar (OCR on-device dengan Apple Vision)
- Sematkan (pin), hapus, seret kartu ke aplikasi lain, klik dua kali untuk tempel
- Aksi pintar: link → kartu dengan judul halaman + buka; warna hex → contoh warna + salin sebagai RGB; email → tulis email; file → masukkan ke Shelf
- **Rapid-copy stacking**: salinan dalam jarak 3 detik ditumpuk; tombol "Paste stack" menempel semuanya sekaligus
- **Auto-paste** (opsional, perlu Accessibility): memilih item langsung menempelkannya ke aplikasi sebelumnya
- Impor riwayat dari Maccy atau Alfred (menu …)
- **Snippets**: teks yang sering dipakai, tempel dengan satu klik atau dari palette

**Command palette (⌃⌥K)** — ketik lalu Enter, panah atas/bawah untuk memilih:

| Ketik | Hasil |
| --- | --- |
| nama tab / fitur | buka tab, toggle Caffeine, mulai Pomodoro/Stopwatch, pick color, capture, Ask about screen, mute mic, cleaning lock |
| `12*7+3` | hasil hitungan, Enter = salin |
| `timer 5` | mulai timer 5 menit |
| `tr selamat pagi` | terjemahan langsung |
| nama snippet | tempel snippet |
| teks apa saja | cocok dari clipboard + file (Spotlight) + cari di Google, DuckDuckGo, Bing, Brave |
| link `https://…` | simpan video (perlu `yt-dlp`) |

**Pencarian lewat palette** — pencarian di 9 mesin (Google, DuckDuckGo, Bing, Brave, Kagi, Perplexity, YouTube, GitHub, Wikipedia) plus mesin custom (URL dengan `%s`), terjemahan otomatis saat mengetik (bahasa tujuan default `id`), kalkulator cepat, dan simpan video dari link.

## File shelf & konversi

Shelf adalah tempat parkir sementara untuk file: seret file ke notch (atau goyang file saat menyeret), lalu seret keluar lagi ke aplikasi mana pun. Isi dan pilihan Shelf tetap ada setelah aplikasi dibuka ulang.

- Klik item untuk memilih; aksi berlaku untuk item terpilih, atau semua bila tidak ada yang dipilih
- Klik dua kali untuk membuka, ikon folder untuk menampilkan di Finder

| Aksi | Hasil |
| --- | --- |
| Zip | satu file → `nama.zip`; banyak file → `Archive.zip` (memakai `ditto`) |
| Unzip | ekstrak ke folder bernama sama |
| Convert › Image | HEIC, PNG, JPEG, TIFF, PDF (tiap halaman jadi gambar) → PNG/JPEG/TIFF/HEIC |
| Convert › Remove background | gambar → `nama.nobg.png` transparan (Apple Vision, macOS 14+) |
| Convert › Video/Audio | video → MP4 atau MOV, audio → M4A |
| AirDrop | kirim item via AirDrop, island berhasil/gagal |
| Eject | tombol eject untuk USB/drive eksternal; island saat drive dicolok |
| Clear | kosongkan Shelf |

Semua konversi berjalan offline. Hasilnya disimpan di samping file aslinya dan otomatis masuk Shelf.

**Download alerts** — NotchHub memantau folder Downloads, jadi bekerja dengan browser apa pun: live activity "N downloading" saat ada file `.crdownload`/`.part`, lalu island "Download finished" dengan tombol Show dan Shelf.

## Layar & capture

| Fitur | Cara pakai | Catatan |
| --- | --- | --- |
| Screenshot shelf | screenshot macOS biasa (⌘⇧3/4) otomatis muncul sebagai island + di Shelf | tombol Pin (jendela melayang di atas semua jendela) dan Markup (Preview) |
| Capture area | Beranda › Capture atau palette | hasil ke clipboard dan Shelf |
| Color eyedropper | Beranda › Color atau palette | klik piksel mana saja, kode hex tersalin; tanpa izin Screen Recording |
| Ask about the screen | Beranda › Ask atau palette | seret area layar → teks dibaca on-device; tombol Copy, Search, Translate, buka link; Ask mengirim gambar ke Anthropic API |
| Keystroke HUD | Settings › System | tampilkan tombol yang ditekan (untuk presentasi/rekaman); field password otomatis dikecualikan |
| Hidden from screen capture | Settings › Privacy | notch tidak ikut terekam/ter-share; "Hidden everywhere" juga menyembunyikan dari layar Anda sendiri, hotkey tetap jalan |

Ask about the screen hanya mengirim gambar ke luar Mac bila Anda menekan **Ask** dan sudah menyimpan Anthropic API key di Settings › Developer (tersimpan di Keychain, model default `claude-sonnet-4-5`).

## Sistem & hardware

Sebagian besar diatur di Settings › System; tab Sistem menampilkan statistik dan slider kontrol.

| Fitur | Yang terjadi | Catatan |
| --- | --- | --- |
| HUD volume & brightness | island di notch saat volume/brightness berubah | gaya alternatif: bar di tepi layar atau gauge lingkaran, ukuran bisa diatur |
| Sembunyikan HUD bawaan macOS | tombol media dicegat, volume/brightness diatur NotchHub | perlu Accessibility |
| Battery HUD | island saat mulai/berhenti charging dan saat baterai 20/10/5% | alert baterai lemah bawaan macOS tetap muncul |
| Full Charge island | island + suara saat baterai mencapai 80–100% (pilih) | |
| Caps Lock HUD | island Caps Lock On/Off | tanpa izin Input Monitoring; nonaktif saat Hyper key aktif |
| Indikator privasi | live activity saat kamera/mikrofon dipakai aplikasi mana pun | |
| Mute mikrofon | Beranda/palette; mute input untuk semua aplikasi | |
| Knock to Control | ketukan 1/2/3 kali di bodi Mac: buka notch, Shelf, Clipboard, Caffeine, atau play/pause | dideteksi lewat mikrofon, sensitivitas bisa diatur |
| Menu bar icon hiding | ikon ‹ dan pemisah │; ⌘-seret ikon ke kiri pemisah lalu klik ‹ untuk menyembunyikan | tanpa API privat |
| Menu bar detach | Clipboard, Timer, Agents (AI) jadi popover di menu bar | |
| Statistik sistem | CPU, memori, jaringan naik/turun, grafik CPU | tab Sistem |
| Brightness & backlight keyboard | slider di tab Sistem; tombol backlight ikut di-HUD | backlight hanya di keyboard yang mendukung |
| Brightness monitor eksternal | slider di tab Sistem | lewat `m1ddc` (`brew install m1ddc`), Apple silicon, off default |
| Extra brightness | layar XDR/HDR dibuat lebih terang (1–2,5×) | turun otomatis saat Low Power Mode, baterai <20%, atau Mac panas |
| Keyboard cleaning lock | semua tombol dikunci untuk dibersihkan; ⌘⎋ membuka | Clean screen juga menghitamkan semua layar (klik dua kali untuk keluar) |
| Hyper key | Caps Lock = ⌃⌥⇧⌘; tekan sebentar = Escape | Caps Lock dipetakan ulang via `hidutil`, dikembalikan saat keluar |
| Window snapping | seret jendela ke notch: kiri = setengah kiri, tengah = penuh, kanan = setengah kanan; ⌃⌥+gerak = pindah, ⌃⌥⇧+gerak = ubah ukuran | perlu Accessibility |
| Widget desktop | Settings › Widgets: Clock, World Clock, Now Playing, Weather, Sunrise & Sunset, Batteries, System, Photo, Timer | jendela di lapisan desktop, bisa digeser |

## Komunikasi

macOS tidak menyediakan API untuk panggilan dan pesan masuk, jadi NotchHub membaca banner Notification Center lewat Accessibility. Hasilnya bergantung pada tampilan banner di versi macOS Anda.

| Fitur | Yang terjadi | Pengaturan |
| --- | --- | --- |
| Call island | panggilan FaceTime, Phone, Zoom, Teams, WhatsApp muncul di notch dengan tombol Accept/Decline (menekan tombol pada banner) | Settings › Productivity, on default |
| Message island | pesan Messages/SMS muncul di notch dengan tombol Reply (balas via Messages); kode verifikasi/OTP dapat tombol Copy | off default |
| Notification Mirror | tab Notifikasi: 60 notifikasi terakhir dari Notification Center | perlu Full Disk Access; tombol refresh dan pintasan ke pengaturan privasi |

## AI & developer tools

Semua integrasi developer berjalan lewat **Developer API lokal** di `127.0.0.1:9999`, off default. Aktifkan di Settings › Developer; setiap request perlu header `Authorization: Bearer <token>` (token dibuat sekali per instalasi, disimpan di Keychain).

**Tab AI** menampilkan aktivitas agen saja: prompt, turn selesai (dengan perkiraan biaya turn Claude Code), permintaan izin, pertanyaan, dan notifikasi dari Claude Code dan Codex. Isinya datang dari hook di bawah; tanpa hook, tab ini kosong. Tombol Clear mengosongkan daftar.

**Integrasi** (tombol di Settings › Developer menulis script ke `~/.notchhub/`)

| Integrasi | Cara pasang | Hasil |
| --- | --- | --- |
| Persetujuan Claude Code | tombol **Install Claude Code hooks** (backup `settings.json.notchhub-backup` dibuat) | Allow/Deny di notch, **hanya** saat Claude Code memang akan meminta izin; tanpa jawaban 60 detik → prompt normal Claude Code. Bisa dimatikan lewat toggle "Approve Claude Code permission prompts from the notch" |
| Pertanyaan Claude Code | ikut hook di atas | pertanyaan (AskUserQuestion) bisa dijawab dengan tombol pilihan di notch |
| Aktivitas Claude Code | ikut hook di atas | "Claude working" di notch, island saat turn selesai + biaya turn |
| Codex | `notify = ["~/.notchhub/codex-notify.sh"]` di `~/.codex/config.toml` | island saat turn Codex selesai |
| Aktivitas shell | `source ~/.notchhub/shell.zsh` di `~/.zshrc` | perintah >5 detik tampil di notch; island bila >10 detik dengan status sukses/gagal & durasi |
| Build Xcode | jalankan `~/.notchhub/nh-xcodebuild` sebagai pengganti `xcodebuild` | timer build live + jumlah error/warning |
| MCP | tombol **Copy MCP Configuration** | konfigurasi server MCP stdio (`notchhub_mcp.py`) untuk aplikasi AI: show_island, set_activity, start_timer, keep_awake, status |

**Endpoint API**

| Method & path | Fungsi |
| --- | --- |
| `GET /v1/status` | status notch, lagu, timer, Keep Awake |
| `POST /v1/island` | tampilkan island `{title, subtitle, icon, duration}` |
| `POST /v1/activity` | set/hapus live activity `{id, text, icon, clear}` |
| `POST /v1/open` | buka notch di tab tertentu `{tab}` |
| `POST /v1/timer` | mulai timer `{minutes}` |
| `POST /v1/keepawake` | Keep Awake `{on, minutes}` |
| `POST /v1/claude/permission`, `/v1/claude/pretool`, `/v1/claude/event` | dipakai hook Claude Code |
| `POST /v1/agent/event`, `/v1/shell/start`, `/v1/shell/end`, `/v1/build` | dipakai Codex, shell, dan build |

Contoh:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"title":"Deploy selesai"}' http://127.0.0.1:9999/v1/island
```

## Privasi, keterbatasan & troubleshooting

**Fitur yang sengaja dihapus (12 November 2026):** Catatan cepat & Apple Reminders, Kalender, Saham, App launcher, Apple Shortcuts, Terminal di notch, pelacak pemakaian AI (token, biaya, batas Claude Code & Codex), dan tab Alat (panel Search, teleprompter Cuely, Camera Mirror, Window Watch). Search, terjemahan, dan kalkulator tetap ada di command palette; pengaturan widget desktop pindah ke Settings › Widgets.

**Privasi.** Tidak ada iklan, tracking, atau analytics. Data tetap di Mac, kecuali permintaan ke layanan berikut: lirik (LRCLIB), cuaca (Open-Meteo), saham (Yahoo Finance), terjemahan (Google), dan screenshot yang Anda kirim sendiri lewat tombol Ask (Anthropic API, memakai key Anda). Waktu sholat dihitung offline.

**Fitur Notchy yang tidak tersedia atau berbeda**

| Fitur | Status | Alasan |
| --- | --- | --- |
| Face Unlock | tidak dibuat | sengaja: harus menyimpan dan mengetikkan password login Anda |
| Widget Lock Screen | tidak bisa | tidak ada API publik macOS |
| Mixer volume per aplikasi (150%) & EQ 3-band | belum ada | butuh Core Audio process taps + driver audio |
| Persetujuan aksi Codex | tidak bisa | Codex tidak punya hook persetujuan; hanya notifikasi turn selesai |
| Knock to Control | berbeda | lewat mikrofon, bukan sensor akselerometer |
| Brightness monitor eksternal | sebagian | lewat CLI `m1ddc` |
| Call & Message island | sebagian | membaca banner via Accessibility, bisa berubah antar versi macOS |
| Widget desktop | berbeda | jendela desktop biasa, bukan WidgetKit |
| Lirik per kata | perkiraan | LRCLIB hanya punya waktu per baris |
| Build Xcode | sebagian | hanya build lewat `nh-xcodebuild`, bukan dari Xcode.app |
| Update otomatis | berbeda | cek feed JSON + link unduh, bukan Sparkle |
| Bahasa | sebagian | English & Bahasa Indonesia (bukan 134 bahasa) |

**Troubleshooting**

| Gejala | Solusi |
| --- | --- |
| Crash `Library not loaded: @rpath/Lottie.framework` | build ulang dengan `./scripts/build_app.sh --install`; pastikan muncul baris `embedded Lottie.framework` |
| Error build `SwiftUIMacros ... not found` | pakai kode terbaru (`@Local`), atau pilih Xcode penuh: `sudo xcode-select -s /Applications/Xcode.app` |
| Setiap aksi Claude Code minta izin di notch | build terbaru lalu klik Install Claude Code hooks lagi; darurat: keluar dari NotchHub atau kembalikan `~/.claude/settings.json.notchhub-backup` |
| Fitur tidak bereaksi setelah build ulang | izinkan ulang di System Settings › Privacy & Security (efek tanda tangan ad-hoc) |
| Musik tidak muncul | izinkan Automation untuk Spotify/Music saat diminta |
| Waktu sholat kosong | izinkan Lokasi atau isi koordinat di Settings › Sholat |
| Adzan hanya berbunyi "ting" | pilih file MP3/M4A adzan di Settings › Sholat |
| Kecepatan video tidak berubah | aktifkan "Allow JavaScript from Apple Events" di menu Developer browser |
| Notifikasi tidak muncul | izinkan NotchHub di System Settings › Notifications |
| Melihat log crash | jalankan `/Applications/NotchHub.app/Contents/MacOS/NotchHub` dari Terminal, atau buka Console.app |
