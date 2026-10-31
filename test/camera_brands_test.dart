import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/host/external_camera.dart';
import 'package:synccam/host/ptp_cameras.dart';
import 'package:synccam/host/ptpip.dart';

// ------------------------------------------------------------ fake PTP/IP

/// A PTP/IP camera on localhost implementing the operations SyncCam uses for
/// one brand. [recording] is the camera's real state; [pressButton] is the
/// user pressing REC on the body.
class FakePtpCamera {
  FakePtpCamera(this.brand);
  final String brand; // nikon | canon | sony
  late ServerSocket server;
  Socket? _events;
  bool recording = false;
  final List<int> ops = [];
  final List<int> _nikonPending = [];
  int? _canonPending;

  Future<int> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_onConn);
    return server.port;
  }

  void pressButton() {
    recording = !recording;
    if (brand == 'nikon') {
      final code = recording ? NikonPtpCamera.evStarted : NikonPtpCamera.evComplete;
      _nikonPending.add(code);
      _send(_events, Ptp.event, (PtpWriter()
            ..u16(code)
            ..u32(0)
            ..u32(1))
          .take());
    }
    if (brand == 'canon') _canonPending = recording ? 4 : 0;
  }

  static void _send(Socket? s, int type, Uint8List payload) {
    if (s == null) return;
    s.add((PtpWriter()
          ..u32(payload.length + 8)
          ..u32(type)
          ..bytes(payload))
        .take());
  }

  void _onConn(Socket s) {
    var buf = <int>[];
    int? pendingOp, pendingTid;
    List<int> pendingParams = [];
    s.listen((chunk) {
      buf.addAll(chunk);
      while (buf.length >= 8) {
        final d = ByteData.sublistView(Uint8List.fromList(buf));
        final len = d.getUint32(0, Endian.little);
        if (buf.length < len) break;
        final type = d.getUint32(4, Endian.little);
        final payload = Uint8List.fromList(buf.sublist(8, len));
        buf = buf.sublist(len);
        final r = PtpReader(payload);
        switch (type) {
          case Ptp.initCommandRequest:
            _send(s, Ptp.initCommandAck, (PtpWriter()
                  ..u32(7)
                  ..bytes(Uint8List(16))
                  ..utf16z('Fake $brand')
                  ..u32(0x00010000))
                .take());
          case Ptp.initEventRequest:
            _events = s;
            _send(s, Ptp.initEventAck, Uint8List(0));
          case Ptp.operationRequest:
            final phase = r.u32();
            final op = r.u16();
            final tid = r.u32();
            final params = <int>[];
            while (r.pos + 4 <= payload.length) {
              params.add(r.u32());
            }
            ops.add(op);
            if (phase == 2) {
              pendingOp = op;
              pendingTid = tid;
              pendingParams = params;
            } else {
              _handle(s, op, tid, params, null);
            }
          case Ptp.endData:
            final data = Uint8List.sublistView(payload, 4);
            _handle(s, pendingOp!, pendingTid!, pendingParams, data);
        }
      }
    });
  }

  void _respond(Socket s, int tid, {int code = Ptp.ok, Uint8List? data}) {
    if (data != null) {
      _send(s, Ptp.startData, (PtpWriter()
            ..u32(tid)
            ..u64(data.length))
          .take());
      _send(s, Ptp.endData, (PtpWriter()
            ..u32(tid)
            ..bytes(data))
          .take());
    }
    _send(s, Ptp.operationResponse, (PtpWriter()
          ..u16(code)
          ..u32(tid))
        .take());
  }

  Uint8List _deviceInfo() {
    final opsList = switch (brand) {
      'nikon' => [0x1001, 0x1002, 0x920A, 0x920B, 0x90C7, 0x90C8],
      'canon' => [0x1001, 0x1002, 0x9110, 0x9114, 0x9115, 0x9116],
      _ => [0x1001, 0x1002, 0x9201, 0x9202, 0x9207, 0x9209],
    };
    void str(PtpWriter w, String v) {
      w.bytes([v.length + 1]);
      w.utf16z(v);
    }

    final w = PtpWriter()
      ..u16(100)
      ..u32(6)
      ..u16(100);
    str(w, 'ext');
    w.u16(0);
    w.u32(opsList.length);
    opsList.forEach(w.u16);
    w
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u32(0);
    str(w, brand == 'nikon' ? 'Nikon Corporation' : brand == 'canon' ? 'Canon Inc.' : 'Sony Corporation');
    str(w, brand == 'nikon' ? 'Z 6_2' : brand == 'canon' ? 'Canon EOS R6' : 'ILCE-7M4');
    str(w, '1.0');
    str(w, 'SN1');
    return w.take();
  }

  Uint8List _sonyProps() {
    final w = PtpWriter()
      ..u64(2)
      // 0x5007 (u16 aperture): factory, current, no form
      ..u16(0x5007)
      ..u16(0x4)
      ..bytes([1, 1])
      ..u16(280)
      ..u16(280)
      ..bytes([0])
      // 0xD21D movie recording state (u8), enum form {0,1}
      ..u16(SonyPtpCamera.movieState)
      ..u16(0x2)
      ..bytes([0, 1, 0, recording ? 1 : 0, 2])
      ..u16(2)
      ..bytes([0, 1]);
    return w.take();
  }

  void _handle(Socket s, int op, int tid, List<int> params, Uint8List? data) {
    switch (op) {
      case Ptp.getDeviceInfo:
        _respond(s, tid, data: _deviceInfo());
      case 0x920A: // Nikon start
        recording = true;
        _nikonPending.add(NikonPtpCamera.evStarted);
        _respond(s, tid);
      case 0x920B:
        recording = false;
        _nikonPending.add(NikonPtpCamera.evComplete);
        _respond(s, tid);
      case 0x90C7: // Nikon GetEvent
        final w = PtpWriter()..u16(_nikonPending.length);
        for (final c in _nikonPending) {
          w
            ..u16(c)
            ..u32(1);
        }
        _nikonPending.clear();
        _respond(s, tid, data: w.take());
      case 0x9110: // Canon SetDevicePropValueEx
        final v = ByteData.sublistView(data!).getUint32(8, Endian.little);
        recording = v != 0;
        _canonPending = v;
        _respond(s, tid);
      case 0x9116: // Canon GetEvent
        final w = PtpWriter();
        if (_canonPending != null) {
          w
            ..u32(16)
            ..u32(CanonPtpCamera.propChanged)
            ..u32(CanonPtpCamera.recordStatus)
            ..u32(_canonPending!);
          _canonPending = null;
        }
        w
          ..u32(8)
          ..u32(0);
        _respond(s, tid, data: w.take());
      case 0x9207: // Sony control device
        if (params.first == SonyPtpCamera.movieButton) {
          recording = ByteData.sublistView(data!).getUint16(0, Endian.little) == 2;
        }
        _respond(s, tid);
      case 0x9209:
        _respond(s, tid, data: _sonyProps());
      default:
        _respond(s, tid);
    }
  }

  Future<void> stop() => server.close();
}

