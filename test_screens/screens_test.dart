// Renders key screens to PNGs for visual review (not run in CI: fonts render
// differently per OS). Run:
//   flutter test test_screens/screens_test.dart --update-goldens
// Output: test_screens/goldens/*.png
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synccam/core/protocol.dart';
import 'package:synccam/core/updates.dart';
import 'package:synccam/host/add_cameras.dart';
import 'package:synccam/host/gallery_screen.dart';
import 'package:synccam/host/host_server.dart';
import 'package:synccam/host/live_wall.dart';
import 'package:synccam/host/rig_settings.dart';
import 'package:synccam/host/settings_tab.dart';
import 'package:synccam/host/take.dart';
import 'package:synccam/host/take_screen.dart';
import 'package:synccam/main.dart';
import 'package:synccam/node/join_screen.dart';
import 'package:synccam/ui/onboarding.dart';
import 'package:synccam/ui/rig_widgets.dart';
import 'package:synccam/ui/theme.dart';
import 'package:synccam/ui/update_dialog.dart';
import 'package:synccam/ui/widgets.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
    }
    await l.load();
  }

  await family('Inter', ['Inter-400.ttf', 'Inter-500.ttf', 'Inter-600.ttf', 'Inter-700.ttf']);
  await family('JetBrainsMono', ['JetBrainsMono-400.ttf', 'JetBrainsMono-600.ttf']);
  final sdk = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(
        File('$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf').readAsBytesSync())));
  await icons.load();
}

Widget _app(Widget home, ThemeChoice theme) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(theme),
      builder: (context, child) => AppBackground(child: child!),
      home: home,
    );

Future<void> _shot(
  WidgetTester tester,
  String name,
  Widget w, {
  ThemeChoice theme = ThemeChoice.studio,
  bool landscape = false,
  Future<void> Function()? then,
}) async {
  tester.view.physicalSize = landscape ? const Size(2532, 1170) : const Size(1170, 2532); // iPhone 14-ish
  tester.view.devicePixelRatio = 3;
  tester.view.padding = landscape
      ? const FakeViewPadding(left: 141, right: 141, bottom: 63)
      : const FakeViewPadding(top: 141, bottom: 102);
  await tester.pumpWidget(_app(w, theme));
  await tester.pump(const Duration(milliseconds: 100));
  if (then != null) await then();
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e).timeout(const Duration(seconds: 3), onTimeout: () {});
    }
  });
  await tester.pump(const Duration(milliseconds: 50));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  await tester.pumpWidget(const SizedBox());
  // Let one-shot timers (settings confirmations, snackbars) run out.
  await tester.pump(const Duration(seconds: 8));
}

/// A believable camera frame: sky, ground, a subject seen from [angle].
Uint8List _frame(int angle, {bool wide = false}) {
  final w = wide ? 480 : 270, h = wide ? 270 : 360;
  final im = img.Image(width: w, height: h);
  final hue = (angle * 47) % 360;
  for (var y = 0; y < h; y++) {
    final t = y / h;
    final c = t < 0.62
        ? img.ColorRgb8((40 + 60 * t).round(), (70 + 90 * t).round(), (120 + 100 * t).round())
        : img.ColorRgb8((60 + 40 * t).round(), (55 + 30 * t).round(), 45);
    img.drawLine(im, x1: 0, y1: y, x2: w, y2: y, color: c);
  }
  final cx = (w / 2 + math.sin(angle) * w * 0.12).round();
  img.fillCircle(im, x: cx, y: (h * 0.42).round(), radius: (h * 0.09).round(),
      color: img.ColorRgb8(230, 190, 160));
  img.fillRect(im,
      x1: cx - (w * 0.1).round(),
      y1: (h * 0.52).round(),
      x2: cx + (w * 0.1).round(),
      y2: (h * 0.9).round(),
      color: img.ColorRgb8(
          (120 + 100 * math.cos(hue)).round().clamp(0, 255), 60, (140 + 90 * math.sin(hue)).round().clamp(0, 255)),
      radius: 12);
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}

class _FakeLink implements DeviceLink {
  @override
  void sendText(String text) {}
  @override
  void close() {}
}

