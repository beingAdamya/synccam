import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/prefs.dart';
import 'core/update_service.dart';
import 'core/updates.dart';
import 'host/gallery_screen.dart';
import 'host/host_screen.dart';
import 'host/recent_rigs.dart';
import 'host/settings_tab.dart';
import 'host/take.dart';
import 'node/join_screen.dart';
import 'ui/guides.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';
import 'ui/update_dialog.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppVersion.load();
  await AppPrefs.load();
  try {
    await UpdateNotifications.init();
  } catch (_) {}
  runApp(SyncCamApp(onboarded: await OnboardingScreen.seen()));
}

class SyncCamApp extends StatelessWidget {
  const SyncCamApp({super.key, required this.onboarded});
  final bool onboarded;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeChoice>(
      valueListenable: AppPrefs.theme,
      builder: (context, choice, _) => MaterialApp(
        title: 'SyncCam',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(choice),
        // One backdrop behind every screen; camera screens paint their own black.
        builder: (context, child) => AppBackground(child: child!),
        home: onboarded ? const HomeScreen() : const _FirstRun(),
      ),
    );
  }
}

class _FirstRun extends StatefulWidget {
  const _FirstRun();
  @override
  State<_FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<_FirstRun> {
  bool _splash = true;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 250),
    child: _splash
        ? SplashScreen(
            key: const ValueKey(0),
            onDone: () => setState(() => _splash = false),
          )
        : OnboardingScreen(
            key: const ValueKey(1),
            onDone: () => Navigator.of(context).pushReplacement(
              PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => const HomeScreen(firstVisit: true),
                transitionsBuilder: (_, a, _, child) =>
                    FadeTransition(opacity: a, child: child),
              ),
            ),
          ),
  );
}

/// The start screen: control a rig, or join one as a camera.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.firstVisit = false});
  final bool firstVisit;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RecentRig> _recent = const [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterStart());
    UpdateNotifications.openedFromNotification.addListener(_checkUpdates);
  }

  @override
  void dispose() {
    UpdateNotifications.openedFromNotification.removeListener(_checkUpdates);
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final r = await RecentRigs.load();
    if (mounted) setState(() => _recent = r);
  }

  Future<void> _afterStart() async {
    await _askForNotifications();
    await _checkUpdates();
  }

  /// Once, after the tour: explain why, then ask for notification permission
  /// and start background update checks.
  Future<void> _askForNotifications() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('notify.asked') ?? false) && mounted) {
      await prefs.setBool('notify.asked', true);
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const IconBadge(Icons.notifications_active_rounded, size: 56),
          title: const Text('Hear about new versions?'),
          content: const Text(
            'SyncCam can let you know when an update is ready, even when the app is closed. '
            'No other notifications.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, notify me'),
            ),
          ],
        ),
      );
      if (yes == true) await UpdateNotifications.requestPermission();
    }
    try {
      await BackgroundUpdates.schedule();
    } catch (_) {}
  }

  Future<void> _checkUpdates() async {
    final fromNotification = UpdateNotifications.openedFromNotification.value;
    final r = await UpdateChecker.check(
      force: fromNotification,
      includeSkipped: fromNotification,
    );
    UpdateNotifications.openedFromNotification.value = false;
    if (r != null && mounted) await showUpdateDialog(context, r);
  }

  Future<void> _openRig(String name, bool asCamera) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host.session', name);
    await prefs.setBool('host.asCamera', asCamera);
    final library = await TakeLibrary.open();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HostScreen(
          sessionName: name,
          hostIsCamera: asCamera,
          library: library,
        ),
      ),
    );
    _loadRecent();
  }

  Future<void> _controlRig() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final nameCtl = TextEditingController(
      text: prefs.getString('host.session') ?? 'My rig',
    );
    var asCamera = prefs.getBool('host.asCamera') ?? false;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Control a rig', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'This phone will see and control every camera.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtl,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name of the rig'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('This phone films too'),
                subtitle: const Text('Use this phone as one of the cameras'),
                value: asCamera,
                onChanged: (v) => set(() => asCamera = v),
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'Start',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    await _openRig(
      nameCtl.text.trim().isEmpty ? 'My rig' : nameCtl.text.trim(),
      asCamera,
    );
  }

  Future<void> _gallery() async {
    final library = await TakeLibrary.open();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => GalleryScreen(library: library)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = context.sync;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth > 700;
            final cards = [
              _BigChoice(
                icon: Icons.grid_view_rounded,
                title: 'Control a rig',
                subtitle: 'This phone sees and controls every camera',
                primary: true,
                onTap: _controlRig,
              ),
              _BigChoice(
                icon: Icons.qr_code_scanner_rounded,
                title: 'Join as a camera',
                subtitle: 'Scan a code from the controlling phone',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const JoinScreen()),
                ),
              ),
            ];
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Row(
                  children: [
                    const AppLogo(size: 36),
                    const SizedBox(width: 10),
                    Text('SyncCam', style: tt.titleLarge),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Help',
                      icon: const Icon(Icons.help_outline_rounded),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const HelpScreen(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(),
                            body: const SettingsTab(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'Many cameras.\nOne shutter.',
                  style: tt.displaySmall?.copyWith(fontSize: 36, height: 1.1),
                ),
                const SizedBox(height: 10),
                Text(
                  'Shoot every angle at exactly the same moment.',
                  style: tt.bodyLarge?.copyWith(color: t.muted),
                ),
                const SizedBox(height: 28),
                if (wide)
                  Row(
                    children: [
                      Expanded(child: cards[0]),
                      const SizedBox(width: 12),
                      Expanded(child: cards[1]),
                    ],
                  )
                else ...[
                  cards[0],
                  const SizedBox(height: 12),
                  cards[1],
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_rounded, size: 14, color: t.muted),
                    const SizedBox(width: 6),
                    Text(
                      'No account. Nothing leaves your devices.',
                      style: tt.bodySmall,
                    ),
                  ],
                ),
                if (_recent.isNotEmpty) ...[
                  const SectionTitle('Recent rigs'),
                  for (final r in _recent)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlassCard(
                        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        onTap: () => _openRig(r.name, r.hostIsCamera),
                        child: Row(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (
                                  var i = 0;
                                  i < r.cameras.length.clamp(0, 4);
                                  i++
                                )
                                  Container(
                                    width: 8,
                                    height: 24,
                                    margin: const EdgeInsets.only(right: 3),
                                    decoration: BoxDecoration(
                                      color: CameraColors.forSlot(i),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.name, style: tt.titleMedium),
                                  Text(
                                    '${r.cameras.length} camera${r.cameras.length == 1 ? '' : 's'} · ${r.cameras.take(3).join(', ')}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tt.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (_) async {
                                await RecentRigs.forget(r.name);
                                _loadRecent();
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'forget',
                                  child: Text('Remove from list'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  onTap: _gallery,
                  child: Row(
                    children: [
                      Icon(Icons.photo_library_rounded, color: t.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Gallery', style: tt.titleMedium)),
                      Icon(Icons.chevron_right_rounded, color: t.muted),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Version ${AppVersion.current}',
                  textAlign: TextAlign.center,
                  style: mono(size: 12, color: t.muted),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One of the two big start choices, as a glass card.
class _BigChoice extends StatelessWidget {
  const _BigChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return GlassCard(
      highlight: primary ? t.accent : null,
      padding: const EdgeInsets.all(20),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: primary ? t.accent : t.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 28, color: primary ? t.onAccent : t.accent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontSize: 20),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_rounded, color: t.muted),
        ],
      ),
    );
  }
}