Future<void> _ptpScenario(ExternalKind kind, String brand) async {
  PtpCamera.guidProvider = () async => Uint8List(16);
  final fake = FakePtpCamera(brand);
  final port = await fake.start();
  final cam = ExternalCamera.create(ExternalConfig(kind: kind, host: '127.0.0.1', port: port));
  final seen = <bool>[];
  cam.onRecordingChanged = (r, _) => seen.add(r);
  await cam.start();
  expect(cam.connected, isTrue, reason: '${cam.error}\n${cam.log.join('\n')}');
  expect(cam.model, isNotEmpty);

  await cam.startRecording();
  expect(fake.recording, isTrue, reason: 'SyncCam should have started the camera');
  await cam.stopRecording();
  expect(fake.recording, isFalse);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  seen.clear();

  fake.pressButton(); // REC pressed on the camera body
  await Future<void>.delayed(const Duration(milliseconds: 700));
  fake.pressButton();
  await Future<void>.delayed(const Duration(milliseconds: 700));
  expect(seen, [true, false], reason: cam.log.join('\n'));
  cam.dispose();
  await fake.stop();
}

// ------------------------------------------------------------ fake HTTP

Future<(HttpServer, ExternalCamera)> _http(ExternalKind kind, FutureOr<String> Function(HttpRequest, String body) h) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    final out = await h(req, body);
    req.response
      ..headers.contentType = ContentType.json
      ..write(out);
    await req.response.close();
  });
  final cam = ExternalCamera.create(ExternalConfig(kind: kind, host: '127.0.0.1', port: server.port));
  return (server, cam);
}

Future<List<bool>> _httpScenario(ExternalCamera cam, void Function(bool) setState) async {
  final seen = <bool>[];
  cam.onRecordingChanged = (r, _) => seen.add(r);
  await cam.start();
  expect(cam.connected, isTrue, reason: '${cam.error}\n${cam.log.join('\n')}');
  setState(true);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  setState(false);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await cam.startRecording();
  await cam.stopRecording();
  cam.dispose();
  return seen;
}

