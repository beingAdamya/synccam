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

### Camera phones
- Join by auto-discovery (Bonjour/NSD), by scanning the host's QR code, or by typing the host's IP. They reconnect automatically if Wi-Fi drops.
- **Updates.** On launch the app checks this repo's GitHub Releases and shows a banner when a newer version exists (Android downloads the APK; iPhone opens the release page). The host flags any camera running a different version, since mixed versions can break timing.
- Keep-awake, plus a **dim** mode that blacks out the screen to save battery while still recording.
- The host phone can **be a camera too**: it joins its own session over loopback.

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
  host/
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
tools/align_clips.py    desktop: frame-align a take's videos (ffmpeg + numpy)
test/sync_test.dart     clock-sync convergence, trigger precision, take math
```

### Protocol
- `ws://host:47810/ws`: JSON control messages both ways. Binary frames carry live-view JPEGs from camera to host.
- `POST http://host:47810/upload`: camera uploads a captured file (`x-take`, `x-device`, `x-shot` headers).
- `udp://host:47811`: clock-sync ping/pong (29-byte packets).
- Bonjour service `_synccam._tcp` for discovery.

## Known limits and next steps
- The Flutter `camera` plugin has no manual ISO, shutter speed or white balance. Adding these needs a small native extension (Camera2 / AVFoundation). Today, AE/AF lock + EV give consistent exposure across the rig.
- Live view pauses while a phone is recording; its tile shows a REC card with the running time. Streaming frames during recording made phones lag (the camera plugin copies every full-resolution frame into the app), so it's off on both platforms.
- Outside recording, live view grabs single frames at 6 fps (15 fps for the camera opened full-screen), not a continuous stream, for the same reason.
- Large 4K videos upload over Wi-Fi after you stop recording. You can turn uploads off and collect the files from each phone's gallery instead.
- Ideas: automatic calibration (decode the clock from photos on-device), RAW/DNG capture, LTC timecode audio track, and remote file browser per camera.
