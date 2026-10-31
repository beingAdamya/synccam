import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'external_camera.dart';
import 'ptpip.dart';

/// Shared PTP/IP camera driver. Brand subclasses add the vendor operations
/// for movie recording and for reading the recording state. Operation and
/// property codes come from libgphoto2 (camlibs/ptp2/ptp.h and config.c).
abstract class PtpCamera extends ExternalCamera {
  PtpCamera(super.config);

  PtpIpSession? session;
  PtpDeviceInfo? info;
  StreamSubscription<PtpEvent>? _events;

  @override
  Duration get pollEvery => const Duration(milliseconds: 250);

  bool supports(int op) => info?.operations.contains(op) ?? false;

  /// Stable per-install identity; Nikon and others pair by this GUID.
  static Future<Uint8List> _guid() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('ptp.guid');
    if (saved != null && saved.length == 32) {
      return Uint8List.fromList(List.generate(16, (i) => int.parse(saved.substring(i * 2, i * 2 + 2), radix: 16)));
    }
    final r = Random.secure();
    final g = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    await prefs.setString('ptp.guid', g.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    return g;
  }

  /// Overridable for tests.
  static Future<Uint8List> Function() guidProvider = _guid;

  @override
  Future<void> connect() async {
    await onLost();
    final s = PtpIpSession(host: config.host, port: config.port, guid: await guidProvider(), trace: trace);
    await s.connect();
    session = s;
    final di = await op(Ptp.getDeviceInfo, check: true);
    info = PtpDeviceInfo.parse(di.data);
    model = '${info!.manufacturer} ${info!.model}'.trim();
    trace('Device: $model ${info!.version}, ${info!.operations.length} operations');
    final open = await op(Ptp.openSession, params: [1]);
    if (!open.ok && open.code != Ptp.sessionAlreadyOpen) throw PtpException('OpenSession failed (${open.codeHex})');
    await afterOpen();
    _events = s.events.listen(onEvent);
  }

  /// Brand-specific setup after the session opens.
  Future<void> afterOpen() async {}

  /// Asynchronous camera events (event channel).
  void onEvent(PtpEvent e) {}

  /// Runs an operation with logging. [check] throws on a non-OK response.
  Future<PtpResponse> op(int code, {List<int> params = const [], Uint8List? dataOut, bool check = false, bool quiet = false}) async {
    final s = session;
    if (s == null) throw PtpException('not connected');
    final name = '0x${code.toRadixString(16)}';
    if (!quiet) trace('→ op $name $params${dataOut == null ? '' : ' +${dataOut.length}B'}');
    final r = await s.transaction(code, params: params, dataOut: dataOut);
    if (!quiet || !r.ok) trace('← ${r.codeHex}${r.data.isEmpty ? '' : ' ${r.data.length}B'}');
    if (check && !r.ok) throw PtpException('operation $name failed (${r.codeHex})');
    return r;
  }