void main() {
  group('PTP/IP brands against a fake camera speaking PTP/IP', () {
    test('Nikon: start/stop ops, detects body REC from events', () => _ptpScenario(ExternalKind.nikon, 'nikon'));
    test('Canon EOS: EVFRecordStatus via 0x9110, detects from GetEvent', () => _ptpScenario(ExternalKind.canonPtp, 'canon'));
    test('Sony: movie button via 0x9207, state from 0xD21D', () => _ptpScenario(ExternalKind.sonyPtp, 'sony'));
  });

  test('Sony property walker finds 0xD21D after other properties', () {
    final f = FakePtpCamera('sony')..recording = true;
    expect(SonyPtpCamera.findPropValue(f._sonyProps(), SonyPtpCamera.movieState), 1);
  });

  test('Blackmagic REST: transports/0/record', () async {
    var rec = false;
    final puts = <String>[];
    final (server, cam) = await _http(ExternalKind.blackmagic, (req, body) {
      if (req.uri.path == '/control/api/v1/transports/0/record') {
        if (req.method == 'PUT') {
          puts.add(body);
          return '';
        }
        return jsonEncode({'recording': rec});
      }
      return jsonEncode({'deviceName': 'Cinema Camera 6K'});
    });
    final seen = await _httpScenario(cam, (v) => rec = v);
    expect(seen, [true, false]);
    expect(puts, ['{"recording":true}', '{"recording":false}']);
    expect(cam.model, 'Cinema Camera 6K');
    await server.close(force: true);
  });

  test('OSC (Ricoh Theta / Insta360): _captureStatus and startCapture', () async {
    var rec = false;
    final commands = <String>[];
    final (server, cam) = await _http(ExternalKind.osc, (req, body) {
      switch (req.uri.path) {
        case '/osc/info':
          return jsonEncode({'manufacturer': 'RICOH', 'model': 'RICOH THETA X'});
        case '/osc/state':
          return jsonEncode({
            'state': {'_captureStatus': rec ? 'shooting' : 'idle'}
          });
        default:
          commands.add((jsonDecode(body) as Map)['name'] as String);
          return jsonEncode({'state': 'done'});
      }
    });
    final seen = await _httpScenario(cam, (v) => rec = v);
    expect(seen, [true, false]);
    expect(commands, ['camera.setOptions', 'camera.startCapture', 'camera.stopCapture']);
    await server.close(force: true);
  });

  test('Sony Camera Remote API: getEvent cameraStatus and startMovieRec', () async {
    var rec = false;
    final methods = <String>[];
    final (server, cam) = await _http(ExternalKind.sonyApi, (req, body) {
      final m = (jsonDecode(body) as Map)['method'] as String;
      if (m == 'getEvent') {
        return jsonEncode({
          'result': [
            [],
            {'type': 'cameraStatus', 'cameraStatus': rec ? 'MovieRecording' : 'IDLE'}
          ],
          'id': 1
        });
      }
      methods.add(m);
      return jsonEncode({
        'result': [0],
        'id': 1
      });
    });
    final seen = await _httpScenario(cam, (v) => rec = v);
    expect(seen, [true, false]);
    expect(methods, containsAllInOrder(['startRecMode', 'setShootMode', 'startMovieRec', 'stopMovieRec']));
    await server.close(force: true);
  });

  test('OM System: sends takemotion with the app user agent', () async {
    final calls = <String>[];
    String? ua;
    final (server, cam) = await _http(ExternalKind.olympus, (req, body) {
      ua = req.headers.value('user-agent');
      calls.add('${req.uri.path}?${req.uri.query}');
      return req.uri.path == '/get_caminfo.cgi' ? '<caminfo><model>E-M1MarkIII</model></caminfo>' : '';
    });
    await cam.start();
    expect(cam.model, 'E-M1MarkIII');
    await cam.startRecording();
    await cam.stopRecording();
    expect(calls, containsAllInOrder(['/switch_cammode.cgi?mode=rec', '/exec_takemotion.cgi?com=starttake', '/exec_takemotion.cgi?com=stoptake']));
    expect(ua, 'OI.Share v2');
    cam.dispose();
    await server.close(force: true);
  });

  test('every brand kind can be created, and capability flags are consistent', () {
    for (final k in ExternalKind.values) {
      final cam = ExternalCamera.create(ExternalConfig(kind: k, host: '127.0.0.1', port: k.defaultPort));
      expect(cam.config.kind, k);
      expect(k.label, isNotEmpty);
      if (k.canLead) expect(k.canControl, isTrue);
      cam.dispose();
    }
  });
}
