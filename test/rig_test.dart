import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synccam/core/protocol.dart';
import 'package:synccam/host/camera_scan.dart';
import 'package:synccam/host/external_camera.dart';
import 'package:synccam/host/host_server.dart';
import 'package:synccam/host/take.dart';
import 'package:synccam/ui/cam_status.dart';

/// A camera link that records what the controller sends it.
class FakeLink implements DeviceLink {
  final sent = <Map<String, dynamic>>[];
  @override
  void sendText(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);
  @override
  void close() {}
  Iterable<Map<String, dynamic>> of(String t) => sent.where((m) => m['t'] == t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The controller's sync tone player: no audio in tests.
  for (final ch in ['xyz.luan/audioplayers.global', 'xyz.luan/audioplayers']) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
  }
  // The test binding blocks real HTTP; the camera scan talks to local fakes.
  HttpOverrides.global = null;
  late Directory tmp;
  late HostServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('rig_test');
    server = HostServer(sessionName: 'Test rig', library: TakeLibrary.at(tmp));
  });

  tearDown(() async {
    server.dispose();
    await tmp.delete(recursive: true);
  });

  (RemoteDevice, LinkInput, FakeLink) join(String id, {String name = 'Phone'}) {
    final link = FakeLink();
    final input = server.attachLink(link, '10.0.0.$id');
    input.onText(encodeMsg(Msg.hello, {'id': id, 'name': name, 'model': 'M$id', 'v': Net.protocolVersion}), (_) {});
    return (server.devices.firstWhere((d) => d.id == id), input, link);
  }

  void status(LinkInput input, Map<String, dynamic> s) => input.onText(
      encodeMsg(Msg.status, {'synced': true, 'errMs': 0.6, 'cameraReady': true, 'battery': 80, ...s}), (_) {});

  test('a camera confirms settings; the controller shows the note for what it could not match', () {
    final (d, input, link) = join('1');
    final first = link.of(Msg.settings).last;
    expect(first['seq'], isA<int>());
    expect(d.applying, isTrue);

    input.onText(encodeMsg(Msg.applied, {'seq': first['seq']}), (_) {});
    expect(d.applying, isFalse);
    expect(d.appliedNote, isNull);

    server.updateGlobal((s) => s.zoom = 12);
    final next = link.of(Msg.settings).last;
    expect(next['seq'], greaterThan(first['seq'] as int));
    expect(d.applying, isTrue);
    input.onText(encodeMsg(Msg.applied, {'seq': next['seq'], 'note': 'Used 5.0× zoom'}), (_) {});
    expect(d.applying, isFalse);
    expect(d.appliedNote, 'Used 5.0× zoom');
  });

  test('status reads as one word with a fix: ready, syncing, drift, battery, recording, lost', () {
    final (d, input, _) = join('2', name: 'Top');
    status(input, {});
    expect(statusOf(d).state, CamState.ready);
    expect(statusOf(d).word, 'Ready');

    status(input, {'synced': false});
    expect(statusOf(d).state, CamState.syncing);

    status(input, {'errMs': 25.0});
    expect(statusOf(d).state, CamState.warning);
    expect(statusOf(d).word, 'Drift');
    expect(statusOf(d).fix, contains('Top'));

    status(input, {'battery': 8});
    expect(statusOf(d).word, 'Battery');
    expect(statusOf(d).fix, contains('8%'));

    status(input, {'recording': true, 'battery': 8});
    expect(statusOf(d).state, CamState.recording, reason: 'recording outranks warnings');

    input.onClosed();
    expect(statusOf(d).state, CamState.lost);
    expect(d.recording, isTrue, reason: 'a dropped camera keeps recording on its own');
    expect(notReady(server).map((e) => e.$1), [d]);
  });

  test('every rig gets a 4-digit code', () {
    expect(server.rigCode, matches(RegExp(r'^\d{4}$')));
  });

  test('takes are numbered, and delete can be undone until purged', () async {
    final lib = TakeLibrary.at(tmp);
    final a = Take.create(tmp, 'photo', 0, 0, []);
    final b = Take.create(tmp, 'video', 0, 0, []);
    lib.add(a);
    lib.add(b);
    await a.save();
    await b.save();
    expect([a.number, b.number], [1, 2]);

    lib.remove([a]);
    expect(lib.takes, [b]);
    lib.restore([a]);
    expect(lib.takes.toSet(), {a, b});

    lib.remove([a]);
    await lib.purge([a]);
    expect(await a.dir.exists(), isFalse);
    expect(await b.dir.exists(), isTrue);
  });

  group('finding Wi-Fi cameras', () {
    Future<(HttpServer, int)> fake(Map<String, String> routes) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        final key = req.uri.hasQuery ? '${req.uri.path}?${req.uri.query}' : req.uri.path;
        final body = routes[key];
        req.response.statusCode = body == null ? 404 : 200;
        if (body != null) req.response.write(body);
        await req.response.close();
      });
      return (s, s.port);
    }

    test('a 360° camera answers /osc/info with its model', () async {
      final (s, port) = await fake({'/osc/info': jsonEncode({'manufacturer': 'RICOH', 'model': 'RICOH THETA X'})});
      final f = await CameraScanner.identify('127.0.0.1', port);
      await s.close(force: true);
      expect(f?.name, 'RICOH RICOH THETA X');
      expect(f?.kinds, [ExternalKind.osc]);
    });

    test('a Blackmagic camera answers with its product name', () async {
      final (s, port) = await fake({'/control/api/v1/system/product': jsonEncode({'productName': 'Pocket Cinema Camera 6K'})});
      final f = await CameraScanner.identify('127.0.0.1', port);
      await s.close(force: true);
      expect(f?.name, 'Pocket Cinema Camera 6K');
      expect(f?.kinds, [ExternalKind.blackmagic]);
    });

    test('a web server that is not a camera is ignored', () async {
      final (s, port) = await fake({'/': 'hello'});
      final f = await CameraScanner.identify('127.0.0.1', port);
      await s.close(force: true);
      expect(f, isNull);
    });

    test('PTP/IP cameras offer a brand choice', () async {
      final f = await CameraScanner.identify('192.168.1.40', 15740);
      expect(f?.kinds, contains(ExternalKind.nikon));
      expect(f!.kinds.length, greaterThan(1));
    });
  });
}
