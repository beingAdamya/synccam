import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/core/clock.dart';
import 'package:synccam/core/protocol.dart';
import 'package:synccam/host/host_server.dart';
import 'package:synccam/host/take.dart';

void main() {
  test('clock sync converges on a host clock that is 123.456 ms ahead', () async {
    const skewUs = 123456;
    final server = ClockSyncServer(now: () => MonoClock.nowUs() + skewUs, port: 47911);
    await server.start();
    final client = ClockSyncClient(InternetAddress.loopbackIPv4, port: 47911);
    await client.start();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    client.stop();
    server.stop();

    expect(client.isSynced, isTrue);
    final errUs = (client.offsetUs - skewUs).abs();
    // ignore: avoid_print
    print('offset error ${errUs}us, best rtt ${client.bestRttUs}us');
    expect(errUs, lessThan(1000), reason: 'loopback sync should be well under 1 ms');
    expect(client.hostToLocal(client.localToHost(42)), 42);
  });

  test('waitUntilLocal fires within 1 ms of the target', () async {
    final errors = <int>[];
    for (var i = 0; i < 10; i++) {
      final target = MonoClock.nowUs() + 40000 + i * 3000;
      await waitUntilLocal(target);
      errors.add(MonoClock.nowUs() - target);
    }
    // ignore: avoid_print
    print('trigger errors (us): $errors');
    expect(errors.every((e) => e >= 0 && e < 1000), isTrue);
  });

  test('per-device override merges on top of global settings', () {
    final g = CameraSettings(zoom: 2, flash: FlashChoice.auto, resolution: ResChoice.max);
    final m = g.merged({'zoom': 3.5, 'lens': 'front'});
    expect(m.zoom, 3.5);
    expect(m.lens, LensChoice.front);
    expect(m.flash, FlashChoice.auto);
    expect(g.needsReinit(m), isTrue);
    expect(g.needsReinit(g.merged({'zoom': 5.0})), isFalse);
    expect(CameraSettings.fromJson(m.toJson()).toJson(), m.toJson());
  });

  test('take computes trigger spread net of stagger, and video head trims', () async {
    final dir = await Directory.systemTemp.createTemp('synccam');
    final a = RemoteDevice('a')..slot = 0;
    final b = RemoteDevice('b')..slot = 1;
    final photo = Take.create(dir, 'photo', 0, 100, [
      TakeDevice('a', 'A', 0, '', 0),
      TakeDevice('b', 'B', 1, '', 0),
    ]);
    // b fires 100 ms later by design (stagger) plus 4 ms of real error.
    photo.addCapture(a, {'shot': 0, 'kind': 'photo', 'calledHostUs': 1000000});
    photo.addCapture(b, {'shot': 0, 'kind': 'photo', 'calledHostUs': 1104000});
    expect(photo.spreadMs(0), closeTo(4, 0.001));

    final video = Take.create(dir, 'video', 0, 0, [
      TakeDevice('a', 'A', 0, '', 0),
      TakeDevice('b', 'B', 1, '', 0),
    ]);
    video.addCapture(a, {'kind': 'video', 'startReturnedHostUs': 5000000});
    video.addCapture(b, {'kind': 'video', 'startReturnedHostUs': 5180000});
    expect(video.headTrimsMs(), {'a': 180.0, 'b': 0.0});

    await video.save();
    final loaded = await Take.loadAll(dir);
    expect(loaded.map((t) => t.id), contains(video.id));
    await dir.delete(recursive: true);
  });
}
