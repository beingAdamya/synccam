import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'widgets.dart';

/// First-run tour: what SyncCam does and how a shoot works, in four screens.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  static const _key = 'onboarded.v1';
  static Future<bool> seen() async => (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _Page {
  const _Page(this.icon, this.color, this.title, this.text);
  final IconData? icon;
  final Color color;
  final String title;
  final String text;
}

const _pages = [
  _Page(null, Brand.red, 'Many cameras.\nOne shutter.',
      'Film or photograph from every angle at exactly the same moment, with phones and cameras you already have.'),
  _Page(Icons.touch_app_rounded, Brand.coral, 'One phone is in charge',
      'Start a shoot on one phone. It shows what every camera sees and controls them all: zoom, flash, photo and video.'),
  _Page(Icons.wifi_rounded, Brand.sky, 'Everyone joins over Wi-Fi',
      'Phones with the app tap Join. iPhones don\'t even need the app: they scan a code and join in Safari.'),
  _Page(Icons.photo_camera_rounded, Brand.warn, 'Bring your pro cameras',
      'Connect Sony, Canon, Nikon, GoPro and more. Press record on the camera and every phone starts with it.'),
];

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pager = PageController();
  int _page = 0;

  Future<void> _finish() async {
    await (await SharedPreferences.getInstance()).setBool(OnboardingScreen._key, true);
    widget.onDone();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _pages.length - 1;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _finish, child: const Text('Skip')),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) {
                final p = _pages[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    p.icon == null ? const AppLogo(size: 180) : IconBadge(p.icon!, color: p.color, size: 120),
                    const SizedBox(height: 40),
                    Text(p.title, textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontSize: 28, height: 1.2)),
                    const SizedBox(height: 16),
                    Text(p.text, textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: Brand.textDim, height: 1.5)),
                  ]),
                );
              },
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < _pages.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.all(4),
                width: i == _page ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: i == _page ? Brand.red : Brand.line,
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: PrimaryButton(
              label: last ? 'Get started' : 'Next',
              icon: last ? Icons.check_rounded : Icons.arrow_forward_rounded,
              onPressed: last
                  ? _finish
                  : () => _pager.nextPage(duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic),
            ),
          ),
        ]),
      ),
    );
  }
}
