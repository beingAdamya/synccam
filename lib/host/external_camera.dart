import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/clock.dart';
import 'ptp_cameras.dart';

/// Every way SyncCam can work with a dedicated camera. Most brands speak
/// one of three families: a brand HTTP API, the OSC standard (360° cameras),
/// or PTP/IP (the ISO tethering protocol). [sound] needs no connection at
/// all: any camera with a microphone records the host's slate beep and is
/// aligned afterwards.
///
/// Enum names are stored in settings; keep existing ones stable.
enum ExternalKind { gopro, canon, lumix, blackmagic, osc, sonyApi, olympus, nikon, sonyPtp, canonPtp, fujifilm, ptp, sound }

extension ExternalKindInfo on ExternalKind {
  String get brand => switch (this) {
        ExternalKind.gopro => 'GoPro',
        ExternalKind.canon || ExternalKind.canonPtp => 'Canon',
        ExternalKind.lumix => 'Panasonic',
        ExternalKind.blackmagic => 'Blackmagic',
        ExternalKind.osc => '360° cameras',
        ExternalKind.sonyApi || ExternalKind.sonyPtp => 'Sony',
        ExternalKind.olympus => 'OM System / Olympus',
        ExternalKind.nikon => 'Nikon',
        ExternalKind.fujifilm => 'Fujifilm',
        ExternalKind.ptp => 'Other brands',
        ExternalKind.sound => 'Any camera',
      };

  String get label => switch (this) {
        ExternalKind.gopro => 'GoPro HERO9 and newer',
        ExternalKind.canon => 'Canon EOS / PowerShot (CCAPI)',
        ExternalKind.canonPtp => 'Canon EOS (EOS Utility / PTP)',
        ExternalKind.lumix => 'Panasonic Lumix',
        ExternalKind.blackmagic => 'Blackmagic (Cinema, Studio, URSA, PYXIS)',
        ExternalKind.osc => 'Ricoh Theta, Insta360 and other OSC cameras',
        ExternalKind.sonyApi => 'Sony Alpha / RX, older (Camera Remote API)',
        ExternalKind.sonyPtp => 'Sony Alpha / FX, current (PC Remote)',
        ExternalKind.olympus => 'OM System / Olympus OM-D, PEN, TG',
        ExternalKind.nikon => 'Nikon Z and DSLR (Wi-Fi PTP)',
        ExternalKind.fujifilm => 'Fujifilm X and GFX',
        ExternalKind.ptp => 'Any PTP/IP camera (Pentax, Leica, Sigma…)',
        ExternalKind.sound => 'Any camera: sync by sound, no connection',
      };

  /// The address each camera uses on its own Wi-Fi access point.
  String get defaultHost => switch (this) {
        ExternalKind.gopro => '10.5.5.9',
        ExternalKind.canon || ExternalKind.canonPtp => '192.168.1.2',
        ExternalKind.lumix => '192.168.54.1',
        ExternalKind.blackmagic => '',
        ExternalKind.osc => '192.168.1.1',
        ExternalKind.sonyApi => '192.168.122.1',
        ExternalKind.sonyPtp => '192.168.122.1',
        ExternalKind.olympus => '192.168.0.10',
        ExternalKind.nikon => '192.168.1.1',
        ExternalKind.fujifilm => '192.168.0.1',
        ExternalKind.ptp => '',
        ExternalKind.sound => '',
      };

  int get defaultPort => switch (this) {
        ExternalKind.gopro || ExternalKind.canon || ExternalKind.sonyApi => 8080,
        ExternalKind.nikon || ExternalKind.sonyPtp || ExternalKind.canonPtp || ExternalKind.ptp => 15740,
        ExternalKind.fujifilm => 15740,
        _ => 80,
      };

  bool get usesPtp => const {
        ExternalKind.nikon,
        ExternalKind.sonyPtp,
        ExternalKind.canonPtp,
        ExternalKind.fujifilm,
        ExternalKind.ptp,
      }.contains(this);

