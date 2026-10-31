# SyncCam

**Many phones, one shutter.** SyncCam turns any mix of Android phones and iPhones into one synchronized multi-camera rig. One phone is the **host**: it sees every camera's live view, changes their settings all at once, and fires them all at the **same instant** on a shared clock. You don't have to line the footage up by hand afterwards.

Built with Flutter, so one codebase covers Android and iOS. Phones talk to each other directly over local Wi-Fi or a phone hotspot. No internet, account, or server is needed.

## Features

### Synchronization (the core)
- **Shared clock.** Every camera keeps estimating the host's clock over UDP, NTP-style (it takes the median of the lowest-round-trip samples and tracks drift). Each tile shows that error live (`±1.2 ms`).
- **Scheduled triggers.** The shutter doesn't say "capture now". It says "capture at host time T", with T ≈ 800 ms ahead. Each phone arms itself (pauses live-view encoding), sleeps, then busy-waits the last 12 ms. That way Wi-Fi jitter has no effect on when the capture fires.
- **Per-device trim.** Phone models have different shutter lag. The **Sync calibration clock** screen shows a millisecond clock with block bars. Point every camera at it, fire a test shot, and type in the time each photo shows. SyncCam then sets each phone's trim automatically.
- **Audio + flash slate.** A sharp 2 kHz beep and a white flash from the host. It fires automatically 1.5 s after a video starts, or whenever you tap **Slate**. Its time is logged in the take manifest.
- **Frame-exact video alignment** with [`tools/align_clips.py`](tools/align_clips.py). It finds the slate beep in every clip (or cross-correlates the audio) and writes trimmed clips that all start on the same frame. It can also build a side-by-side `grid.mp4`.

