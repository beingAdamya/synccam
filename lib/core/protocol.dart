import 'dart:convert';

/// Network constants shared by host and camera nodes.
class Net {
  static const int httpPort = 47810; // WebSocket control channel + HTTP uploads
  static const int udpPort = 47811; // Clock-sync pings
  static const int httpsPort = 47812; // Browser cameras (needs the local CA)
  static const String serviceType = '_synccam._tcp';
  static const int protocolVersion = 1;
}

/// Message types sent over the WebSocket control channel (JSON text frames).
///
/// Binary frames carry live-view JPEGs from node -> host (see [PreviewFrame]).
class Msg {
  // node -> host
  static const hello = 'hello';
  static const status = 'status';
  static const captured = 'captured';
  static const error = 'error';
  static const caps = 'caps';
  static const bye = 'bye'; // camera is leaving on purpose

  // host -> node
  static const welcome = 'welcome';
  static const settings = 'settings';
  static const capturePhoto = 'capturePhoto';
  static const startVideo = 'startVideo';
  static const stopVideo = 'stopVideo';
  static const focusAt = 'focusAt';
  static const identify = 'identify';
  static const preview = 'preview';
  static const rename = 'rename';
  static const policy = 'policy';
  static const countdown = 'countdown';
  static const endSession = 'endSession';

  // browser cameras: clock sync over the WebSocket (no UDP in browsers)
  static const ping = 'ping';
  static const pong = 'pong';
}

String encodeMsg(String type, [Map<String, dynamic>? body]) =>
    jsonEncode({'t': type, ...?body});

enum CaptureMode { photo, video, burst, interval }

enum LensChoice { back, front, external }

enum FlashChoice { off, auto, always, torch }

enum ResChoice { low, medium, high, veryHigh, ultraHigh, max }

enum OrientationLock { auto, portrait, landscape }

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// Every camera parameter the host can drive. The host keeps one global
/// [CameraSettings] plus optional per-device overrides (a partial map that is
/// merged on top of the global one).
class CameraSettings {
  CameraSettings({
    this.lens = LensChoice.back,
    this.resolution = ResChoice.veryHigh,
    this.fps,
    this.enableAudio = true,
    this.flash = FlashChoice.off,
    this.zoom = 1.0,
    this.exposureOffset = 0.0,
    this.exposureLocked = false,
    this.focusLocked = false,
    this.stabilization = false,
    this.jpegQuality = 95,
    this.orientation = OrientationLock.auto,
    this.showGrid = false,
  });

  LensChoice lens;
  ResChoice resolution;
  int? fps;
  bool enableAudio;
  FlashChoice flash;
  double zoom;
  double exposureOffset;
  bool exposureLocked;
  bool focusLocked;
  bool stabilization;
  int jpegQuality;
  OrientationLock orientation;
  bool showGrid;

  Map<String, dynamic> toJson() => {
        'lens': lens.name,
        'resolution': resolution.name,
        'fps': fps,
        'enableAudio': enableAudio,
        'flash': flash.name,
        'zoom': zoom,
        'exposureOffset': exposureOffset,
        'exposureLocked': exposureLocked,
        'focusLocked': focusLocked,
        'stabilization': stabilization,
        'jpegQuality': jpegQuality,
        'orientation': orientation.name,
        'showGrid': showGrid,
      };

  static CameraSettings fromJson(Map<String, dynamic> j) => CameraSettings(
        lens: _enumByName(LensChoice.values, j['lens'], LensChoice.back),
        resolution: _enumByName(ResChoice.values, j['resolution'], ResChoice.veryHigh),
        fps: (j['fps'] as num?)?.toInt(),
        enableAudio: j['enableAudio'] as bool? ?? true,
        flash: _enumByName(FlashChoice.values, j['flash'], FlashChoice.off),
        zoom: (j['zoom'] as num?)?.toDouble() ?? 1.0,
        exposureOffset: (j['exposureOffset'] as num?)?.toDouble() ?? 0.0,
        exposureLocked: j['exposureLocked'] as bool? ?? false,
        focusLocked: j['focusLocked'] as bool? ?? false,
        stabilization: j['stabilization'] as bool? ?? false,
        jpegQuality: (j['jpegQuality'] as num?)?.toInt() ?? 95,
        orientation: _enumByName(OrientationLock.values, j['orientation'], OrientationLock.auto),
        showGrid: j['showGrid'] as bool? ?? false,
      );

  /// Global settings with a per-device partial override merged on top.
  CameraSettings merged(Map<String, dynamic> override) =>
      CameraSettings.fromJson({...toJson(), ...override});

  CameraSettings copy() => CameraSettings.fromJson(toJson());

  /// Fields whose change requires re-creating the native camera session.
  bool needsReinit(CameraSettings other) =>
      lens != other.lens ||
      resolution != other.resolution ||
      fps != other.fps ||
      enableAudio != other.enableAudio;
}

/// Header prepended to binary live-view frames:
/// byte 0 = magic 0x53 ('S'), byte 1 = frame kind (1 = jpeg), then JPEG bytes.
class PreviewFrame {
  static const int magic = 0x53;
  static const int kindJpeg = 1;
}
