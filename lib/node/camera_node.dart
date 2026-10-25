import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/clock.dart';
import '../core/device_health.dart';
import '../core/frame_encoder.dart';
import '../core/protocol.dart';
import '../core/updates.dart';
import '../core/util.dart';

enum LinkState { connecting, connected, disconnected }

/// Stable identity for this phone, persisted across launches.
class NodeIdentity {
  NodeIdentity(this.id, this.name);
  final String id;
  String name;

  static Future<NodeIdentity> load() async {
    final p = await SharedPreferences.getInstance();
    var id = p.getString('node.id');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await p.setString('node.id', id);
    }
    var name = p.getString('node.name');
    if (name == null) {
      name = await _defaultName();
      await p.setString('node.name', name);
    }
    return NodeIdentity(id, name);
  }

  static Future<String> _defaultName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return a.model;
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return i.name;
      }
    } catch (_) {}
    return 'Camera';
  }

  Future<void> rename(String n) async {
    name = n;
    final p = await SharedPreferences.getInstance();
    await p.setString('node.name', n);
  }
}

/// One phone acting as a remotely controlled camera.
///
/// Owns the WebSocket link to the host, the UDP clock-sync client, and the
/// native camera. Every camera operation goes through [_lock] so a scheduled
/// capture can never be interleaved with a settings change.
class CameraNode extends ChangeNotifier {
  CameraNode({required this.hostAddress, this.port = Net.httpPort, required this.identity});

  final String hostAddress;
  final int port;
  final NodeIdentity identity;

  LinkState link = LinkState.connecting;
  String? lastError;
  String sessionName = '';
  int slot = 0;

  CameraController? controller;
  List<CameraDescription> _cameras = [];
  CameraSettings settings = CameraSettings();
  double minZoom = 1, maxZoom = 1, minEv = 0, maxEv = 0, evStep = 0;

  bool recording = false;
  int? recordStartLocalUs;
  String? _recordTake;
  int _recStartCalledHost = 0, _recStartReturnedHost = 0;

  /// Local time of an upcoming capture, so the UI can show a countdown.
  int? countdownTargetLocalUs;
  DateTime? identifyUntil;
  int capturesThisSession = 0;
  int pendingUploads = 0;
  DeviceHealth health = DeviceHealth();

  /// Set when the session is over: 'host' (host ended it) or 'left'.
  String? ended;

  bool autoUpload = true;
  bool keepCopy = true;

  // Live-view config, driven by the host.
  bool _previewEnabled = true;
  int _previewFps = 6;
  int _previewMax = 360;
  int _previewQ = 55;
  bool _liveHold = true;
  Timer? _pulseTimer;
  Future<void>? _pulseOp;

  WebSocket? _ws;
  ClockSyncClient? clock;
  final FrameEncoder _encoder = FrameEncoder();
  final AsyncLock _lock = AsyncLock();
  Timer? _statusTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  final Battery _battery = Battery();