### Host control
- A live-view grid of every camera, with battery, sync quality, REC timer, upload status and warnings on each tile.
- Global controls that apply to every phone at once: front/back lens, flash (off/auto/on/torch), zoom, exposure compensation, AE lock, AF lock, resolution (240p–4K/max), frame rate, audio on/off, stabilization, JPEG quality, capture-orientation lock, and a grid overlay.
- **Per-device overrides.** Tap a tile for a sharper, faster live view of that phone. Settings you change there (lens, zoom, EV, flash) apply to that phone only. One tap resets them.
- **Tap-to-focus/expose** on any live view. It can apply to one camera or to all of them.
- **Sync status at a glance.** The title bar says "All 4 in sync · ±1.8 ms · Excellent" (or which cameras aren't), and tapping it lists every camera's clock error. After each shot the host reports what happened, e.g. "All 4 cameras fired within 2.1 ms of each other" or "3 of 4 fired · no response from Pixel 7".
- **Sessions.** The host can **End session** (menu, or back): it stops any recording, waits for files to arrive, then sends every camera back to its start screen. A camera can **Leave**; the host removes its tile. A phone that rejoins replaces its old tile instead of appearing twice.
- **Identify.** Long-press a tile and that phone flashes white with its number and vibrates, so you can find it in the rig.
- **Rig order.** Drag cameras into their physical left-to-right order. The order sets file names (`01_…`, `02_…`) and the bullet-time sequence.

### Capture modes
| Mode | What it does |
|---|---|
| **Photo** | One synchronized photo on every camera |
| **Burst** | N synced photos at a fixed interval |
| **Video** | Synchronized start and stop on every camera |
| **Time-lapse** | A synced photo on all cameras every N seconds until stopped |
| **Bullet time** | Any photo mode with a *stagger*: camera k fires k × stagger ms after the first. 0 ms freezes one moment; 20–50 ms gives a time-slice sweep |

You can add a countdown (3/5/10 s). The number shows on the host and on every camera.

### Media
- **Rig health.** Each tile shows free storage, overheating (🔥) and power-saving mode, read natively on both platforms. Pressing record warns you about any phone that is hot, nearly full, in Low Power Mode or not yet synced.
- Each camera uploads its files straight to the host when it captures. The host groups them into **takes**: one folder per shot, holding every angle plus a `manifest.json` with microsecond host-clock timestamps.
- Each phone can also keep its own copy in a "SyncCam" album.
- The **Gallery** (home screen, or the host's toolbar) shows every angle side by side, with each camera's offset in ms and the overall trigger spread. You can save a whole take to Photos or share it (AirDrop, Drive, …) with its manifest.

### Playback and compare
- Every video opens with a **seek bar**: scrub, frame-by-frame step, 0.1×–2× speed, loop.
- **Compare angles** plays every camera of a take on one timeline, lined up with each clip's measured start offset (tap the link icon to see raw clip starts). It has five modes:
  - **Grid:** all angles at once.
  - **Side by side:** two angles, stacked in portrait.
  - **Wipe:** drag a divider across two angles.
  - **Overlay:** fade one angle over another.
  - **Switcher:** a big view plus thumbnails, like a multicam edit.
- You pick which angle's audio you hear. Drift between players is corrected twice a second. Photos compare in the same modes.

### iPhone without the app (browser camera)
- **No app, no certificate (default):** in the host's **Add cameras** sheet choose **iPhone, no app** and scan the QR code with the iPhone's Camera app. Safari opens the SyncCam camera page on GitHub Pages; tap **Start camera**.
  - **How it connects:** the page and the host find each other through a public MQTT relay, exchanging one offer and one answer. They then talk **directly over WebRTC on your Wi-Fi**: commands, clock sync, live view and file uploads.
  - **What the relay sees:** only AES-256-GCM ciphertext. The key travels in the QR code's `#fragment`, which browsers never send to a server.
  - **Internet:** needed only while joining. A phone hotspot with mobile data works.
- **Offline (certificate route):** the **Offline** tab serves the page from the host phone itself. It needs a one-time certificate install per iPhone (Settings → General → VPN & Device Management, then Settings → General → About → Certificate Trust Settings), because Safari only allows the camera, and the secure connection the page needs, on a trusted HTTPS page.
- Both routes run the same page and protocol as the app: live view, synced photo, burst, time-lapse and video triggers, uploads, identify, leave and end-session. Clock sync is about ±1–3 ms on Wi-Fi.
- **Late triggers:** if a camera fires late (for example because it was still restarting), it reports it and the host flags it.
- **Browser limits:**
  - **Photos** are full-resolution frames of the video stream, not the camera's still pipeline.
  - **Controls:** zoom, torch and exposure work only where Safari exposes them.
  - **Foreground only:** keep the tab open and the screen on.
  - **Long recordings** are held in the browser's memory until you stop.

### Dedicated cameras: every brand (host menu → Camera link)
Pick the camera, enter its IP and connect. Every camera can be synced by sound. Most can also be started by SyncCam, and many can lead: pressing record on the camera starts every phone, app or browser.

| Brand | Protocol | Camera's REC starts the phones | SyncCam starts the camera |
|---|---|---|---|
| GoPro HERO9+ | Open GoPro HTTP | ✓ | ✓ |
| Canon EOS / PowerShot | CCAPI (HTTP) | ✓ | ✓ |
| Canon EOS (no CCAPI) | PTP/IP, EOS ops | ✓ | ✓ |
| Nikon Z / DSLR | PTP/IP, Nikon movie ops and events | ✓ | ✓ |
| Sony Alpha / FX (current) | PTP/IP "PC Remote" | ✓ (if the body reports its state) | ✓ |
| Sony Alpha / RX (older) | Camera Remote API (JSON-RPC) | ✓ | ✓ |
| Panasonic Lumix | `cam.cgi` | ✓ | ✓ |
| Blackmagic Cinema/Studio/URSA/PYXIS | Official REST API | ✓ | ✓ |
| Ricoh Theta, Insta360, other 360° | OSC (open standard) | ✓ | ✓ |
| Fujifilm X / GFX | PTP/IP, Fuji movie ops | – | ✓ |
| OM System / Olympus | Wi-Fi CGI | – | ✓ |
| Pentax, Leica, Sigma, other PTP/IP | Standard PTP open capture | – | ✓ |
| **Any camera** | **Sync by sound**: no connection | – | – |

- **Timing:** SyncCam polls (or listens for events) every 150–250 ms and starts the phones about 0.35 s after it sees the camera start, on the shared clock. The host's slate beep is on every recording, including the camera's own, so `tools/align_clips.py <take> --extra <camera clip>` lines the camera's file up with the phones to the frame.
- **Connection log:** every request and answer is listed under **Connection log**, with a Copy button, so a camera that misbehaves shows exactly what it said.
- **How it's built:**
  - **Official or vendor sources:** GoPro and Blackmagic come from the makers' official APIs. Nikon, Canon, Sony and Fujifilm PTP codes come from libgphoto2.
  - **Community and open sources:** Lumix, Sony Remote API and OM System from community documentation, and OSC from Google's open spec.
- **Testing:** each driver passes tests against a simulated camera speaking its protocol. The PTP/IP ones use a fake camera implementing PTP/IP over real TCP. They have not yet been tested on physical cameras; the connection log is there for that first test.
- **Not reachable:** DJI Osmo and other closed-protocol cameras. Use sync by sound for those.

### Camera phones
- Join by auto-discovery (Bonjour/NSD), by scanning the host's QR code, or by typing the host's IP. They reconnect automatically if Wi-Fi drops.
- **Updates.** On launch the app checks this repo's GitHub Releases and shows a banner when a newer version exists (Android downloads the APK; iPhone opens the release page). The host flags any camera running a different version, since mixed versions can break timing.
- Keep-awake, plus a **dim** mode that blacks out the screen to save battery while still recording.
- The host phone can **be a camera too**: it joins its own session over loopback.
- If camera permission is off, the phone says so and offers **Try again** instead of spinning forever.
- A phone that drops out mid-recording keeps recording. The host reports it, and stops it when it reconnects if the take is over.

## Running it

Requires Flutter 3.38+ (built and tested with 3.47).

```bash
flutter pub get
flutter run            # pick a connected Android or iOS device
```

Release builds:

```bash
flutter build apk --release
```

```bash
flutter build ipa      # on a Mac with Xcode; set your signing team in ios/Runner.xcworkspace first
```

### iOS

All of `lib/` runs unchanged on iPhone. The iOS-specific parts are:

| File | What it does |
|---|---|
| `ios/Runner/AppDelegate.swift` | `DeviceHealthPlugin`: thermal state, Low Power Mode and free storage over the `synccam/device` channel (Android twin in `MainActivity.kt`) |
| `ios/Runner/Info.plist` | Camera, microphone, photo-library and local-network permission text; Bonjour service `_synccam._tcp`; full-screen on iPad; export-compliance flag |
| `ios/Runner/PrivacyInfo.xcprivacy` | App Store privacy manifest: no tracking or data collection; declares UserDefaults, disk-space and system-boot-time API reasons |

The Dart code also has iOS-specific behaviour:
- The slate beep uses a `playAndRecord` + `mixWithOthers` audio session, so it never interrupts a recording on the host phone.
- After iOS suspends the app, the host reopens its listening sockets and camera phones restart clock sync.
- iOS already mirrors front-camera frames, so the live-view encoder only flips them on Android.

**Downloads.** Pushing a version tag publishes a GitHub Release with the Android APK and the unsigned iOS IPA:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

**Android signing key.** Every release APK is signed with one permanent key, so a new version installs over the old one and keeps the phone's settings and identity. The key lives in GitHub secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`). CI refuses to publish an APK whose certificate SHA-256 isn't `d07074bf…73ebc7`. To sign a local release build, set `SYNCCAM_KEY_PROPERTIES` to the path of your `key.properties`. **Keep a backup of the keystore and its password:** if they are lost, no future update can install over existing installs.

**No Mac?** There are two cloud options:
- **GitHub Actions** ([.github/workflows/build.yml](.github/workflows/build.yml)): push the project to GitHub and every push runs tests, builds the Android APK and builds iOS on a macOS runner. You get an *unsigned* iOS build, which proves it compiles but can't be installed.
- **Codemagic** ([codemagic.yaml](codemagic.yaml)): signs the app with your Apple Developer account and uploads it to **TestFlight**, so you can install it on any iPhone. The setup steps are at the top of the file. An Apple Developer membership is required for any iPhone install outside a Mac's Xcode.

On first launch, iOS asks for **Local Network** access. Allow it on every phone, or the host and cameras can't see each other. If it was denied, re-enable it in Settings → Privacy & Security → Local Network → SyncCam.

### Using it
1. Put every phone on the **same Wi-Fi**, or turn on a hotspot on the host phone and join the others to it. A hotspot is often the best choice because it has the lowest jitter.
2. On the host phone, tap **Host a session**.
3. On each other phone, tap **Join as camera** and tap the host when it appears (or scan its QR code).
4. Wait for every tile to show a green `±x ms`, then shoot.

For the tightest sync: run the calibration clock once per phone model, keep stabilization off, lock AE/AF before important shots, and keep the slate on for video.

## How accurate is it?

There are three separate parts to the error:

| Part | Typical | Notes |
|---|---|---|
| Clock agreement between phones | 0.5–3 ms on Wi-Fi | Shown live per tile |
| Trigger moment (software) | < 0.2 ms | Coarse sleep, then busy-wait |
| Camera pipeline latency | Photos 30–300 ms, varies by model; video start 50–300 ms | Photos: fixed by per-device trim from the calibration clock. Video: fixed by the slate + `align_clips.py` |

So **photos** land within about one frame (≈10–30 ms) of each other after calibration. **Video** lands frame-exact after `align_clips.py`. Before alignment, each clip's start offset is already recorded in `manifest.json` (`headTrimsMs`), so you can also trim by hand in any editor.

Phone cameras can't be hardware-genlocked. No app on stock phones can make different sensors expose on the exact same microsecond. SyncCam removes everything it can in software and measures the rest precisely, so the final alignment step is automatic.

## Project layout

```
lib/
  core/
    clock.dart          monotonic clock, UDP clock-sync server/client, precise wait
    protocol.dart       message types, CameraSettings model (global + overrides)
    frame_encoder.dart  YUV/BGRA → small JPEG live view on a background isolate
    util.dart           async lock, slate WAV generator, IP helpers
    device_health.dart  thermal / low-power / storage from native code
    updates.dart        app version, GitHub Releases update check
    widgets.dart        small shared widgets (self-ticking timers)
    tls.dart            local certificate authority + HTTPS certs for browser cameras
    seal.dart           AES-256-GCM envelopes for relay messages (matches the browser's WebCrypto)
  host/
    external_camera.dart         camera link: brands, capabilities, HTTP drivers, connection log
    ptpip.dart                   PTP/IP transport (command + event channels, transactions)
    ptp_cameras.dart             Nikon, Canon EOS, Sony, Fujifilm and generic PTP drivers
    rtc_link.dart                WebRTC gateway for the GitHub Pages camera page (relay + data channels)
    external_camera_screen.dart  connect a Wi-Fi camera; "camera leads" switch
    playback.dart       synced multi-clip playback engine, seek bar, single-video player
    compare_screen.dart grid / side-by-side / wipe / overlay / switcher
    host_server.dart    HTTP+WebSocket server, device registry, capture scheduling, uploads, sync reports
    sync_panel.dart     title-bar sync chip + per-camera sync sheet
    take.dart           take model + manifest.json (timing, spread, head trims)
    host_screen.dart    live grid + control panel + QR join sheet
    device_detail_screen.dart, rig_order_screen.dart, calibration_screen.dart,
    gallery_screen.dart, take_screen.dart, host_settings_screen.dart
  node/
    camera_node.dart    camera phone: link, clock sync, camera control, timed capture, upload
    node_screen.dart    viewfinder UI on camera phones
    join_screen.dart    discovery / QR / manual join
assets/web/             browser camera (index.html, app.js, transport.js) and iPhone setup page;
                        CI also publishes it to GitHub Pages (the no-certificate route)
tools/align_clips.py    desktop: frame-align a take's videos (ffmpeg + numpy); --extra for other cameras
tool/make_icon.dart     draws the app icon
test/                   clock sync, trigger precision, take math, TLS certificates
                        (checked by a real TLS handshake and openssl), Wi-Fi camera drivers
                        (against fake cameras), update check
```

### Protocol
- `ws://host:47810/ws`: JSON control messages both ways. Binary frames carry live-view JPEGs from camera to host.
- `POST http://host:47810/upload`: camera uploads a captured file (`x-take`, `x-device`, `x-shot` headers).
- `udp://host:47811`: clock-sync ping/pong (29-byte packets).
- `https://host:47812/`: browser camera page plus the same `/ws` and `/upload`. Browser cameras sync their clock with `ping`/`pong` messages over the WebSocket.
- `http://host:47810/web`: iPhone setup page. `/ca.crt` is the host's CA certificate, and `/ping` is the trust check.
- Bonjour service `_synccam._tcp` for discovery.

## Prior art (researched October 2026)
- **[RecSync](https://github.com/DFKI-SignLanguage/RecSync-android)** (Android) reaches sub-millisecond sync, but needs identical Android 10+ phones and a wired leader.
- **[MultiCameraSync](https://apps.apple.com/bs/app/multicamerasync/id6447541517)** and **[Mobile Choreography](https://apps.apple.com/us/app/id1243391007)** work on iPhone only, and need the app installed.
- **[Detail](https://detail.co/academy/record-two-angles)** connects two iOS devices.
- Users trying to mix an iPhone controller with Android phones [report it fails](https://forum.blackmagicdesign.com/viewtopic.php?p=1123465). None of these mix Android, iPhone and browser cameras, or follow a DSLR.
- **[VDO.Ninja](https://docs.vdo.ninja/getting-started/rooms)** streams phone cameras from the browser over WebRTC, but needs internet to connect and isn't a synced recorder.
- **Wi-Fi camera APIs:**
  - [Open GoPro](https://gopro.github.io/OpenGoPro/http) for GoPro.
  - Canon [CCAPI function list](https://developercommunity.usa.canon.com/s/article/CCAPI-Function-List).
  - Lumix `cam.cgi` as used by [python_lumix_control](https://github.com/palmdalian/python_lumix_control).
  - For a future Nikon, Fuji or Sony driver: the PTP/IP libraries [camlib](https://github.com/dakmh/camlib) and [ptp-ip](https://github.com/malc0mn/ptp-ip).
- Safari blocks WebSockets to self-signed certificates unless the certificate is installed and trusted ([code-server iPad guide](https://github.com/cdr/code-server/blob/v3.7.0/doc/ipad.md)). That's why the browser camera uses a one-time certificate install.

## Known limits and next steps
- The Flutter `camera` plugin has no manual ISO, shutter speed or white balance. Adding these needs a small native extension (Camera2 / AVFoundation). Today, AE/AF lock + EV give consistent exposure across the rig.
- Live view pauses while a phone is recording; its tile shows a REC card with the running time. Streaming frames during recording made phones lag (the camera plugin copies every full-resolution frame into the app), so it's off on both platforms.
- Outside recording, live view grabs single frames at 6 fps (15 fps for the camera opened full-screen), not a continuous stream, for the same reason.
- Large 4K videos upload over Wi-Fi after you stop recording. You can turn uploads off and collect the files from each phone's gallery instead.
- The no-certificate iPhone route needs internet while joining, and uses free public MQTT relays (HiveMQ, then EMQX as fallback). If both are down, use the Offline tab.
- Camera drivers are tested against simulated cameras, not real bodies. Canon CCAPI also needs Canon's activation.
- The Android APK is about 110 MB because the WebRTC library ships for every CPU type. Per-CPU APKs would be about 40 MB each.
- Ideas: automatic calibration (decode the clock from photos on-device), RAW/DNG capture, LTC timecode audio track, and remote file browser per camera.
