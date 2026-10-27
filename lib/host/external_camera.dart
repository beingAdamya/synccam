import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/clock.dart';

/// Wi-Fi cameras SyncCam can follow. Each speaks an HTTP API on the local
/// network, so the camera and every phone must be on the same Wi-Fi (or the
/// phones on the camera's own access point).
enum ExternalKind { gopro, canon, lumix }

extension ExternalKindInfo on ExternalKind {
  String get label => switch (this) {
        ExternalKind.gopro => 'GoPro (HERO9 and newer)',
        ExternalKind.canon => 'Canon EOS / PowerShot (CCAPI)',
        ExternalKind.lumix => 'Panasonic Lumix',
      };

  /// The address the camera uses on its own Wi-Fi access point.
  String get defaultHost => switch (this) {
        ExternalKind.gopro => '10.5.5.9',
        ExternalKind.canon => '192.168.1.2',
        ExternalKind.lumix => '192.168.54.1',
      };

  int get defaultPort => switch (this) {
        ExternalKind.gopro => 8080,
        ExternalKind.canon => 8080,
        ExternalKind.lumix => 80,
      };

  String get setupHint => switch (this) {
        ExternalKind.gopro => 'Turn on the GoPro\'s Wi-Fi (Connections → Wireless Connections) and join its network '
            'from every phone, or use Camera on Home Network (HERO12+) with its IP, user and password.',
        ExternalKind.canon => 'Needs Canon\'s free CCAPI activation (Canon developer site). Then on the camera: '
            'Network → Wi-Fi function → Remote control (EOS Utility/CCAPI) on the same Wi-Fi as the phones. '
            'Experimental: verified against Canon\'s published endpoint list, not on a camera.',
        ExternalKind.lumix => 'On the camera: Wi-Fi → New connection → Remote shooting & view. Join the camera\'s '
            'network from every phone (or connect the camera to your Wi-Fi via an access point).',
      };
}

class ExternalConfig {
  ExternalConfig({required this.kind, required this.host, required this.port, this.https = false, this.user = '', this.password = ''});
  final ExternalKind kind;
  final String host;
  final int port;
  final bool https;
  final String user;
  final String password;

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'host': host, 'port': port, 'https': https, 'user': user, 'password': password};

  static ExternalConfig? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final kind = ExternalKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) return null;
    return ExternalConfig(
      kind: kind,
      host: j['host'] as String? ?? kind.defaultHost,
      port: (j['port'] as num?)?.toInt() ?? kind.defaultPort,
      https: j['https'] as bool? ?? false,
      user: j['user'] as String? ?? '',
      password: j['password'] as String? ?? '',
    );
  }
}

/// A Wi-Fi camera polled for its recording state. When it starts or stops
/// recording on its own button, [onRecordingChanged] fires with the local
/// time the change was seen, so the host can start every phone.
abstract class ExternalCamera extends ChangeNotifier {
  ExternalCamera(this.config);

  final ExternalConfig config;
  bool connected = false;
  bool recording = false;
  String? error;
  String? model;

  /// Time between polls; detection lag is about half of this plus a round trip.
  Duration get pollEvery => const Duration(milliseconds: 150);
  int lastRoundTripMs = 0;

  void Function(bool recording, int seenAtUs)? onRecordingChanged;

  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  static ExternalCamera create(ExternalConfig c) => switch (c.kind) {
        ExternalKind.gopro => GoProCamera(c),
        ExternalKind.canon => CanonCcapiCamera(c),
        ExternalKind.lumix => LumixCamera(c),
      };

  Future<void> start() async {
    if (config.https) {
      // Cameras use self-signed certificates; trust only this camera's host.
      _http.badCertificateCallback = (cert, host, port) => host == config.host;
    }
    if (config.user.isNotEmpty) {
      _http.addCredentials(_base(), 'camera', HttpClientBasicCredentials(config.user, config.password));
    }
    await _tryConnect();
    _poll = Timer.periodic(pollEvery, (_) => _tick());
  }

  Future<void> _tryConnect() async {
    try {
      await connect();
      connected = true;
      error = null;
    } catch (e) {
      connected = false;
      error = 'Can\'t reach the camera at ${config.host}: ${_short(e)}';
    }
    _notify();
  }

  Future<void> _tick() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      if (!connected) {
        await _tryConnect();
        return;
      }
      final sw = Stopwatch()..start();
      final rec = await pollRecording();
      lastRoundTripMs = sw.elapsedMilliseconds;
      final seen = MonoClock.nowUs() - sw.elapsedMicroseconds ~/ 2;
      if (rec != null && rec != recording) {
        recording = rec;
        onRecordingChanged?.call(rec, seen);
        _notify();
      }
      if (error != null) {
        error = null;
        _notify();
      }
    } catch (e) {
      connected = false;
      error = 'Lost the camera: ${_short(e)}';
      _notify();
    } finally {
      _polling = false;
    }
  }

  /// Open a control session (if the camera needs one) and read its model.
  Future<void> connect();

  /// Current recording state, or null if this poll had no answer about it.
  Future<bool?> pollRecording();

  Future<void> startRecording();
  Future<void> stopRecording();

  Uri _base([String path = '/', Map<String, String>? query]) =>
      Uri(scheme: config.https ? 'https' : 'http', host: config.host, port: config.port, path: path, queryParameters: query);

  Future<String> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<String> post(String path, Object body) => _send('POST', path, body: jsonEncode(body));
  Future<String> put(String path, Object body) => _send('PUT', path, body: jsonEncode(body));

  Future<String> _send(String method, String path, {Map<String, String>? query, String? body}) async {
    final req = await _http.openUrl(method, _base(path, query)).timeout(const Duration(seconds: 3));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode} $text');
    return text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _http.close(force: true);
    super.dispose();
  }
}