  Future<void> start() async {
    await _encoder.start();
    try {
      _cameras = await availableCameras();
    } catch (e) {
      lastError = 'Camera unavailable: $e';
    }
    await _lock.run(() => _initCamera(settings));
    final addr = InternetAddress.tryParse(hostAddress) ??
        (await InternetAddress.lookup(hostAddress)).first;
    clock = ClockSyncClient(addr)..onUpdate = notifyListeners;
    await clock!.start();
    _connect();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sendStatus());
  }

  // ---------------------------------------------------------------- link

  Future<void> _connect() async {
    if (_disposed) return;
    link = LinkState.connecting;
    notifyListeners();
    try {
      final ws = await WebSocket.connect('ws://$hostAddress:$port/ws')
          .timeout(const Duration(seconds: 6));
      ws.pingInterval = const Duration(seconds: 3);
      _ws = ws;
      link = LinkState.connected;
      lastError = null;
      notifyListeners();
      _send(Msg.hello, await _helloBody());
      _sendCaps();
      ws.listen(
        (data) {
          if (data is String) _onMessage(jsonDecode(data) as Map<String, dynamic>);
        },
        onDone: _onLinkLost,
        onError: (_) => _onLinkLost(),
        cancelOnError: true,
      );
    } catch (e) {
      lastError = 'Cannot reach host: $e';
      _onLinkLost();
    }
  }

  void _onLinkLost() {
    _ws = null;
    if (_disposed || ended != null) return;
    link = LinkState.disconnected;
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _connect);
  }

  void _send(String type, [Map<String, dynamic>? body]) {
    try {
      _ws?.add(encodeMsg(type, body));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _helloBody() async {
    var model = '';
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        model = '${a.manufacturer} ${a.model} (Android ${a.version.release})';
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        model = '${i.utsname.machine} (iOS ${i.systemVersion})';
      }
    } catch (_) {}
    return {
      'id': identity.id,
      'name': identity.name,
      'platform': Platform.operatingSystem,
      'model': model,
      'v': Net.protocolVersion,
      'app': AppVersion.current,
    };
  }

  void _sendCaps() {
    _send(Msg.caps, {
      'lenses': {for (final c in _cameras) c.lensDirection.name}.toList(),
      'minZoom': minZoom,
      'maxZoom': maxZoom,
      'minEv': minEv,
      'maxEv': maxEv,
      'evStep': evStep,
    });
  }

  Future<void> _sendStatus() async {
    if (_ws == null) return;
    int? battery;
    bool charging = false;
    try {
      battery = await _battery.batteryLevel;
      charging = (await _battery.batteryState) == BatteryState.charging;
    } catch (_) {}
    health = await DeviceHealth.read();
    final c = clock;
    _send(Msg.status, {
      'thermal': health.thermal,
      'lowPower': health.lowPower,
      'freeBytes': health.freeBytes,
      'battery': battery,
      'charging': charging,
      'synced': c?.isSynced ?? false,
      'offsetMs': (c?.offsetUs ?? 0) / 1000.0,
      'errMs': c?.errorMs ?? 0,
      'recording': recording,
      'recStartHostUs': recording ? _recStartReturnedHost : null,
      'pendingUploads': pendingUploads,
      'captures': capturesThisSession,
      'cameraReady': controller?.value.isInitialized ?? false,
      'lens': settings.lens.name,
      'err': lastError,
    });
  }

  // ------------------------------------------------------------ messages

  void _onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case Msg.welcome:
        sessionName = m['session'] as String? ?? '';
        slot = (m['slot'] as num?)?.toInt() ?? 0;
        notifyListeners();
      case Msg.settings:
        final next = CameraSettings.fromJson((m['s'] as Map).cast<String, dynamic>());
        _lock.run(() => _applySettings(next));
      case Msg.capturePhoto:
        _lock.run(() => _capturePhotos(
              take: m['take'] as String,
              shot: (m['shot'] as num?)?.toInt() ?? 0,
              atHostUs: (m['at'] as num).toInt(),
              count: (m['count'] as num?)?.toInt() ?? 1,
              intervalMs: (m['interval'] as num?)?.toInt() ?? 0,
            ));
      case Msg.startVideo:
        _lock.run(() => _startVideo(m['take'] as String, (m['at'] as num).toInt()));
      case Msg.stopVideo:
        _lock.run(() => _stopVideo((m['at'] as num).toInt()));
      case Msg.focusAt:
        _lock.run(() => _focusAt((m['x'] as num).toDouble(), (m['y'] as num).toDouble()));
      case Msg.identify:
        identifyUntil = DateTime.now().add(const Duration(milliseconds: 1500));
        HapticFeedback.heavyImpact();
        notifyListeners();
        Timer(const Duration(milliseconds: 1600), notifyListeners);
      case Msg.preview:
        _previewEnabled = m['on'] as bool? ?? true;
        _previewFps = (m['fps'] as num?)?.toInt() ?? _previewFps;
        _previewMax = (m['max'] as num?)?.toInt() ?? _previewMax;
        _previewQ = (m['q'] as num?)?.toInt() ?? _previewQ;
        _restartPulseTimer();
      case Msg.endSession:
        _end(byHost: true);
      case Msg.rename:
        identity.rename(m['name'] as String).then((_) => notifyListeners());
      case Msg.policy:
        autoUpload = m['autoUpload'] as bool? ?? autoUpload;
        keepCopy = m['keepCopy'] as bool? ?? keepCopy;
      case Msg.countdown:
        final at = (m['at'] as num?)?.toInt();
        countdownTargetLocalUs = at == null ? null : clock?.hostToLocal(at);
        notifyListeners();
    }
  }

  // -------------------------------------------------------------- camera

  CameraDescription? _pickCamera(LensChoice lens) {
    if (_cameras.isEmpty) return null;
    final want = switch (lens) {
      LensChoice.back => CameraLensDirection.back,
      LensChoice.front => CameraLensDirection.front,
      LensChoice.external => CameraLensDirection.external,
    };
    return _cameras.firstWhere((c) => c.lensDirection == want, orElse: () => _cameras.first);
  }

  Future<void> _initCamera(CameraSettings s) async {
    final desc = _pickCamera(s.lens);
    if (desc == null) return;
    await _pauseLive();
    final old = controller;
    controller = null;
    notifyListeners();
    await old?.dispose();

    final c = CameraController(
      desc,
      ResolutionPreset.values[s.resolution.index],
      enableAudio: s.enableAudio,
      fps: s.fps,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    try {
      await c.initialize();
      controller = c;
      minZoom = await c.getMinZoomLevel();
      maxZoom = await c.getMaxZoomLevel();
      minEv = await c.getMinExposureOffset();
      maxEv = await c.getMaxExposureOffset();
      evStep = await c.getExposureOffsetStepSize();
      settings = s;
      await _applyLive(s, force: true);
      await _resumeLive();
      _sendCaps();
    } catch (e) {
      lastError = 'Camera init failed: $e';
    }
    notifyListeners();
  }

  Future<void> _applySettings(CameraSettings next) async {
    if (recording) {
      // Changing session parameters mid-recording would cut the clip; only
      // live parameters are applied while rolling.
      await _applyLive(next);
      return;
    }
    if (controller == null || settings.needsReinit(next)) {
      await _initCamera(next);
    } else {
      await _applyLive(next);
    }
    notifyListeners();
  }

  Future<void> _applyLive(CameraSettings s, {bool force = false}) async {
    final c = controller;
    if (c == null) return;
    final old = settings;
    final errors = <String>[];
    Future<void> attempt(String what, Future<void> Function() fn) async {
      try {
        await fn();
      } catch (e) {
        errors.add('$what: $e');
      }
    }

    if (force || s.flash != old.flash) {
      await attempt('flash', () => c.setFlashMode(FlashMode.values.byName(s.flash.name)));
    }
    if (force || s.zoom != old.zoom) {
      await attempt('zoom', () => c.setZoomLevel(s.zoom.clamp(minZoom, maxZoom)));
    }
    if (force || s.exposureOffset != old.exposureOffset) {
      var ev = s.exposureOffset.clamp(minEv, maxEv);
      if (evStep > 0) ev = (ev / evStep).round() * evStep;
      await attempt('exposure', () => c.setExposureOffset(ev));
    }
    if (force || s.exposureLocked != old.exposureLocked) {
      await attempt('ae lock',
          () => c.setExposureMode(s.exposureLocked ? ExposureMode.locked : ExposureMode.auto));
    }
    if (force || s.focusLocked != old.focusLocked) {
      await attempt(
          'af lock', () => c.setFocusMode(s.focusLocked ? FocusMode.locked : FocusMode.auto));
    }
    if (force || s.stabilization != old.stabilization) {
      await attempt(
          'stabilization',
          () => c.setVideoStabilizationMode(
              s.stabilization ? VideoStabilizationMode.level1 : VideoStabilizationMode.off));
    }
    if (force || s.jpegQuality != old.jpegQuality) {
      await attempt('jpeg quality', () => c.setJpegImageQuality(s.jpegQuality));
    }
    if (force || s.orientation != old.orientation) {
      await attempt('orientation', () async {
        switch (s.orientation) {
          case OrientationLock.auto:
            await c.unlockCaptureOrientation();
          case OrientationLock.portrait:
            await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
          case OrientationLock.landscape:
            await c.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
        }
      });
    }
    settings = s;
    // Unsupported features (e.g. stabilization on some phones) are reported
    // but never fatal.
    lastError = errors.isEmpty ? null : errors.join('; ');
  }

  Future<void> _focusAt(double x, double y) async {
    final c = controller;
    if (c == null) return;
    final p = Offset(x.clamp(0, 1), y.clamp(0, 1));
    try {
      if (c.value.focusPointSupported) await c.setFocusPoint(p);
      if (c.value.exposurePointSupported) await c.setExposurePoint(p);
    } catch (e) {
      lastError = 'focus: $e';
    }
  }

  // ------------------------------------------------------------ live view

  // The camera plugin copies *every* stream frame (30 fps, full capture
  // resolution: ~8 MB per 1080p BGRA frame on iPhone, far more at 4K) into
  // Dart while a stream is open. Leaving it open made the phone lag. Instead,
  // live view grabs one frame at a time: open the stream, take the first
  // frame, close it, at the host's requested rate.

  /// Lets live view run again after a capture or camera change.
  Future<void> _resumeLive() async {
    _liveHold = false;
    _pulseTimer ??= Timer.periodic(Duration(milliseconds: 1000 ~/ max(1, _previewFps)), (_) => _pulse());
  }

  /// Stops live view and waits for any frame grab in progress, so the camera
  /// is free for capture, recording or reconfiguration.
  Future<void> _pauseLive() async {
    _liveHold = true;
    await _pulseOp;
    final c = controller;
    if (c != null && c.value.isStreamingImages && !c.value.isRecordingVideo) {
      try {
        await c.stopImageStream();
      } catch (_) {}
    }
  }

  void _restartPulseTimer() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
    if (!_liveHold) _resumeLive();
  }

  void _pulse() {
    final c = controller;
    if (_liveHold || _pulseOp != null || !_previewEnabled || _ws == null || _encoder.busy) return;
    if (c == null || !c.value.isInitialized || c.value.isRecordingVideo || c.value.isStreamingImages) return;
    if (!c.supportsImageStreaming()) return;
    _pulseOp = _grabFrame(c).whenComplete(() => _pulseOp = null);
  }

  Future<void> _grabFrame(CameraController c) async {
    final got = Completer<CameraImage>();
    try {
      await c.startImageStream((img) {
        if (!got.isCompleted) got.complete(img);
      });
      // Short timeout: a capture may be waiting on this grab to finish.
      final img = await got.future.timeout(const Duration(milliseconds: 400));
      await c.stopImageStream();
      _sendFrame(img, c);
    } catch (_) {
      if (c.value.isStreamingImages) {
        try {
          await c.stopImageStream();
        } catch (_) {}
      }
    }
  }

  void _sendFrame(CameraImage image, CameraController c) {
    // Android delivers sensor-native frames; iOS already rotates them and
    // mirrors the front camera, so only Android needs both corrections.
    final front = Platform.isAndroid && c.description.lensDirection == CameraLensDirection.front;
    final rot = Platform.isAndroid ? c.description.sensorOrientation : 0;
    _encoder
        .encode(image, rotation: rot, mirror: front, maxDim: _previewMax, quality: _previewQ)
        .then((jpeg) {
      if (jpeg == null) return;
      final out = Uint8List(jpeg.length + 2)
        ..[0] = PreviewFrame.magic
        ..[1] = PreviewFrame.kindJpeg
        ..setRange(2, jpeg.length + 2, jpeg);
      try {
        _ws?.add(out);
      } catch (_) {}
    });
  }

  // -------------------------------------------------------------- capture

  int _toLocal(int hostUs) => clock?.hostToLocal(hostUs) ?? hostUs;
  int _hostNow() => clock?.hostNowUs() ?? MonoClock.nowUs();

  Future<void> _capturePhotos({
    required String take,
    required int shot,
    required int atHostUs,
    required int count,
    required int intervalMs,
  }) async {
    final c = controller;
    if (c == null || recording) {
      _send(Msg.error, {'take': take, 'msg': recording ? 'busy recording' : 'camera not ready'});
      return;
    }
    final targetLocal = _toLocal(atHostUs);
    countdownTargetLocalUs = targetLocal;
    notifyListeners();

    // Arm: stop live-view encoding so the capture pipeline has the CPU and
    // the camera to itself at the trigger instant.
    await _pauseLive();

    final results = <(XFile, int, int, int)>[];
    for (var k = 0; k < count; k++) {
      final t = targetLocal + k * intervalMs * 1000;
      await waitUntilLocal(t);
      final called = _hostNow();
      try {
        final f = await c.takePicture();
        results.add((f, shot + k, called, _hostNow()));
      } catch (e) {
        _send(Msg.error, {'take': take, 'msg': 'capture failed: $e'});
      }
      if (k == 0) {
        countdownTargetLocalUs = null;
        notifyListeners();
      }
    }
    await _resumeLive();

    for (final (file, shotIdx, called, returned) in results) {
      capturesThisSession++;
      _send(Msg.captured, {
        'take': take,
        'shot': shotIdx,
        'kind': 'photo',
        'scheduledHostUs': atHostUs + (shotIdx - shot) * intervalMs * 1000,
        'calledHostUs': called,
        'returnedHostUs': returned,
        'size': await File(file.path).length(),
      });
      _deliver(file, take, shotIdx, 'photo');
    }
    notifyListeners();
  }

  Future<void> _startVideo(String take, int atHostUs) async {
    final c = controller;
    if (c == null || recording) return;
    countdownTargetLocalUs = _toLocal(atHostUs);
    notifyListeners();
    await _pauseLive();
    try {
      await c.prepareForVideoRecording();
    } catch (_) {}
    await waitUntilLocal(_toLocal(atHostUs));
    _recStartCalledHost = _hostNow();
    try {
      // iOS can keep live view running while recording; on Android an extra
      // analysis stream during recording is not supported on all devices.
      // No live-view stream while rolling: it would copy every frame into
      // Dart and lag the phone. The host shows a REC card instead.
      await c.startVideoRecording();
      _recStartReturnedHost = _hostNow();
      recording = true;
      recordStartLocalUs = MonoClock.nowUs();
      _recordTake = take;
    } catch (e) {
      _send(Msg.error, {'take': take, 'msg': 'record failed: $e'});
      await _resumeLive();
    }
    countdownTargetLocalUs = null;
    notifyListeners();
    _sendStatus();
  }

  Future<void> _stopVideo(int atHostUs) async {
    final c = controller;
    if (c == null || !recording) return;
    await waitUntilLocal(_toLocal(atHostUs));
    final stopCalled = _hostNow();
    try {
      final f = await c.stopVideoRecording();
      final stopReturned = _hostNow();
      recording = false;
      recordStartLocalUs = null;
      capturesThisSession++;
      final take = _recordTake ?? 'unknown';
      _send(Msg.captured, {
        'take': take,
        'shot': 0,
        'kind': 'video',
        'scheduledHostUs': atHostUs,
        'startCalledHostUs': _recStartCalledHost,
        'startReturnedHostUs': _recStartReturnedHost,
        'stopCalledHostUs': stopCalled,
        'stopReturnedHostUs': stopReturned,
        'size': await File(f.path).length(),
      });
      _deliver(f, take, 0, 'video');
    } catch (e) {
      recording = false;
      _send(Msg.error, {'msg': 'stop failed: $e'});
    }
    await _resumeLive();
    notifyListeners();
    _sendStatus();
  }

  /// Saves to the phone's gallery and/or uploads to the host, off the
  /// capture path.
  Future<void> _deliver(XFile file, String take, int shot, String kind) async {
    // Count it as pending right away, so a host ending the session waits
    // for this file even while it is still being saved to the gallery.
    if (autoUpload) {
      pendingUploads++;
      notifyListeners();
    }
    if (keepCopy) {
      try {
        if (await Gal.requestAccess(toAlbum: true)) {
          kind == 'video'
              ? await Gal.putVideo(file.path, album: 'SyncCam')
              : await Gal.putImage(file.path, album: 'SyncCam');
        }
      } catch (e) {
        lastError = 'gallery: $e';
      }
    }
    if (!autoUpload) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _upload(file, take, shot, kind)) break;
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
    pendingUploads--;
    notifyListeners();
  }

  Future<bool> _upload(XFile file, String take, int shot, String kind) async {
    final client = HttpClient();
    try {
      final f = File(file.path);
      final req = await client.post(hostAddress, port, '/upload');
      final ext = file.path.contains('.') ? file.path.split('.').last : (kind == 'video' ? 'mp4' : 'jpg');
      req.headers
        ..set('x-device', identity.id)
        ..set('x-take', take)
        ..set('x-shot', '$shot')
        ..set('x-kind', kind)
        ..set('x-ext', ext);
      req.contentLength = await f.length();
      await req.addStream(f.openRead());
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (e) {
      lastError = 'upload: $e';
      return false;
    } finally {
      client.close();
    }
  }

  /// Leave the session from this phone. The host removes this camera
  /// instead of showing it offline.
  Future<void> leave() async {
    if (recording) await _lock.run(() => _stopVideo(_hostNow()));
    _send(Msg.bye);
    _end(byHost: false);
  }

  void _end({required bool byHost}) {
    if (ended != null) return;
    ended = byHost ? 'host' : 'left';
    _reconnectTimer?.cancel();
    _pulseTimer?.cancel();
    _liveHold = true;
    if (byHost && recording) _lock.run(() => _stopVideo(_hostNow()));
    // Give the bye / final upload a moment before dropping the link.
    Timer(const Duration(milliseconds: 300), () => _ws?.close());
    notifyListeners();
  }

  /// Called by the UI when the app goes to background / returns.
  void onLifecycle(bool resumed) {
    if (resumed) {
      // iOS reclaims sockets of suspended apps; rebind the sync socket and
      // re-measure (the monotonic clock may also have paused during sleep).
      clock?.restart();
      _lock.run(() => _initCamera(settings));
    } else if (!recording) {
      _lock.run(() async {
        await _pauseLive();
        final c = controller;
        controller = null;
        notifyListeners();
        await c?.dispose();
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _reconnectTimer?.cancel();
    _pulseTimer?.cancel();
    _ws?.close();
    clock?.stop();
    _encoder.dispose();
    controller?.dispose();
    super.dispose();
  }
}