  /// Pressing record on the camera itself can start the phones.
  bool get canLead => !const {ExternalKind.olympus, ExternalKind.fujifilm, ExternalKind.ptp, ExternalKind.sound}.contains(this);

  /// SyncCam can start/stop the camera's recording.
  bool get canControl => this != ExternalKind.sound;

  bool get needsConnection => this != ExternalKind.sound;

  /// How sure we are that it works, so users know what to expect.
  String get maturity => switch (this) {
        ExternalKind.gopro || ExternalKind.blackmagic => 'Built from the maker\'s official API',
        ExternalKind.sound => 'Works with every camera',
        _ => 'Experimental: built from public docs and libgphoto2, not yet tested on this camera. '
            'If it fails, the connection log shows why.',
      };

  String get setupHint => switch (this) {
        ExternalKind.gopro => 'Turn on the GoPro\'s Wi-Fi and join its network from every phone, or use Camera on '
            'Home Network (HERO12+) with its IP, user and password.',
        ExternalKind.canon => 'Needs Canon\'s free CCAPI activation (Canon developer site). Then on the camera: '
            'Network → Wi-Fi → Remote control (EOS Utility/CCAPI), on the same Wi-Fi as the phones.',
        ExternalKind.canonPtp => 'For EOS bodies without CCAPI. On the camera: Wi-Fi → Remote control (EOS Utility), '
            'join the same Wi-Fi as the phones, then pair when the camera asks.',
        ExternalKind.lumix => 'On the camera: Wi-Fi → New connection → Remote shooting & view. Join the camera\'s '
            'network from every phone, or connect the camera to your Wi-Fi.',
        ExternalKind.blackmagic => 'Connect the camera to your network and enable Web Media Manager in Blackmagic '
            'Camera Setup. Enter its IP (or name, e.g. Cinema-Camera-6K.local).',
        ExternalKind.osc => 'Join the camera\'s Wi-Fi (Ricoh Theta: 192.168.1.1). In client mode enter the '
            'camera\'s IP plus the user/password printed on it.',
        ExternalKind.sonyApi => 'Older Sony models with "Smart Remote" / Imaging Edge Mobile. On the camera start '
            'Ctrl with Smartphone, then join its Wi-Fi from every phone.',
        ExternalKind.sonyPtp => 'Current Alpha/FX bodies: Network → PC Remote → On, connect over Wi-Fi '
            '(access point mode). If the camera asks for pairing, accept SyncCam.',
        ExternalKind.olympus => 'On the camera: Wi-Fi / Connection to Smartphone, then join its network. SyncCam can '
            'start and stop it; its own button can\'t start the phones.',
        ExternalKind.nikon => 'On the camera: Network → Connect to computer (Wi-Fi), same network as the phones. '
            'The first connection may need pairing confirmation on the camera.',
        ExternalKind.fujifilm => 'On the camera: wireless tethered shooting / PC connection over Wi-Fi. SyncCam can '
            'start and stop it; its own button can\'t start the phones.',
        ExternalKind.ptp => 'For other cameras that support PTP/IP ("connect to computer over Wi-Fi"). Start and '
            'stop from SyncCam only.',
        ExternalKind.sound => 'No connection. Start the camera yourself before or after the phones. The host\'s '
            'slate beep is recorded by the camera\'s microphone, and tools/align_clips.py --extra lines its clip up '
            'with the phones to the frame.',
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

/// A camera polled for its recording state (or told it by events). When it
/// starts or stops recording on its own button, [onRecordingChanged] fires
/// with the local time the change was seen, so the host can start every
/// phone. Every request and answer goes to [log] for troubleshooting.
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

  /// Recent protocol traffic, newest last, for the connection log screen.
  final List<String> log = [];

  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  /// Extra HTTP headers some cameras insist on.
  Map<String, String> get headers => const {};

  static ExternalCamera create(ExternalConfig c) => switch (c.kind) {
        ExternalKind.gopro => GoProCamera(c),
        ExternalKind.canon => CanonCcapiCamera(c),
        ExternalKind.lumix => LumixCamera(c),
        ExternalKind.blackmagic => BlackmagicCamera(c),
        ExternalKind.osc => OscCamera(c),
        ExternalKind.sonyApi => SonyRemoteApiCamera(c),
        ExternalKind.olympus => OlympusCamera(c),
        ExternalKind.nikon => NikonPtpCamera(c),
        ExternalKind.sonyPtp => SonyPtpCamera(c),
        ExternalKind.canonPtp => CanonPtpCamera(c),
        ExternalKind.fujifilm => FujifilmPtpCamera(c),
        ExternalKind.ptp => GenericPtpCamera(c),
        ExternalKind.sound => SoundOnlyCamera(c),
      };

  @protected
  void trace(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    log.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')} $line');
    if (log.length > 300) log.removeRange(0, log.length - 300);
  }

