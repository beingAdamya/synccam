import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/clock.dart';
import '../core/protocol.dart';
import '../core/tls.dart';
import '../core/updates.dart';
import '../core/util.dart';
import 'external_camera.dart';
import 'take.dart';

/// A phone connected to this host as a camera.
class RemoteDevice extends ChangeNotifier {
  RemoteDevice(this.id);

  final String id;
  String name = 'Camera';
  String platform = '';
  String model = '';
  String? lastIp;

  /// App version the camera reported; null for builds before 0.2.0.
  String? appVersion;
  int protocol = Net.protocolVersion;
  WebSocket? ws;
  bool get online => ws != null;

  int slot = 0;

  /// Per-device timing correction in ms. Positive fires this phone earlier,
  /// compensating for a slower shutter pipeline.
  double trimMs = 0;

  /// Per-device settings that differ from the global ones.
  Map<String, dynamic> override = {};

  /// Extra quarter-turns applied to this device's live view on the host.
  int viewTurns = 0;

  // Status reported by the device.
  int? battery;
  bool charging = false;
  bool synced = false;
  double errMs = 0;
  bool recording = false;
  int? recStartHostUs;
  int pendingUploads = 0;
  int captures = 0;
  bool cameraReady = false;
  String? error;
  String? thermal;
  bool lowPower = false;
  int? freeBytes;

  /// Different message format: capture commands may be misread.
  bool get incompatible => protocol != Net.protocolVersion;

  /// Same protocol, different build: works, but timing fixes may differ.
  bool get versionMismatch => appVersion != AppVersion.current;

  bool get hot => thermal == 'serious' || thermal == 'critical';
  bool get lowStorage => freeBytes != null && freeBytes! < 2 * 1024 * 1024 * 1024;
  List<String> lenses = const [];
  double minZoom = 1, maxZoom = 1, minEv = 0, maxEv = 0;

  final ValueNotifier<Uint8List?> frame = ValueNotifier(null);
  int _framesInWindow = 0;
  int _windowStartUs = 0;
  double liveFps = 0;

  void onFrame(Uint8List jpeg) {
    frame.value = jpeg;
    _framesInWindow++;
    final now = MonoClock.nowUs();
    if (now - _windowStartUs > 2000000) {
      liveFps = _framesInWindow * 1e6 / (now - _windowStartUs);
      _framesInWindow = 0;
      _windowStartUs = now;
    }
  }

  void send(String type, [Map<String, dynamic>? body]) {
    try {
      ws?.add(encodeMsg(type, body));
    } catch (_) {}
  }

  void changed() => notifyListeners();
}

/// Capture behaviour chosen on the host.
class CaptureConfig {
  CaptureMode mode = CaptureMode.photo;

  /// Time between pressing the shutter and the synchronized trigger. Must
  /// cover worst-case Wi-Fi delivery + arming; 600-1000 ms is comfortable.
  int leadMs = 800;
  int countdownSec = 0;

  /// Delay added per slot ("bullet-time sweep"). 0 = all fire together.
  int staggerMs = 0;
  int burstCount = 5;
  int burstIntervalMs = 400;
  int intervalSec = 5;
  bool autoUpload = true;
  bool keepCopyOnDevice = true;
  bool autoSlate = true;
}

/// Shown on the host after each trigger: did every camera fire, and how
/// close together.
class CaptureReport {
  CaptureReport(this.text, {required this.ok});
  final String text;
  final bool ok;
}

class HostServer extends ChangeNotifier {
  HostServer({required this.sessionName, required this.library});

  final String sessionName;
  final TakeLibrary library;
  HttpServer? _http;
  final ClockSyncServer _clock = ClockSyncServer();
  nsd.Registration? _registration;
  List<String> addresses = [];
  String? startError;

  final Map<String, RemoteDevice> _devices = {};
  List<RemoteDevice> get devices => _devices.values.toList()..sort((a, b) => a.slot.compareTo(b.slot));
  List<RemoteDevice> get onlineDevices => devices.where((d) => d.online).toList();

  CameraSettings global = CameraSettings();
  final CaptureConfig config = CaptureConfig();

  /// Device currently opened full-screen on the host, which gets a sharper,
  /// faster live view.
  String? focusedDeviceId;