/// A rig with [n] cameras in assorted states.
HostServer _rig(int n, Directory dir, {bool recording = false, bool wide = false}) {
  final server = HostServer(sessionName: 'Wedding · Hall B', library: TakeLibrary.at(dir));
  const names = ['Left wide', 'Center', 'Right wide', 'Top', 'Close-up', 'Balcony', 'Stage left', 'Stage right', 'Crowd'];
  for (var i = 0; i < n; i++) {
    final input = server.attachLink(_FakeLink(), '10.0.0.${i + 2}');
    input.onText(
        encodeMsg(Msg.hello, {
          'id': 'cam$i',
          'name': names[i % names.length],
          'model': 'Pixel ${i + 6}',
          'platform': i == 2 ? 'web' : 'android',
          'v': Net.protocolVersion,
        }),
        (_) {});
    final drift = i == 3 && !recording;
    input.onText(
        encodeMsg(Msg.status, {
          'synced': true,
          'errMs': drift ? 18.0 : 0.4 + i * 0.15,
          'cameraReady': true,
          'battery': i == 1 ? 12 : 84 - i * 7,
          'recording': recording,
          'recStartHostUs': recording ? server.nowUs() - 42 * 1000000 : null,
          'freeBytes': 40 * 1024 * 1024 * 1024,
        }),
        (_) {});
    final d = server.devices.firstWhere((x) => x.id == 'cam$i');
    d.onFrame(_frame(i, wide: wide));
    if (i == n - 1 && n > 3 && !recording) input.onClosed();
  }
  return server;
}

Future<Take> _take(Directory dir, TakeLibrary lib, int n, String kind, {String label = ''}) async {
  final t = Take.create(dir, kind, 0, 0, [
    for (var i = 0; i < n; i++) TakeDevice('cam$i', ['Left wide', 'Center', 'Right wide', 'Top', 'Close-up', 'Balcony'][i], i, 'Pixel', 0),
  ]);
  t.label = label;
  await t.dir.create(recursive: true);
  for (var i = 0; i < n; i++) {
    final it = TakeItem('cam$i', 0, kind == 'video' ? 'video' : 'photo')
      ..timing['calledHostUs'] = 1000 + i * 300
      ..timing['startReturnedHostUs'] = 1000 + i * 300
      ..timing['stopReturnedHostUs'] = 42 * 1000000
      ..size = 2400000 + i * 100000;
    final name = 'cam$i.${kind == 'video' ? 'mp4' : 'jpg'}';
    if (kind == 'video') {
      await File('${t.dir.path}/thumb_cam$i.jpg').writeAsBytes(_frame(i + 3));
      await File('${t.dir.path}/$name').writeAsBytes([0]);
    } else {
      await File('${t.dir.path}/$name').writeAsBytes(_frame(i));
    }
    if (!(kind == 'video' && i == n - 1)) it.file = name;
    t.items.add(it);
  }
  lib.add(t);
  return t;
}