  Future<void> start() async {
    trace('Connecting to ${config.kind.label} at ${config.host}:${config.port}');
    if (config.https) {
      // Cameras use self-signed certificates; trust only this camera's host.
      _http.badCertificateCallback = (cert, host, port) => host == config.host;
    }
    if (config.user.isNotEmpty) {
      _http.addCredentials(
        _base(),
        'camera',
        config.kind == ExternalKind.osc
            ? HttpClientDigestCredentials(config.user, config.password)
            : HttpClientBasicCredentials(config.user, config.password),
      );
    }
    await _tryConnect();
    if (config.kind.needsConnection) _poll = Timer.periodic(pollEvery, (_) => _tick());
  }

  Future<void> _tryConnect() async {
    try {
      await connect();
      connected = true;
      error = null;
      trace('Connected${model == null ? '' : ': $model'}');
    } catch (e) {
      connected = false;
      error = 'Can\'t reach the camera at ${config.host}: ${short(e)}';
      trace('Connect failed: $e');
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
      if (rec != null) reportRecording(rec, seenUs: MonoClock.nowUs() - sw.elapsedMicroseconds ~/ 2);
      if (error != null) {
        error = null;
        _notify();
      }
    } catch (e) {
      connected = false;
      error = 'Lost the camera: ${short(e)}';
      trace('Poll failed: $e');
      await onLost();
      _notify();
    } finally {
      _polling = false;
    }
  }

  /// Drivers that learn the state from events (PTP) call this directly.
  @protected
  void reportRecording(bool rec, {int? seenUs}) {
    if (rec == recording) return;
    recording = rec;
    trace('Camera ${rec ? 'STARTED' : 'STOPPED'} recording');
    onRecordingChanged?.call(rec, seenUs ?? MonoClock.nowUs());
    _notify();
  }

  /// Open a control session (if the camera needs one) and read its model.
  Future<void> connect();

  /// Current recording state, or null if this poll had no answer about it.
  Future<bool?> pollRecording();

  Future<void> startRecording();
  Future<void> stopRecording();

  /// Called when a poll fails, to drop sockets before reconnecting.
  @protected
  Future<void> onLost() async {}

  Uri _base([String path = '/', Map<String, String>? query]) =>
      Uri(scheme: config.https ? 'https' : 'http', host: config.host, port: config.port, path: path, queryParameters: query);

  Future<String> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<String> post(String path, Object body) => _send('POST', path, body: jsonEncode(body));
  Future<String> put(String path, Object body) => _send('PUT', path, body: jsonEncode(body));