/// Open GoPro HTTP API (HERO9+). Endpoints from GoPro's Open GoPro SDK:
/// shutter `/gopro/camera/shutter/{start,stop}`, state `/gopro/camera/state`
/// where status 10 is "encoding" (recording) and 8 is "busy".
class GoProCamera extends ExternalCamera {
  GoProCamera(super.config);

  Timer? _keepAlive;

  @override
  Future<void> connect() async {
    final state = jsonDecode(await get('/gopro/camera/state')) as Map<String, dynamic>;
    recording = _encoding(state) ?? false;
    model = 'GoPro';
    // GoPros sleep when idle unless kept alive.
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 3), (_) => get('/gopro/camera/keep_alive').catchError((_) => ''));
  }

  static bool? _encoding(Map<String, dynamic> state) {
    final v = (state['status'] as Map?)?['10'];
    return v == null ? null : v == 1 || v == true;
  }

  @override
  Future<bool?> pollRecording() async =>
      _encoding(jsonDecode(await get('/gopro/camera/state')) as Map<String, dynamic>);

  @override
  Future<void> startRecording() async {
    await get('/gopro/camera/presets/set_group', query: {'id': '1000'}); // video preset group
    await get('/gopro/camera/shutter/start');
  }

  @override
  Future<void> stopRecording() => get('/gopro/camera/shutter/stop');

  @override
  void dispose() {
    _keepAlive?.cancel();
    super.dispose();
  }
}

/// Canon Camera Control API. Recording via
/// `POST /ccapi/ver100/shooting/control/recbutton {"action":"start"|"stop"}`;
/// state via `GET /ccapi/ver100/event/polling` (changes since the last call).
/// Marked experimental: built from Canon's published function list, not
/// tested on a camera.
class CanonCcapiCamera extends ExternalCamera {
  CanonCcapiCamera(super.config);

  @override
  Duration get pollEvery => const Duration(milliseconds: 200);

  @override
  Future<void> connect() async {
    try {
      final info = jsonDecode(await get('/ccapi/ver100/deviceinformation')) as Map<String, dynamic>;
      model = info['productname'] as String? ?? 'Canon';
    } on HttpException {
      // Older firmware: the API root still proves CCAPI is reachable.
      await get('/ccapi');
      model = 'Canon';
    }
    // First poll returns the full state.
    final first = await pollRecording();
    recording = first ?? false;
  }

  @override
  Future<bool?> pollRecording() async {
    final body = await get('/ccapi/ver100/event/polling');
    if (body.trim().isEmpty) return null;
    return parseRecording(jsonDecode(body));
  }

  /// Looks for the recording state in an event-polling result. Canon reports
  /// it under "recbutton" ({"status":"start"|"stop"}); other spellings are
  /// accepted defensively.
  static bool? parseRecording(Object? events) {
    if (events is! Map) return null;
    for (final key in const ['recbutton', 'recordingstatus', 'movierecording']) {
      final v = events[key];
      final status = v is Map ? (v['status'] ?? v['value']) : v;
      if (status == null) continue;
      final s = status.toString().toLowerCase();
      if (s == 'start' || s == 'on' || s == 'recording' || s == 'true') return true;
      if (s == 'stop' || s == 'off' || s == 'idle' || s == 'false') return false;
    }
    return null;
  }

  @override
  Future<void> startRecording() async {
    await post('/ccapi/ver100/shooting/control/moviemode', {'action': 'on'}).catchError((_) => '');
    await post('/ccapi/ver100/shooting/control/recbutton', {'action': 'start'});
  }

  @override
  Future<void> stopRecording() => post('/ccapi/ver100/shooting/control/recbutton', {'action': 'stop'});
}

/// Panasonic Lumix `cam.cgi` (as used by community tools such as
/// python_lumix_control): `mode=camcmd` with `recmode`, `video_recstart` or
/// `video_recstop`; state via `mode=getstate`, whose XML has a `rec` element
/// that reads on or off.
class LumixCamera extends ExternalCamera {
  LumixCamera(super.config);

  @override
  Duration get pollEvery => const Duration(milliseconds: 200);

  Future<String> _cmd(String value) => get('/cam.cgi', query: {'mode': 'camcmd', 'value': value});

  @override
  Future<void> connect() async {
    // Newer bodies want an access request before accepting commands.
    await get('/cam.cgi', query: {'mode': 'accctrl', 'type': 'req_acc', 'value': '4D454930-0100-1000-8001-0000000053CC', 'value2': 'SyncCam'})
        .catchError((_) => '');
    final r = await _cmd('recmode');
    if (!r.contains('<result>ok</result>')) throw HttpException('camera refused: $r');
    model = 'Lumix';
    recording = parseRecording(await get('/cam.cgi', query: {'mode': 'getstate'})) ?? false;
  }

  static bool? parseRecording(String xml) {
    final m = RegExp(r'<rec>\s*(\w+)\s*</rec>').firstMatch(xml);
    return m == null ? null : m.group(1) == 'on';
  }

  @override
  Future<bool?> pollRecording() async => parseRecording(await get('/cam.cgi', query: {'mode': 'getstate'}));

  @override
  Future<void> startRecording() => _cmd('video_recstart');

  @override
  Future<void> stopRecording() => _cmd('video_recstop');
}
