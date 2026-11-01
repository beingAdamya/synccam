import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/update_service.dart';
import 'core/updates.dart';
import 'host/gallery_screen.dart';
import 'host/host_screen.dart';
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
    return MaterialApp(
      title: 'SyncCam',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildTheme(),
      theme: buildTheme(),
      // One backdrop behind every screen; camera screens paint their own black.
      builder: (context, child) => AppBackground(child: child!),
      home: onboarded ? const HomeScreen() : const _FirstRun(),
    );
  }
}

class _FirstRun extends StatelessWidget {
  const _FirstRun();
  @override
  Widget build(BuildContext context) => OnboardingScreen(
        onDone: () => Navigator.of(context).pushReplacement(
          PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const HomeScreen(firstVisit: true),
            transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
          ),
        ),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.firstVisit = false});
  final bool firstVisit;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterStart());
    UpdateNotifications.openedFromNotification.addListener(_checkUpdates);
  }

  @override
  void dispose() {
    UpdateNotifications.openedFromNotification.removeListener(_checkUpdates);
    super.dispose();
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
          icon: const IconBadge(Icons.notifications_active_rounded, color: Brand.coral, size: 56),
          title: const Text('Hear about new versions?'),
          content: const Text('SyncCam can let you know when an update is ready, even when the app is closed. '
              'No other notifications.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, notify me')),
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
    final r = await UpdateChecker.check(force: fromNotification, includeSkipped: fromNotification);
    UpdateNotifications.openedFromNotification.value = false;
    if (r != null && mounted) await showUpdateDialog(context, r);
  }

  Future<void> _startShoot() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final nameCtl = TextEditingController(text: prefs.getString('host.session') ?? 'My shoot');
    var asCamera = prefs.getBool('host.asCamera') ?? false;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Start a shoot', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('This phone will control every camera.', style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 20),
            TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Name of the shoot')),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use this phone as a camera too'),
              subtitle: const Text('Film with this phone while it controls the others'),
              value: asCamera,
              onChanged: (v) => set(() => asCamera = v),
            ),
            const SizedBox(height: 12),
            PrimaryButton(label: 'Start', icon: Icons.play_arrow_rounded, onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    if (go != true || !mounted) return;
    final name = nameCtl.text.trim().isEmpty ? 'My shoot' : nameCtl.text.trim();
    await prefs.setString('host.session', name);
    await prefs.setBool('host.asCamera', asCamera);
    final library = await TakeLibrary.open();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => HostScreen(sessionName: name, hostIsCamera: asCamera, library: library)),
    );
  }

  Future<void> _gallery() async {
    final library = await TakeLibrary.open();
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GalleryScreen(library: library)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Row(children: [
              const AppLogo(size: 40),
              const SizedBox(width: 10),
              Text('SyncCam', style: t.titleLarge),
              const Spacer(),
              IconButton(
                tooltip: 'Help & guides',
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const HelpScreen())),
              ),
            ]),
            const SizedBox(height: 24),
            const Center(child: AppLogo(size: 150)),
            const SizedBox(height: 20),
            Text('Many cameras.\nOne shutter.',
                textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontSize: 30, height: 1.15)),
            const SizedBox(height: 10),
            Text('Shoot photos and video from every angle at exactly the same moment.',
                textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Brand.textDim)),
            const SizedBox(height: 28),
            ActionCard(
              icon: Icons.play_arrow_rounded,
              title: 'Start a shoot',
              subtitle: 'Control every camera from this phone',
              highlight: true,
              onTap: _startShoot,
            ),
            const SizedBox(height: 12),
            ActionCard(
              icon: Icons.videocam_rounded,
              color: Brand.sky,
              title: 'Join as a camera',
              subtitle: 'Let another phone control this one',
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const JoinScreen())),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _MiniCard(icon: Icons.photo_library_rounded, label: 'Gallery', onTap: _gallery)),
              const SizedBox(width: 12),
              Expanded(
                child: _MiniCard(
                  icon: Icons.menu_book_rounded,
                  label: 'How it works',
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const HelpScreen())),
                ),
              ),
            ]),
            const SizedBox(height: 28),
            Text('Version ${AppVersion.current}', textAlign: TextAlign.center, style: t.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GlassCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        child: Column(children: [
          Icon(icon, color: Brand.coral, size: 28),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.titleSmall),
        ]),
      );
}
