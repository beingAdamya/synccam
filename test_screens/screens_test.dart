// Renders key screens to PNGs for visual review (not run in CI: fonts render
// differently per OS). Run:
//   flutter test test_screens/screens_test.dart --update-goldens
// Output: test_screens/goldens/*.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synccam/core/updates.dart';
import 'package:synccam/main.dart';
import 'package:synccam/ui/guides.dart';
import 'package:synccam/ui/onboarding.dart';
import 'package:synccam/ui/theme.dart';
import 'package:synccam/ui/update_dialog.dart';
import 'package:synccam/ui/widgets.dart';

Future<void> _loadFonts() async {
  final poppins = FontLoader('Poppins');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    poppins.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Poppins-$w.ttf').readAsBytesSync())));
  }
  await poppins.load();
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(
        File('$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf').readAsBytesSync())));
  await icons.load();
}

Widget _app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (context, child) => AppBackground(child: child!),
      home: home,
    );

Future<void> _shot(WidgetTester tester, String name, Widget w, {Future<void> Function()? then}) async {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone 14-ish
  tester.view.devicePixelRatio = 3;
  await tester.pumpWidget(_app(w));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(() async {
    // let Image.asset decode
    for (final e in find.byType(Image).evaluate()) {
      final img = e.widget as Image;
      await precacheImage(img.image, e);
    }
  });
  await tester.pump();
  if (then != null) await then();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({'notify.asked': true, 'onboarded.v1': true});
    AppVersion.current = '0.4.0';
    await _loadFonts();
  });

  testWidgets('home', (t) => _shot(t, 'home', const HomeScreen()));
  testWidgets('onboarding', (t) => _shot(t, 'onboarding', OnboardingScreen(onDone: () {})));
  testWidgets('help', (t) => _shot(t, 'help', const HelpScreen()));
  testWidgets('guide', (t) => _shot(t, 'guide', GuideScreen(guide: guides[2])));
  testWidgets('update', (t) async {
    final release = ReleaseInfo(
      tag: 'v0.5.0',
      version: SemVer(0, 5, 0),
      name: 'SyncCam v0.5.0',
      notes: '- A fresh new look with a 3D logo\n- Update right inside the app\n- Notifications when a new version is ready\n'
          '- Step-by-step guides for every kind of camera\n---\nInstall notes',
      pageUrl: 'https://example.com',
      apkSize: 115000000,
    );
    await _shot(t, 'update', Builder(builder: (context) {
      return Scaffold(
        body: Center(child: TextButton(onPressed: () => showUpdateDialog(context, release), child: const Text('open'))),
      );
    }), then: () async {
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        for (final e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
      });
      await t.pump();
    });
  });
}
