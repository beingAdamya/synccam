import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/host/external_camera.dart';

/// A fake camera on localhost speaking one brand's HTTP API.
class FakeCamera {
  FakeCamera(this.handler);
  final FutureOr<String> Function(HttpRequest req, FakeCamera cam) handler;
  bool recording = false;
  final List<String> commands = [];
  late HttpServer server;

  Future<int> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await handler(req, this);
      req.response
        ..headers.contentType = ContentType.json
        ..write(body);
      await req.response.close();
    });
    return server.port;
  }

  Future<void> stop() => server.close(force: true);
}

Future<List<bool>> _runScenario(ExternalKind kind, FakeCamera fake) async {
  final port = await fake.start();
  final cam = ExternalCamera.create(ExternalConfig(kind: kind, host: '127.0.0.1', port: port));
  final changes = <bool>[];
  cam.onRecordingChanged = (rec, _) => changes.add(rec);
  await cam.start();
  expect(cam.connected, isTrue, reason: cam.error);

  fake.recording = true; // someone pressed REC on the camera body
  await Future<void>.delayed(const Duration(milliseconds: 700));
  fake.recording = false;
  await Future<void>.delayed(const Duration(milliseconds: 700));

  await cam.startRecording(); // SyncCam asks the camera to record
  await cam.stopRecording();
  cam.dispose();
  await fake.stop();
  return changes;
}

void main() {
  test('GoPro: detects record start/stop from status 10 and sends shutter commands', () async {
    final fake = FakeCamera((req, cam) {
      final p = req.uri.path;
      if (p == '/gopro/camera/state') {
        return jsonEncode({
          'status': {'8': 0, '10': cam.recording ? 1 : 0},
          'settings': {},
        });
      }
      cam.commands.add(p);
      return '{}';
    });
    final changes = await _runScenario(ExternalKind.gopro, fake);
    expect(changes, [true, false]);
    expect(fake.commands, containsAllInOrder(['/gopro/camera/shutter/start', '/gopro/camera/shutter/stop']));
  });

  test('Lumix: detects <rec>on</rec> and sends camcmd', () async {
    final fake = FakeCamera((req, cam) {
      final q = req.uri.queryParameters;
      if (q['mode'] == 'getstate') {
        return '<camrply><result>ok</result><state><batt>3/3</batt><rec>${cam.recording ? 'on' : 'off'}</rec></state></camrply>';
      }
      if (q['mode'] == 'camcmd') cam.commands.add(q['value']!);
      return '<camrply><result>ok</result></camrply>';
    });
    final changes = await _runScenario(ExternalKind.lumix, fake);
    expect(changes, [true, false]);
    expect(fake.commands, containsAllInOrder(['recmode', 'video_recstart', 'video_recstop']));
  });

  test('Canon CCAPI: reads recbutton from event polling and posts recbutton actions', () async {
    var lastReported = false;
    final fake = FakeCamera((req, cam) async {
      final p = req.uri.path;
      if (p == '/ccapi/ver100/deviceinformation') return jsonEncode({'productname': 'Canon EOS R6'});
      if (p == '/ccapi/ver100/event/polling') {
        // Like CCAPI: only changed items are reported.
        if (cam.recording == lastReported) return '{}';
        lastReported = cam.recording;
        return jsonEncode({'recbutton': {'status': cam.recording ? 'start' : 'stop'}});
      }
      final body = await utf8.decoder.bind(req).join();
      cam.commands.add('${req.method} $p $body');
      return '{}';
    });
    final changes = await _runScenario(ExternalKind.canon, fake);
    expect(changes, [true, false]);
    expect(fake.commands.last, contains('"action":"stop"'));
    expect(fake.commands.any((c) => c.contains('recbutton') && c.contains('"action":"start"')), isTrue);
  });

  test('unreachable camera reports an error instead of throwing', () async {
    final cam = ExternalCamera.create(ExternalConfig(kind: ExternalKind.gopro, host: '127.0.0.1', port: 1));
    await cam.start();
    expect(cam.connected, isFalse);
    expect(cam.error, contains("Can't reach"));
    cam.dispose();
  });
}