  List<Take> get takes => library.takes;
  Take? activeVideoTake;
  Take? _intervalTake;
  Timer? _intervalTimer;
  bool get intervalRunning => _intervalTimer != null;

  /// Local time of the next trigger, for the host countdown.
  int? nextTriggerUs;
  final ValueNotifier<int> slateFlash = ValueNotifier(0);
  final AudioPlayer _player = AudioPlayer();
  final Uint8List _beep = slateWav();

  SharedPreferences? _prefs;
  HttpServer? _https;
  LocalCa? _ca;
  Map<String, String>? _web;
  Timer? _ipWatch;
  String? httpsError;

  /// Optional Wi-Fi camera (GoPro, Canon, Lumix). When [externalLeads], its
  /// own record button starts and stops every phone.
  ExternalCamera? external;
  bool externalLeads = true;
  final StreamController<CaptureReport> _reports = StreamController.broadcast();
  Stream<CaptureReport> get reports => _reports.stream;
  int _activeUploads = 0;

  int nowUs() => MonoClock.nowUs();

  Future<void> start() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      // The slate must not steal the audio session from the camera: on iOS a
      // plain playback session would interrupt the host phone's own
      // recording, and on Android taking audio focus can pause the mic.
      await _player.setAudioContext(AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: const {AVAudioSessionOptions.mixWithOthers, AVAudioSessionOptions.defaultToSpeaker},
        ),
        android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
      ));
    } catch (e) {
      debugPrint('audio context: $e');
    }
    await _bindNetwork();
    final saved = _prefs?.getString('external');
    if (saved != null) {
      externalLeads = _prefs?.getBool('external.leads') ?? true;
      final cfg = ExternalConfig.fromJson((jsonDecode(saved) as Map).cast<String, dynamic>());
      if (cfg != null) unawaited(setExternal(cfg));
    }
    try {
      _registration = await nsd.register(
        nsd.Service(name: sessionName, type: Net.serviceType, port: Net.httpPort),
      );
    } catch (e) {
      debugPrint('NSD register failed: $e');
    }
    notifyListeners();
  }

  Future<void> _bindNetwork() async {
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, Net.httpPort, shared: true);
      _http!.listen(_onRequest);
      await _clock.start();
      startError = null;
    } catch (e) {
      startError = 'Could not open network ports: $e';
    }
    addresses = await localIPv4s();
    await _bindHttps();
    // Wi-Fi changes (joining a hotspot, a camera's network) change this
    // phone's IP; the HTTPS certificate must name the current addresses.
    _ipWatch ??= Timer.periodic(const Duration(seconds: 10), (_) => _checkAddresses());
  }

  /// HTTPS for browser cameras, with a certificate from this phone's local
  /// CA naming its current IP addresses.
  Future<void> _bindHttps() async {
    await _https?.close(force: true);
    _https = null;
    try {
      _web ??= await _loadWebAssets();
      _ca ??= await LocalCa.loadOrCreate(Directory('${(await getApplicationSupportDirectory()).path}/tls'));
      final ctx = _ca!.serverContext([...addresses, '127.0.0.1']);
      _https = await HttpServer.bindSecure(InternetAddress.anyIPv4, Net.httpsPort, ctx, shared: true);
      _https!.listen(_onRequest);
      httpsError = null;
    } catch (e) {
      httpsError = 'Browser cameras unavailable: $e';
    }
  }

  Future<void> _checkAddresses() async {
    final now = await localIPv4s();
    if (now.join(',') == addresses.join(',')) return;
    addresses = now;
    await _bindHttps();
    notifyListeners();
  }

  static Future<Map<String, String>> _loadWebAssets() async => {
        for (final f in const ['index.html', 'app.js', 'setup.html']) f: await rootBundle.loadString('assets/web/$f'),
      };

  /// Link an iPhone opens (plain HTTP) to set up trust and reach the camera page.
  String? get webJoinUrl => addresses.isEmpty ? null : 'http://${addresses.first}:${Net.httpPort}/web';
  String? get caFingerprint => _ca?.fingerprint;

  /// iOS tears down the listening sockets of a suspended app. After the host
  /// comes back to the foreground, reopen them; cameras reconnect on their own.
  Future<void> resumeNetwork() async {
    await _http?.close(force: true);
    _http = null;
    await _https?.close(force: true);
    _https = null;
    _clock.stop();
    await _bindNetwork();
    notifyListeners();
  }

  @override
  void dispose() {
    _intervalTimer?.cancel();
    for (final d in _devices.values) {
      d.ws?.close();
    }
    external?.dispose();
    _http?.close(force: true);
    _https?.close(force: true);
    _ipWatch?.cancel();
    _clock.stop();
    final r = _registration;
    if (r != null) nsd.unregister(r);
    _player.dispose();
    _reports.close();
    super.dispose();
  }

  // ------------------------------------------------------------- network

  Future<void> _onRequest(HttpRequest req) async {
    try {
      switch (req.uri.path) {
        case '/ws':
          if (!WebSocketTransformer.isUpgradeRequest(req)) {
            req.response.statusCode = 400;
            await req.response.close();
            return;
          }
          final ip = req.connectionInfo?.remoteAddress.address;
          final ws = await WebSocketTransformer.upgrade(req, compression: CompressionOptions.compressionOff);
          _onSocket(ws, ip);
        case '/upload':
          await _onUpload(req);
        case '/ping':
          // Lets the setup page check from plain HTTP whether this iPhone
          // trusts the HTTPS certificate yet.
          req.response
            ..headers.set('Access-Control-Allow-Origin', '*')
            ..write('ok');
          await req.response.close();
        case '/ca.crt':
          final ca = _ca;
          if (ca == null) throw StateError('no CA');
          req.response
            ..headers.contentType = ContentType('application', 'x-x509-ca-cert')
            ..headers.set('Content-Disposition', 'attachment; filename="SyncCam-Local-CA.crt"')
            ..add(ca.caCertDer);
          await req.response.close();
        case '/web' || '/setup':
          await _sendPage(req, 'setup.html');
        case '/' when req.requestedUri.scheme == 'https':
          await _sendPage(req, 'index.html');
        case '/app.js':
          await _sendPage(req, 'app.js', type: ContentType('text', 'javascript', charset: 'utf-8'));
        case '/':
          // Plain HTTP root: send browsers to the setup page.
          req.response
            ..statusCode = HttpStatus.found
            ..headers.set('Location', '/web');
          await req.response.close();
        default:
          req.response
            ..statusCode = 404
            ..write('Not found');
          await req.response.close();
      }
    } catch (e) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _sendPage(HttpRequest req, String file, {ContentType? type}) async {
    String esc(String v) => const HtmlEscape().convert(v);
    final body = (_web?[file] ?? '')
        .replaceAll('{{SESSION}}', esc(sessionName).replaceAll("'", '&#39;'))
        .replaceAll('{{VERSION}}', AppVersion.current)
        .replaceAll('{{PROTOCOL}}', '${Net.protocolVersion}')
        .replaceAll('{{HTTPS_PORT}}', '${Net.httpsPort}')
        .replaceAll('{{FINGERPRINT}}', _ca?.fingerprint ?? '');
    req.response
      ..headers.contentType = type ?? ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(body);
    await req.response.close();
  }

  void _onSocket(WebSocket ws, String? ip) {
    RemoteDevice? dev;
    ws.listen(
      (data) {
        final receivedUs = nowUs();
        if (data is Uint8List || data is List<int>) {
          final b = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
          if (dev != null && b.length > 2 && b[0] == PreviewFrame.magic && b[1] == PreviewFrame.kindJpeg) {
            dev!.onFrame(Uint8List.sublistView(b, 2));
          }
          return;
        }
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        if (m['t'] == Msg.ping) {
          // NTP-style reply for browser cameras: receive and send times.
          ws.add(encodeMsg(Msg.pong, {'c': m['c'], 'h1': receivedUs, 'h2': nowUs()}));
          return;
        }
        if (m['t'] == Msg.hello) {
          dev = _onHello(ws, m, ip);
        } else if (dev != null) {
          _onDeviceMessage(dev!, m);
        }
      },
      onDone: () => _onSocketClosed(dev, ws),
      onError: (_) => _onSocketClosed(dev, ws),
      cancelOnError: true,
    );
  }

  RemoteDevice _onHello(WebSocket ws, Map<String, dynamic> m, String? ip) {
    final id = m['id'] as String;
    final isNew = !_devices.containsKey(id);
    // The same phone rejoining under a new id (reinstalled app, cleared
    // data) must replace its old offline tile, not add a second one.
    final stale = isNew ? _findStale(m, ip) : null;
    final d = _devices.putIfAbsent(id, () => RemoteDevice(id));
    d.lastIp = ip ?? d.lastIp;
    d.ws?.close();
    d.ws = ws;
    d.name = m['name'] as String? ?? d.name;
    d.platform = m['platform'] as String? ?? '';
    d.model = m['model'] as String? ?? '';
    d.appVersion = m['app'] as String?;
    d.protocol = (m['v'] as num?)?.toInt() ?? 0;
    if (stale != null) {
      _devices.remove(stale.id);
      d
        ..slot = stale.slot
        ..trimMs = stale.trimMs
        ..override = stale.override
        ..viewTurns = stale.viewTurns;
      _saveDevicePrefs(d);
    } else if (isNew) {
      _restoreDevicePrefs(d);
      if (d.slot >= 1 << 20 || _slotTaken(d)) {
        d.slot = _devices.values.where((x) => x != d).fold(-1, (a, x) => x.slot > a ? x.slot : a) + 1;
      }
    }
    d.send(Msg.welcome, {'session': sessionName, 'slot': d.slot});
    _sendPolicy(d);
    _sendSettings(d);
    _sendPreviewConfig(d);
    notifyListeners();
    return d;
  }

  RemoteDevice? _findStale(Map<String, dynamic> hello, String? ip) {
    for (final x in _devices.values) {
      if (x.online) continue;
      // Same model, plus the same address or the same name. Model alone
      // isn't enough (a rig can have several identical phones), and an
      // address alone could be reused by a different phone.
      final sameModel = x.model.isNotEmpty && x.model == hello['model'];
      final sameIp = ip != null && x.lastIp == ip;
      if (sameModel && (sameIp || x.name == hello['name'])) return x;
    }
    return null;
  }

  bool _slotTaken(RemoteDevice d) => _devices.values.any((x) => x != d && x.slot == d.slot);

  void _onSocketClosed(RemoteDevice? d, WebSocket ws) {
    if (d == null || d.ws != ws) return;
    if (d.recording && !_reports.isClosed) {
      _reports.add(CaptureReport(
          '${d.name} lost connection while recording. It keeps recording, and SyncCam stops it '
          'when it reconnects if the take is over.',
          ok: false));
    }
    d.ws = null;
    d.recording = false;
    d.changed();
    notifyListeners();
  }

  void _onDeviceMessage(RemoteDevice d, Map<String, dynamic> m) {
    switch (m['t']) {
      case Msg.status:
        d.battery = (m['battery'] as num?)?.toInt();
        d.charging = m['charging'] as bool? ?? false;
        d.synced = m['synced'] as bool? ?? false;
        d.errMs = (m['errMs'] as num?)?.toDouble() ?? 0;
        d.recording = m['recording'] as bool? ?? false;
        d.recStartHostUs = (m['recStartHostUs'] as num?)?.toInt();
        d.pendingUploads = (m['pendingUploads'] as num?)?.toInt() ?? 0;
        d.captures = (m['captures'] as num?)?.toInt() ?? 0;
        d.cameraReady = m['cameraReady'] as bool? ?? false;
        d.error = m['err'] as String?;
        d.thermal = m['thermal'] as String?;
        d.lowPower = m['lowPower'] as bool? ?? false;
        d.freeBytes = (m['freeBytes'] as num?)?.toInt();
        // A camera that dropped out mid-take and came back after the host
        // stopped would otherwise record forever.
        if (d.recording && activeVideoTake == null) {
          d.send(Msg.stopVideo, {'at': nowUs() + 300000});
        }
        d.changed();
        notifyListeners();
      case Msg.caps:
        d.lenses = ((m['lenses'] as List?) ?? const []).cast<String>();
        d.minZoom = (m['minZoom'] as num?)?.toDouble() ?? 1;
        d.maxZoom = (m['maxZoom'] as num?)?.toDouble() ?? 1;
        d.minEv = (m['minEv'] as num?)?.toDouble() ?? 0;
        d.maxEv = (m['maxEv'] as num?)?.toDouble() ?? 0;
        d.changed();
        notifyListeners();
      case Msg.captured:
        final take = library.byId(m['take'] as String?);
        if (take == null) return;
        take.addCapture(d, m);
        take.save();
        library.changed();
        notifyListeners();
      case Msg.bye:
        // Left on purpose: remove the tile rather than show it offline.
        _devices.remove(d.id);
        if (focusedDeviceId == d.id) focusedDeviceId = null;
        notifyListeners();
      case Msg.error:
        d.error = m['msg'] as String?;
        d.changed();
        notifyListeners();
    }
  }

  Future<void> _onUpload(HttpRequest req) async {
    final h = req.headers;
    final deviceId = h.value('x-device') ?? '';
    final take = library.byId(h.value('x-take'));
    // The camera may already have left; its take record still knows it.
    final d = _devices[deviceId];
    final td = take?.device(deviceId);
    if (take == null || (d == null && td == null)) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final shot = int.tryParse(h.value('x-shot') ?? '') ?? 0;
    final ext = (h.value('x-ext') ?? 'bin').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final name = d?.name ?? td!.name;
    final slot = d?.slot ?? td!.slot;
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final fileName =
        '${(slot + 1).toString().padLeft(2, '0')}_${safeName}_s${shot.toString().padLeft(3, '0')}.$ext';
    final file = File('${take.dir.path}/$fileName');
    await file.create(recursive: true);
    _activeUploads++;
    notifyListeners();
    try {
      await req.cast<List<int>>().pipe(file.openWrite());
    } finally {
      _activeUploads--;
    }
    take.attachFile(deviceId, shot, fileName);
    await take.save();
    req.response.statusCode = 200;
    await req.response.close();
    library.changed();
    notifyListeners();
  }

  // ------------------------------------------------------------ settings

  void _sendSettings(RemoteDevice d) =>
      d.send(Msg.settings, {'s': global.merged(d.override).toJson()});

  void _sendPolicy(RemoteDevice d) => d.send(Msg.policy, {
        'autoUpload': config.autoUpload,
        'keepCopy': config.keepCopyOnDevice,
      });

  void _sendPreviewConfig(RemoteDevice d) {
    final focused = d.id == focusedDeviceId;
    d.send(Msg.preview, {
      'on': true,
      'fps': focused ? 15 : (onlineDevices.length > 6 ? 4 : 6),
      'max': focused ? 720 : 360,
      'q': focused ? 70 : 55,
    });
  }

  /// Change a global setting and push it to every camera at once.
  void updateGlobal(void Function(CameraSettings s) change) {
    change(global);
    for (final d in onlineDevices) {
      _sendSettings(d);
    }
    notifyListeners();
  }

  /// Change a setting on one device only (kept as an override).
  void updateDevice(RemoteDevice d, String key, Object? value) {
    d.override[key] = value;
    _sendSettings(d);
    _saveDevicePrefs(d);
    d.changed();
    notifyListeners();
  }

  void clearOverrides(RemoteDevice d) {
    d.override.clear();
    _sendSettings(d);
    _saveDevicePrefs(d);
    d.changed();
    notifyListeners();
  }

  void updatePolicy() {
    for (final d in onlineDevices) {
      _sendPolicy(d);
    }
    notifyListeners();
  }

  void setFocused(String? id) {
    final prev = focusedDeviceId;
    focusedDeviceId = id;
    for (final d in _devices.values.where((d) => d.id == prev || d.id == id)) {
      _sendPreviewConfig(d);
    }
  }

  void focusAt(RemoteDevice d, double x, double y, {bool all = false}) {
    for (final t in all ? onlineDevices : [d]) {
      t.send(Msg.focusAt, {'x': x, 'y': y});
    }
  }

  void identify(RemoteDevice d) => d.send(Msg.identify);

  void rename(RemoteDevice d, String name) {
    d.name = name;
    d.send(Msg.rename, {'name': name});
    d.changed();
    notifyListeners();
  }

  void setTrim(RemoteDevice d, double ms) {
    d.trimMs = ms;
    _saveDevicePrefs(d);
    d.changed();
    notifyListeners();
  }

  void rotateView(RemoteDevice d) {
    d.viewTurns = (d.viewTurns + 1) % 4;
    _saveDevicePrefs(d);
    d.changed();
  }

  void removeDevice(RemoteDevice d) {
    d.ws?.close();
    _devices.remove(d.id);
    notifyListeners();
  }

  /// Reorder the rig (slot order drives bullet-time stagger and file names).
  void reorder(int oldIndex, int newIndex) {
    final list = devices;
    final d = list.removeAt(oldIndex);
    list.insert(newIndex, d);
    for (var i = 0; i < list.length; i++) {
      list[i].slot = i;
      list[i].send(Msg.welcome, {'session': sessionName, 'slot': i});
      _saveDevicePrefs(list[i]);
    }
    notifyListeners();
  }

  void _saveDevicePrefs(RemoteDevice d) {
    _prefs?.setString(
        'dev.${d.id}',
        jsonEncode({
          'slot': d.slot,
          'trim': d.trimMs,
          'override': d.override,
          'turns': d.viewTurns,
        }));
  }

  void _restoreDevicePrefs(RemoteDevice d) {
    final raw = _prefs?.getString('dev.${d.id}');
    if (raw == null) {
      d.slot = 1 << 20; // forces a fresh slot assignment
      return;
    }
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      d.slot = (j['slot'] as num?)?.toInt() ?? 0;
      d.trimMs = (j['trim'] as num?)?.toDouble() ?? 0;
      d.override = (j['override'] as Map?)?.cast<String, dynamic>() ?? {};
      d.viewTurns = (j['turns'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  // ------------------------------------------------------------- capture

  /// Problems worth knowing about before a take: a phone that is overheating
  /// (iOS stops recording at "critical"), in power-saving mode (lower frame
  /// rates), or about to run out of space.
  List<String> preflightWarnings() => [
        for (final d in onlineDevices) ...[
          if (d.incompatible)
            '${d.name} runs an incompatible SyncCam (${d.appVersion ?? 'old build'}); update it'
          else if (d.versionMismatch)
            '${d.name} runs SyncCam ${d.appVersion ?? 'older than 0.2.0'}, host has ${AppVersion.current}',
          if (d.hot) '${d.name} is ${d.thermal == 'critical' ? 'overheating' : 'hot'}',
          if (d.lowStorage) '${d.name} has only ${formatBytes(d.freeBytes!)} free',
          if (d.lowPower) '${d.name} is in power-saving mode',
          if (!d.synced) '${d.name} is not clock-synced yet',
        ],
      ];

  List<RemoteDevice> get outdatedDevices =>
      onlineDevices.where((d) => d.incompatible || d.versionMismatch).toList();

  bool get anyRecording => onlineDevices.any((d) => d.recording) || activeVideoTake != null;

  int _triggerTime({int extraMs = 0}) =>
      nowUs() + (config.leadMs + config.countdownSec * 1000 + extraMs) * 1000;

  /// Per-device fire time: shared trigger + bullet-time stagger - trim.
  int _deviceTime(RemoteDevice d, int baseUs, int index) =>
      baseUs + index * config.staggerMs * 1000 - (d.trimMs * 1000).round();

  Take _newTake(CaptureMode mode, int scheduledUs) {
    final t = Take.create(library.dir, mode.name, scheduledUs, config.staggerMs, [
      for (final d in onlineDevices) TakeDevice(d.id, d.name, d.slot, d.model, d.trimMs),
    ]);
    library.add(t);
    t.save();
    return t;
  }

  /// The big shutter button.
  void shutter() {
    if (onlineDevices.isEmpty) return;
    HapticFeedback.mediumImpact();
    switch (config.mode) {
      case CaptureMode.photo:
        _photo(count: 1);
      case CaptureMode.burst:
        _photo(count: config.burstCount, intervalMs: config.burstIntervalMs);
      case CaptureMode.video:
        anyRecording ? stopVideo() : startVideo();
      case CaptureMode.interval:
        intervalRunning ? stopInterval() : startInterval();
    }
  }

  Take _photo({required int count, int intervalMs = 0, Take? into, int shot = 0}) {
    final base = _triggerTime();
    final take = into ?? _newTake(count > 1 ? CaptureMode.burst : CaptureMode.photo, base);
    final list = onlineDevices;
    for (var i = 0; i < list.length; i++) {
      list[i].send(Msg.capturePhoto, {
        'take': take.id,
        'shot': shot,
        'at': _deviceTime(list[i], base, i),
        'count': count,
        'interval': intervalMs,
      });
    }
    _markTrigger(base);
    if (shot == 0) _reportAfter(take, 0, base, video: false);
    return take;
  }

  /// Fires a synchronized single photo, e.g. from the calibration screen.
  Take testShot() => _photo(count: 1);

  /// Starts every phone. [fromCameraUs] means the Wi-Fi camera started on
  /// its own and was seen at that time: start the phones as fast as safely
  /// possible rather than after the normal lead.
  void startVideo({int? fromCameraUs}) {
    final base = fromCameraUs != null ? nowUs() + 350000 : _triggerTime();
    final take = _newTake(CaptureMode.video, base);
    activeVideoTake = take;
    final cam = external;
    if (cam != null && cam.connected) {
      take.external = {
        'model': cam.model ?? cam.config.kind.label,
        'kind': cam.config.kind.name,
        'led': fromCameraUs != null,
        'seenHostUs': ?fromCameraUs,
      };
      if (fromCameraUs == null && !cam.recording) {
        // Pressed in SyncCam: start the camera at the same trigger instant.
        Timer(Duration(microseconds: max(0, base - nowUs())), () {
          cam.startRecording().catchError((Object e) {
            _reports.add(CaptureReport('${cam.model ?? 'Camera'} did not start: $e', ok: false));
          });
        });
      }
      take.save();
    }
    final list = onlineDevices;
    for (var i = 0; i < list.length; i++) {
      list[i].send(Msg.startVideo, {'take': take.id, 'at': _deviceTime(list[i], base, i)});
    }
    _markTrigger(base);
    _reportAfter(take, 0, base, video: true);
    if (config.autoSlate) {
      // Fire a slate ~1.5 s after the trigger, once every phone is rolling.
      final delay = Duration(microseconds: base - nowUs() + 1500000);
      Timer(delay, () {
        if (activeVideoTake == take) slate();
      });
    }
    notifyListeners();
  }

  void stopVideo({bool fromCamera = false}) {
    // Stop is less timing-critical; use a short lead so it feels responsive.
    final base = nowUs() + 400000;
    final cam = external;
    if (!fromCamera && cam != null && cam.connected && cam.recording) {
      Timer(Duration(microseconds: base - nowUs()), () => cam.stopRecording().catchError((_) {}));
    }
    final list = onlineDevices;
    for (var i = 0; i < list.length; i++) {
      list[i].send(Msg.stopVideo, {'at': _deviceTime(list[i], base, i)});
    }
    activeVideoTake = null;
    notifyListeners();
  }

  void startInterval() {
    final take = _newTake(CaptureMode.interval, _triggerTime());
    _intervalTake = take;
    var shot = 0;
    _photo(count: 1, into: take, shot: shot++);
    _intervalTimer = Timer.periodic(Duration(seconds: config.intervalSec), (_) {
      _photo(count: 1, into: take, shot: shot++);
    });
    notifyListeners();
  }

  void stopInterval() {
    _intervalTimer?.cancel();
    _intervalTimer = null;
    _intervalTake = null;
    notifyListeners();
  }

  void _markTrigger(int baseUs) {
    nextTriggerUs = baseUs;
    notifyListeners();
    Timer(Duration(microseconds: baseUs - nowUs() + 50000), () {
      if (nextTriggerUs == baseUs) {
        nextTriggerUs = null;
        notifyListeners();
      }
    });
  }

  /// Audio + visual slate ("clapperboard"): a sharp beep from the host phone
  /// that every camera's microphone records, plus a white screen flash. The
  /// time is logged in the active take so clips can be aligned exactly.
  Future<void> slate() async {
    final at = nowUs();
    slateFlash.value++;
    final t = activeVideoTake ?? _intervalTake;
    if (t != null) {
      t.slates.add(at);
      t.save();
    }
    try {
      await _player.play(BytesSource(_beep, mimeType: 'audio/wav'));
    } catch (e) {
      debugPrint('slate audio failed: $e');
    }
  }

  Future<void> deleteTake(Take t) => library.delete(t);

  // ------------------------------------------------------ external camera

  Future<void> setExternal(ExternalConfig? cfg, {bool? leads}) async {
    external?.dispose();
    external = null;
    if (leads != null) externalLeads = leads;
    await _prefs?.setBool('external.leads', externalLeads);
    if (cfg == null) {
      await _prefs?.remove('external');
      notifyListeners();
      return;
    }
    await _prefs?.setString('external', jsonEncode(cfg.toJson()));
    final cam = ExternalCamera.create(cfg);
    cam.onRecordingChanged = _onExternalRecording;
    cam.addListener(notifyListeners);
    external = cam;
    notifyListeners();
    await cam.start();
  }

  void setExternalLeads(bool v) {
    externalLeads = v;
    _prefs?.setBool('external.leads', v);
    notifyListeners();
  }

  void _onExternalRecording(bool recording, int seenUs) {
    if (!externalLeads || onlineDevices.isEmpty) return;
    final name = external?.model ?? 'Camera';
    if (recording && !anyRecording) {
      startVideo(fromCameraUs: seenUs);
      _reports.add(CaptureReport('$name started recording → starting ${onlineDevices.length} phones', ok: true));
    } else if (!recording && anyRecording) {
      stopVideo(fromCamera: true);
      _reports.add(CaptureReport('$name stopped → stopping all phones', ok: true));
    }
  }

  // ------------------------------------------------------------- session

  /// Files still on their way to this host: uploads in progress here plus
  /// those each camera has queued.
  int get pendingFiles => _activeUploads + onlineDevices.fold(0, (a, d) => a + d.pendingUploads);

  /// Stops anything still capturing, so ending a session never cuts a clip.
  void wrapUpCaptures() {
    stopInterval();
    if (anyRecording) stopVideo();
  }

  /// Tells every camera the session is over; they return to their start
  /// screen instead of trying to reconnect.
  void endSession() {
    for (final d in onlineDevices) {
      d.send(Msg.endSession);
    }
  }

  // ---------------------------------------------------------- sync report

  static String syncQuality(double errMs) => errMs < 2
      ? 'Excellent'
      : errMs < 5
          ? 'Good'
          : errMs < 15
              ? 'Fair'
              : 'Poor';

  /// After a trigger, check what actually happened on each camera and post
  /// a one-line verdict ("All 4 fired within 1.8 ms").
  void _reportAfter(Take take, int shot, int baseUs, {required bool video}) {
    final wait = Duration(microseconds: max(0, baseUs - nowUs()) + (video ? 2500000 : 3500000));
    Timer(wait, () {
      if (_reports.isClosed) return;
      final expected = take.devices;
      final starts = <String, int>{};
      if (video) {
        for (final td in expected) {
          final s = _devices[td.id]?.recStartHostUs;
          if (s != null) starts[td.id] = s - td.slot * take.staggerMs * 1000;
        }
      } else {
        for (final it in take.itemsForShot(shot)) {
          final s = it.startUs;
          final td = take.device(it.deviceId);
          if (s != null && td != null) starts[td.id] = s - td.slot * take.staggerMs * 1000;
        }
      }
      final missing = [for (final td in expected) if (!starts.containsKey(td.id)) td.name];
      final spread = starts.length < 2
          ? 0.0
          : (starts.values.reduce(max) - starts.values.reduce(min)) / 1000.0;
      final n = expected.length;
      if (missing.isNotEmpty) {
        _reports.add(CaptureReport(
            '${starts.length} of $n cameras ${video ? 'started recording' : 'fired'} · no response from ${missing.join(', ')}',
            ok: false));
      } else if (video) {
        _reports.add(CaptureReport(
            'All $n cameras recording · starts within ${spread.toStringAsFixed(0)} ms '
            '(logged per clip, and removed exactly by the slate when aligning)',
            ok: true));
      } else {
        _reports.add(CaptureReport(
            n == 1 ? 'Captured on 1 camera' : 'All $n cameras fired within ${spread.toStringAsFixed(1)} ms of each other',
            ok: spread < 20));
      }
    });
  }
}