  Future<String> _send(String method, String path, {Map<String, String>? query, String? body}) async {
    final uri = _base(path, query);
    final quiet = !_verbose(path);
    if (!quiet) trace('→ $method ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}${body == null ? '' : ' $body'}');
    try {
      final req = await _http.openUrl(method, uri).timeout(const Duration(seconds: 3));
      headers.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 3));
      final text = await res.transform(utf8.decoder).join();
      if (!quiet || res.statusCode >= 400) trace('← ${res.statusCode} ${_clip(text)}');
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode} ${_clip(text)}');
      return text;
    } catch (e) {
      if (quiet) trace('✗ $method ${uri.path}: $e');
      rethrow;
    }
  }

  // Poll requests run several times a second; log them only when they fail.
  bool _pollingPath = false;
  bool _verbose(String path) => !_pollingPath;

  /// Runs [fn] without logging each successful request (for polls).
  @protected
  Future<T> quietly<T>(Future<T> Function() fn) async {
    _pollingPath = true;
    try {
      return await fn();
    } finally {
      _pollingPath = false;
    }
  }

  static String _clip(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 200 ? '${one.substring(0, 200)}…' : one;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String short(Object e) {
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

/// No connection: the camera is started by hand and aligned by its audio.
class SoundOnlyCamera extends ExternalCamera {
  SoundOnlyCamera(super.config);

  @override
  Future<void> connect() async => model = 'Any camera (sync by sound)';
  @override
  Future<bool?> pollRecording() async => null;
  @override
  Future<void> startRecording() async {}
  @override
  Future<void> stopRecording() async {}
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
  Future<bool?> pollRecording() =>
      quietly(() async => _encoding(jsonDecode(await get('/gopro/camera/state')) as Map<String, dynamic>));

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
    final body = await quietly(() => get('/ccapi/ver100/event/polling'));
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
  Future<bool?> pollRecording() async =>
      parseRecording(await quietly(() => get('/cam.cgi', query: {'mode': 'getstate'})));

  @override
  Future<void> startRecording() => _cmd('video_recstart');

  @override
  Future<void> stopRecording() => _cmd('video_recstop');
}

/// Blackmagic camera REST API (official, Blackmagic "REST API for Blackmagic
/// Cameras"): `GET`/`PUT /control/api/v1/transports/0/record` with
/// `{"recording": true|false}`. Needs Web Media Manager enabled.
class BlackmagicCamera extends ExternalCamera {
  BlackmagicCamera(super.config);

  static const _record = '/control/api/v1/transports/0/record';

  @override
  Future<void> connect() async {
    recording = parseRecording(await get(_record)) ?? false;
    try {
      final p = jsonDecode(await get('/control/api/v1/system/product')) as Map<String, dynamic>;
      model = p['deviceName'] as String? ?? p['productName'] as String? ?? 'Blackmagic camera';
    } catch (_) {
      model = 'Blackmagic camera';
    }
  }

  static bool? parseRecording(String body) {
    final j = jsonDecode(body);
    return j is Map && j['recording'] is bool ? j['recording'] as bool : null;
  }

  @override
  Future<bool?> pollRecording() async => parseRecording(await quietly(() => get(_record)));

  @override
  Future<void> startRecording() => put(_record, {'recording': true});

  @override
  Future<void> stopRecording() => put(_record, {'recording': false});
}

/// Open Spherical Camera API (Google's open standard; Ricoh Theta, Insta360
/// and others): `POST /osc/commands/execute` with `camera.startCapture` /
/// `camera.stopCapture` after switching `captureMode` to video; state from
/// `POST /osc/state`, where `_captureStatus` is "shooting" while recording.
class OscCamera extends ExternalCamera {
  OscCamera(super.config);

  @override
  Duration get pollEvery => const Duration(milliseconds: 200);

  Future<Map<String, dynamic>> _exec(String name, [Map<String, dynamic>? parameters]) async {
    final r = await post('/osc/commands/execute', {'name': name, 'parameters': ?parameters});
    final j = jsonDecode(r) as Map<String, dynamic>;
    if (j['state'] == 'error') throw HttpException('$name: ${j['error']}');
    return j;
  }

  @override
  Future<void> connect() async {
    final info = jsonDecode(await get('/osc/info')) as Map<String, dynamic>;
    model = [info['manufacturer'], info['model']].whereType<String>().join(' ');
    recording = parseRecording(await post('/osc/state', {})) ?? false;
  }

  static bool? parseRecording(String body) {
    final state = (jsonDecode(body) as Map)['state'];
    if (state is! Map) return null;
    final s = (state['_captureStatus'] ?? state['captureStatus'])?.toString().toLowerCase();
    if (s == null) return null;
    return s == 'shooting' || s == 'recording';
  }

  @override
  Future<bool?> pollRecording() async => parseRecording(await quietly(() => post('/osc/state', {})));

  @override
  Future<void> startRecording() async {
    await _exec('camera.setOptions', {
      'options': {'captureMode': 'video'},
    }).catchError((Object _) => <String, dynamic>{});
    await _exec('camera.startCapture');
  }

  @override
  Future<void> stopRecording() => _exec('camera.stopCapture');
}

/// Sony Camera Remote API (JSON-RPC, older Alpha/RX models with "Smart
/// Remote"): `POST /sony/camera` with `startMovieRec` / `stopMovieRec`;
/// state from `getEvent`, whose cameraStatus is "MovieRecording".
class SonyRemoteApiCamera extends ExternalCamera {
  SonyRemoteApiCamera(super.config);

  @override
  Duration get pollEvery => const Duration(milliseconds: 200);

  int _id = 0;

  Future<List<dynamic>> _call(String method, [List<dynamic> params = const []]) async {
    final r = await post('/sony/camera', {'method': method, 'params': params, 'id': ++_id, 'version': '1.0'});
    final j = jsonDecode(r) as Map<String, dynamic>;
    if (j['error'] != null) throw HttpException('$method: ${j['error']}');
    return (j['result'] as List?) ?? const [];
  }

  @override
  Future<void> connect() async {
    // Some models need remote shooting mode turned on first.
    await _call('startRecMode').catchError((Object _) => <dynamic>[]);
    model = 'Sony camera';
    recording = parseRecording(await _call('getEvent', [false])) ?? false;
  }

  static bool? parseRecording(List<dynamic> result) {
    for (final e in result) {
      final items = e is List ? e : [e];
      for (final i in items) {
        if (i is Map && i['type'] == 'cameraStatus') {
          final s = i['cameraStatus'] as String?;
          if (s == null) continue;
          return s == 'MovieRecording' || s == 'AudioRecording';
        }
      }
    }
    return null;
  }

  @override
  Future<bool?> pollRecording() async => parseRecording(await quietly(() => _call('getEvent', [false])));

  @override
  Future<void> startRecording() async {
    await _call('setShootMode', ['movie']).catchError((Object _) => <dynamic>[]);
    await _call('startMovieRec');
  }

  @override
  Future<void> stopRecording() => _call('stopMovieRec');
}

/// OM System / Olympus Wi-Fi CGI API (as documented by community tools):
/// `switch_cammode.cgi?mode=rec`, then `exec_takemotion.cgi?com=starttake`
/// / `stoptake` in movie mode. The camera exposes no recording state, so it
/// can't lead; SyncCam starts and stops it.
class OlympusCamera extends ExternalCamera {
  OlympusCamera(super.config);

  // The cameras reject requests that don't look like the official app.
  @override
  Map<String, String> get headers => const {'User-Agent': 'OI.Share v2'};

  @override
  Future<void> connect() async {
    final info = await get('/get_caminfo.cgi');
    model = RegExp(r'<model>\s*([^<]+)</model>').firstMatch(info)?.group(1) ?? 'OM System camera';
    await get('/switch_cammode.cgi', query: {'mode': 'rec'});
  }

  @override
  Future<bool?> pollRecording() async => null;

  @override
  Future<void> startRecording() => get('/exec_takemotion.cgi', query: {'com': 'starttake'});

  @override
  Future<void> stopRecording() => get('/exec_takemotion.cgi', query: {'com': 'stoptake'});
}