void main() {
  late Directory tmp;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final ch in ['xyz.luan/audioplayers.global', 'xyz.luan/audioplayers', 'xyz.luan/audioplayers.global/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'notify.asked': true,
      'onboarded.v2': true,
      'recentRigs.v1': jsonEncode([
        {'name': 'Sunday studio', 'cameras': ['Left', 'Center', 'Right', 'Top'], 'lastUsed': '2026-11-09T10:00:00', 'hostIsCamera': false},
      ]),
    });
    AppVersion.current = '0.6.0';
    await _loadFonts();
    tmp = Directory.systemTemp.createTempSync('screens');
  });

  testWidgets('home', (t) => _shot(t, 'home', const HomeScreen()));
  testWidgets('home-daylight', (t) => _shot(t, 'home-daylight', const HomeScreen(), theme: ThemeChoice.daylight));
  testWidgets('onboarding', (t) => _shot(t, 'onboarding', OnboardingScreen(onDone: () {})));
  testWidgets('splash', (t) => _shot(t, 'splash', SplashScreen(onDone: () {}), then: () async {
        await t.pump(const Duration(milliseconds: 1500));
      }));
  testWidgets('join', (t) => _shot(t, 'join', const JoinScreen()));

  testWidgets('wall-4', (t) async {
    final s = _rig(4, tmp);
    await _shot(t, 'wall-4', Scaffold(backgroundColor: Colors.black, body: LiveWall(server: s, onAddCameras: () {}, menu: const Icon(Icons.more_horiz, color: Colors.white), dockInset: const EdgeInsets.only(bottom: 72))));
  });
  testWidgets('wall-4-collapsed', (t) async {
    final s = _rig(4, tmp);
    await _shot(t, 'wall-4-collapsed', Scaffold(backgroundColor: Colors.black, body: LiveWall(server: s, onAddCameras: () {}, menu: const Icon(Icons.more_horiz, color: Colors.white), dockInset: const EdgeInsets.only(bottom: 72))), then: () async {
      await t.tap(find.byTooltip('Hide controls'));
      await t.pump(const Duration(milliseconds: 300));
    });
  });
  testWidgets('wall-9-recording-landscape', (t) async {
    final s = _rig(9, tmp, recording: true, wide: true);
    s.config.mode = CaptureMode.video;
    s.activeVideoTake = Take.create(tmp, 'video', 0, 0, []);
    await _shot(t, 'wall-9-recording-landscape', Scaffold(backgroundColor: Colors.black, body: LiveWall(server: s, onAddCameras: () {}, menu: const Icon(Icons.more_horiz, color: Colors.white), dockInset: const EdgeInsets.only(left: 76))), landscape: true);
  });
  testWidgets('wall-hc', (t) async {
    final s = _rig(2, tmp);
    await _shot(t, 'wall-hc', Scaffold(backgroundColor: Colors.black, body: LiveWall(server: s, onAddCameras: () {}, menu: const Icon(Icons.more_horiz, color: Colors.white), dockInset: const EdgeInsets.only(bottom: 72))), theme: ThemeChoice.highContrast);
  });
  testWidgets('wall-empty', (t) async {
    final s = _rig(0, tmp);
    await _shot(t, 'wall-empty', Scaffold(backgroundColor: Colors.black, body: LiveWall(server: s, onAddCameras: () {}, menu: const SizedBox(), dockInset: const EdgeInsets.only(bottom: 72))));
  });
  testWidgets('not-ready', (t) async {
    final s = _rig(4, tmp);
    await _shot(t, 'not-ready', Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showNotReadySheet(context, s), child: const Text('open'))))), then: () async {
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 600));
    });
  });
  testWidgets('add-cameras', (t) async {
    final s = _rig(3, tmp);
    s.addresses.add('192.168.1.20');
    await _shot(t, 'add-cameras', AddCamerasScreen(server: s));
  });
  testWidgets('rig-settings', (t) async {
    final s = _rig(4, tmp);
    s.onlineDevices.first.appliedNote = 'Used 30 fps';
    await _shot(t, 'rig-settings', Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showRigSettings(context, s), child: const Text('open'))))), then: () async {
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 600));
      s.updateGlobal((g) => g.fps = 60);
      await t.pump(const Duration(milliseconds: 50));
    });
  });
  testWidgets('settings', (t) async {
    final s = _rig(1, tmp);
    await _shot(t, 'settings', Scaffold(body: SettingsTab(server: s, onEnd: () {})));
  });

  Future<TakeLibrary> library() async {
    final dir = Directory('${tmp.path}/lib${DateTime.now().microsecondsSinceEpoch}')..createSync();
    final lib = TakeLibrary.at(dir);
    await t0(dir, lib);
    return lib;
  }

  testWidgets('gallery', (t) async {
    late TakeLibrary lib;
    await t.runAsync(() async => lib = await library());
    await _shot(t, 'gallery', GalleryScreen(library: lib));
  });
  testWidgets('gallery-select-daylight', (t) async {
    late TakeLibrary lib;
    await t.runAsync(() async => lib = await library());
    await _shot(t, 'gallery-select-daylight', GalleryScreen(library: lib), theme: ThemeChoice.daylight, then: () async {
      await t.longPress(find.byType(TakeCard).first);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byType(TakeCard).at(2));
      await t.pump(const Duration(milliseconds: 300));
    });
  });
  testWidgets('take', (t) async {
    late TakeLibrary lib;
    await t.runAsync(() async => lib = await library());
    final take = lib.takes.firstWhere((x) => x.kind == 'photo');
    await _shot(t, 'take', TakeScreen(library: lib, take: take), then: () async {
      await t.longPress(find.text('Center'));
      await t.pump(const Duration(milliseconds: 300));
    });
  });
  testWidgets('update', (t) async {
    final release = ReleaseInfo(
      tag: 'v0.6.0',
      version: SemVer(0, 6, 0),
      name: 'SyncCam v0.6.0',
      notes: '- A new studio look\n- Pick several takes at once\n---\nInstall notes',
      pageUrl: 'https://example.com',
      apkSize: 115000000,
    );
    await _shot(t, 'update', Builder(builder: (context) {
      return Scaffold(
        body: Center(child: TextButton(onPressed: () => showUpdateDialog(context, release), child: const Text('open'))),
      );
    }), then: () async {
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 600));
    });
  });
}

Future<void> t0(Directory dir, TakeLibrary lib) async {
  await _take(dir, lib, 4, 'photo');
  await _take(dir, lib, 6, 'video', label: 'First dance');
  await _take(dir, lib, 3, 'burst');
  await _take(dir, lib, 5, 'photo');
}
