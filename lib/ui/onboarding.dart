import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'widgets.dart';

/// First-run splash: several small camera frames slide in and snap into
/// one, then the name appears.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
      Future<void>.delayed(
        const Duration(milliseconds: 600),
        () => mounted ? widget.onDone() : null,
      );
    } else {
      _c.forward().whenComplete(
        () => Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (mounted) widget.onDone();
        }),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return Scaffold(
      backgroundColor: t.background,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final slide = Curves.easeOutCubic.transform(
              (_c.value / 0.6).clamp(0, 1),
            );
            final snap = Curves.easeOutBack.transform(
              ((_c.value - 0.55) / 0.2).clamp(0, 1),
            );
            final name = Curves.easeOut.transform(
              ((_c.value - 0.7) / 0.3).clamp(0, 1),
            );
            const n = 5;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 220,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var i = 0; i < n; i++)
                        Builder(
                          builder: (_) {
                            final a = -math.pi / 2 + i * 2 * math.pi / n;
                            final d = 140 * (1 - slide);
                            final spread = 26 * (1 - snap);
                            final dx = math.cos(a) * d + (i - 2) * spread;
                            return Transform.translate(
                              offset: Offset(dx, math.sin(a) * d),
                              child: Opacity(
                                opacity:
                                    (slide * 1.4).clamp(0, 1) *
                                    (1 - snap * 0.85),
                                child: Container(
                                  width: 46,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: CameraColors.forSlot(i),
                                      width: 2.5,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      Opacity(
                        opacity: snap,
                        child: Transform.scale(
                          scale: 0.6 + 0.4 * snap,
                          child: Container(
                            width: 96,
                            height: 72,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: t.accent, width: 3),
                            ),
                            child: Center(
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: const BoxDecoration(
                                  color: Status.recording,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Opacity(
                  opacity: name,
                  child: Transform.translate(
                    offset: Offset(0, 8 * (1 - name)),
                    child: Text(
                      'SyncCam',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontSize: 32, letterSpacing: -0.8),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// First-run tour: three short pages.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  static const _key = 'onboarded.v2';
  static Future<bool> seen() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _Page {
  const _Page(this.icon, this.title, this.text);
  final IconData icon;
  final String title;
  final String text;
}

const _pages = [
  _Page(
    Icons.grid_view_rounded,
    'Many cameras, one shutter',
    'One phone controls the rig. Every camera takes the photo or starts the video at the same moment, within a millisecond.',
  ),
  _Page(
    Icons.devices_rounded,
    'Phones, iPhones and Wi-Fi cameras',
    'Android phones join with the app. iPhones just scan a code, no app needed. Sony, Canon, Nikon, GoPro and more join over Wi-Fi.',
  ),
  _Page(
    Icons.lock_rounded,
    'Your footage stays on your devices',
    'No account, no cloud. Photos and videos go only between your own phones and cameras.',
  ),
];

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pager = PageController();
  int _page = 0;

  Future<void> _finish() async {
    await (await SharedPreferences.getInstance()).setBool(
      OnboardingScreen._key,
      true,
    );
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
    final tt = Theme.of(context).textTheme;
    final t = context.sync;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
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
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        i == 0
                            ? const AppLogo(size: 150)
                            : IconBadge(p.icon, size: 96),
                        const SizedBox(height: 36),
                        Text(
                          p.title,
                          textAlign: TextAlign.center,
                          style: tt.headlineSmall?.copyWith(fontSize: 26),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          p.text,
                          textAlign: TextAlign.center,
                          style: tt.bodyLarge?.copyWith(
                            color: t.muted,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? t.accent : t.line,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: PrimaryButton(
                label: last ? 'Get started' : 'Next',
                icon: last ? Icons.arrow_forward_rounded : null,
                onPressed: last
                    ? _finish
                    : () => _pager.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