  /// Retries while the camera reports busy (switching modes, writing card).
  Future<PtpResponse> opWhenReady(int code, {List<int> params = const [], Uint8List? dataOut}) async {
    for (var i = 0; i < 20; i++) {
      final r = await op(code, params: params, dataOut: dataOut);
      if (r.code != Ptp.deviceBusy) {
        if (!r.ok) throw PtpException('operation 0x${code.toRadixString(16)} failed (${r.codeHex})');
        return r;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw PtpException('camera stayed busy');
  }

  static Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  static Uint8List u32s(List<int> vs) {
    final b = ByteData(4 * vs.length);
    for (var i = 0; i < vs.length; i++) {
      b.setUint32(i * 4, vs[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  @override
  Future<void> onLost() async {
    await _events?.cancel();
    _events = null;
    await session?.close();
    session = null;
  }

  @override
  void dispose() {
    onLost();
    super.dispose();
  }
}

/// Nikon: StartMovieRecInCard 0x920A / EndMovieRec 0x920B; state from
/// GetEvent 0x90C7 (and the event channel): MovieRecordStarted 0xC10A,
/// MovieRecordComplete 0xC108, MovieRecordInterrupted 0xC105.
class NikonPtpCamera extends PtpCamera {
  NikonPtpCamera(super.config);

  static const startMovie = 0x920A, endMovie = 0x920B, getEvent = 0x90C7, deviceReady = 0x90C8, startLiveView = 0x9201;
  static const evStarted = 0xC10A, evComplete = 0xC108, evInterrupted = 0xC105;

  static bool? stateFromCodes(Iterable<int> codes) {
    bool? state;
    for (final c in codes) {
      if (c == evStarted) state = true;
      if (c == evComplete || c == evInterrupted) state = false;
    }
    return state;
  }

  /// GetEvent data: u16 count, then (u16 code, u32 param) per event.
  static List<int> parseEventCodes(Uint8List data) {
    if (data.length < 2) return const [];
    final r = PtpReader(data);
    final n = r.u16();
    final codes = <int>[];
    for (var i = 0; i < n && r.pos + 6 <= data.length; i++) {
      codes.add(r.u16());
      r.u32();
    }
    return codes;
  }

  @override
  void onEvent(PtpEvent e) {
    final s = stateFromCodes([e.code]);
    if (s != null) reportRecording(s);
  }

  @override
  Future<bool?> pollRecording() async {
    if (!supports(getEvent)) return null;
    final r = await op(getEvent, quiet: true);
    final codes = parseEventCodes(r.data);
    if (codes.isNotEmpty) trace('← Nikon events ${codes.map((c) => '0x${c.toRadixString(16)}').join(' ')}');
    return stateFromCodes(codes);
  }

  Future<void> _waitReady() async {
    if (!supports(deviceReady)) return;
    for (var i = 0; i < 30; i++) {
      final r = await op(deviceReady, quiet: true);
      if (r.code != Ptp.deviceBusy) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Future<void> startRecording() async {
    // Movie recording needs live view running on most bodies (as in libgphoto2).
    if (supports(startLiveView)) {
      await op(startLiveView);
      await _waitReady();
    }
    await opWhenReady(startMovie);
  }

  @override
  Future<void> stopRecording() => opWhenReady(endMovie);
}

/// Canon EOS over PTP/IP (EOS Utility mode): SetRemoteMode 0x9114 and
/// SetEventMode 0x9115 after opening; recording by setting EVFRecordStatus
/// 0xD1B8 to 4 (record to card) or 0 via SetDevicePropValueEx 0x9110; state
/// from GetEvent 0x9116 PropValueChanged (0xC189) records for 0xD1B8.
class CanonPtpCamera extends PtpCamera {
  CanonPtpCamera(super.config);

  static const setPropEx = 0x9110, setRemoteMode = 0x9114, setEventMode = 0x9115, getEvent = 0x9116;
  static const recordStatus = 0xD1B8, propChanged = 0xC189;

  @override
  Future<void> afterOpen() async {
    await op(setRemoteMode, params: [1]);
    await op(setEventMode, params: [1]);
    final first = await pollRecording();
    recording = first ?? false;
  }

  /// GetEvent data: records of (u32 size, u32 type, ...) ending with a
  /// size-8 type-0 record. PropValueChanged = (prop u32, value u32...).
  static bool? parseRecording(Uint8List data) {
    final d = ByteData.sublistView(data);
    var p = 0;
    bool? state;
    while (p + 8 <= data.length) {
      final size = d.getUint32(p, Endian.little);
      final type = d.getUint32(p + 4, Endian.little);
      if (size < 8 || (size == 8 && type == 0)) break;
      if (type == propChanged && p + 16 <= data.length) {
        final prop = d.getUint32(p + 8, Endian.little);
        if (prop == recordStatus) state = d.getUint32(p + 12, Endian.little) != 0;
      }
      p += size;
    }
    return state;
  }

  @override
  Future<bool?> pollRecording() async => parseRecording((await op(getEvent, quiet: true)).data);

  Future<void> _setRecord(int v) => opWhenReady(setPropEx, dataOut: PtpCamera.u32s([12, recordStatus, v]));

  @override
  Future<void> startRecording() => _setRecord(4);

  @override
  Future<void> stopRecording() => _setRecord(0);
}

/// Sony PC Remote (current Alpha/FX): SDIO_Connect 0x9201 handshake
/// (phases 1, 2, ext-info 0x9202 with 0xC8, phase 3); record by holding the
/// movie button property 0xD2C8 (2 = pressed to start, 1 = released to stop)
/// via SDIO_ControlDevice 0x9207; state from property 0xD21D
/// (MovieRecordingState) in the SDIO_GetAllExtDevicePropInfo 0x9209 blob.
class SonyPtpCamera extends PtpCamera {
  SonyPtpCamera(super.config);

  static const sdioConnect = 0x9201, getExtInfo = 0x9202, controlDevice = 0x9207, getAllProps = 0x9209;
  static const movieButton = 0xD2C8, movieState = 0xD21D;

  bool _canReadState = true;

  @override
  Future<void> afterOpen() async {
    await op(sdioConnect, params: [1, 0, 0]);
    await op(sdioConnect, params: [2, 0, 0]);
    await op(getExtInfo, params: [0xC8]);
    await op(sdioConnect, params: [3, 0, 0]);
  }

  @override
  Future<bool?> pollRecording() async {
    if (!_canReadState) return null;
    final r = await op(getAllProps, quiet: true);
    if (!r.ok) return null;
    final v = findPropValue(r.data, movieState);
    if (v == null) {
      _canReadState = false;
      trace('This Sony model does not report its recording state; it can\'t lead the phones.');
      return null;
    }
    return v != 0;
  }

  static int _size(int type) => switch (type) {
        0x1 || 0x2 => 1,
        0x3 || 0x4 => 2,
        0x5 || 0x6 => 4,
        0x7 || 0x8 => 8,
        _ => -1,
      };

  /// Walks the property list for [code]. Tries the classic layout, then the
  /// newer one (two enum lists per property).
  static int? findPropValue(Uint8List data, int code) {
    for (final newer in [false, true]) {
      try {
        final v = _walk(data, code, newer);
        if (v != null) return v;
      } catch (_) {}
    }
    return null;
  }

  static int? _walk(Uint8List data, int code, bool newer) {
    final r = PtpReader(data);
    final n = r.u64();
    int read(int type) {
      final s = _size(type);
      if (s < 0) {
        if (type == 0xFFFF) {
          r.string();
          return 0;
        }
        throw StateError('unknown type 0x${type.toRadixString(16)}');
      }
      final v = switch (s) { 1 => r.u8(), 2 => r.u16(), 4 => r.u32(), _ => r.u64() };
      return v;
    }

    for (var i = 0; i < n && !r.done; i++) {
      final propCode = r.u16();
      final type = r.u16();
      r.u8(); // get/set
      r.u8(); // enabled
      read(type); // factory default
      final current = read(type);
      if (propCode == code) return current;
      final form = r.u8();
      if (form == 1) {
        read(type);
        read(type);
        read(type);
      } else if (form == 2) {
        for (var k = 0; k < (newer ? 2 : 1); k++) {
          final count = r.u16();
          for (var j = 0; j < count; j++) {
            read(type);
          }
        }
      }
    }
    return null;
  }

  Future<void> _press(int v) => opWhenReady(controlDevice, params: [movieButton], dataOut: PtpCamera.u16(v));

  @override
  Future<void> startRecording() => _press(2);

  @override
  Future<void> stopRecording() => _press(1);
}

/// Fujifilm: InitiateMovieCapture 0x9020 / TerminateMovieCapture 0x9021,
/// after asking for PC priority (PriorityMode 0xD207 = 2). Fuji reports no
/// recording state, so it can't lead.
class FujifilmPtpCamera extends PtpCamera {
  FujifilmPtpCamera(super.config);

  @override
  Future<void> afterOpen() async {
    await op(Ptp.setDevicePropValue, params: [0xD207], dataOut: PtpCamera.u16(2));
  }

  @override
  Future<bool?> pollRecording() async => null;

  @override
  Future<void> startRecording() => opWhenReady(0x9020);

  @override
  Future<void> stopRecording() => opWhenReady(0x9021);
}

/// Any PTP/IP camera: the standard InitiateOpenCapture 0x101C /
/// TerminateOpenCapture 0x1018 pair, which many bodies map to video.
class GenericPtpCamera extends PtpCamera {
  GenericPtpCamera(super.config);

  int? _openTid;

  @override
  Future<bool?> pollRecording() async => null;

  @override
  Future<void> startRecording() async {
    if (!supports(Ptp.initiateOpenCapture)) {
      throw PtpException('${model ?? 'This camera'} does not offer remote capture over PTP/IP.');
    }
    final r = await opWhenReady(Ptp.initiateOpenCapture, params: [0, 0]);
    _openTid = r.transactionId;
  }

  @override
  Future<void> stopRecording() async {
    final t = _openTid;
    if (t == null) return;
    await opWhenReady(Ptp.terminateOpenCapture, params: [t]);
    _openTid = null;
  }
}
