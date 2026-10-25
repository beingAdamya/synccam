import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/updates.dart';
import 'host/gallery_screen.dart';
import 'host/host_screen.dart';
import 'host/take.dart';
import 'node/join_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppVersion.load();
  runApp(const SyncCamApp());
}

class SyncCamApp extends StatelessWidget {
  const SyncCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncCam',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.redAccent, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ReleaseInfo? _update;

  @override
  void initState() {
    super.initState();
    UpdateChecker.check().then((r) {
      if (mounted) setState(() => _update = r);
    });
  }

  Future<void> _host(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    final nameCtl = TextEditingController(text: prefs.getString('host.session') ?? 'SyncCam Session');
    var asCamera = prefs.getBool('host.asCamera') ?? false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Host a session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Session name'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use this phone as a camera too'),
                value: asCamera,
                onChanged: (v) => set(() => asCamera = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
          ],
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    final name = nameCtl.text.trim().isEmpty ? 'SyncCam Session' : nameCtl.text.trim();
    await prefs.setString('host.session', name);
    await prefs.setBool('host.asCamera', asCamera);
    final library = await TakeLibrary.open();
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HostScreen(sessionName: name, hostIsCamera: asCamera, library: library),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        // Scrolls on short screens; otherwise fills the height so the
        // spacers keep the layout centred.
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_update case final u?)
                        _UpdateBanner(release: u, onClose: () => setState(() => _update = null)),
                      const Spacer(),
                      const Icon(Icons.camera, size: 72, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      Text('SyncCam', textAlign: TextAlign.center, style: t.displaySmall),
                      const SizedBox(height: 8),
                      Text(
                        'Many phones. One shutter. Frame-synced photos and video from every angle.',
                        textAlign: TextAlign.center,
                        style: t.bodyLarge?.copyWith(color: Colors.white70),
                      ),
                      const Spacer(),
                      _BigButton(
                        icon: Icons.dashboard_customize,
                        title: 'Host a session',
                        subtitle: 'Control every camera, see all live views, trigger in sync',
                        onTap: () => _host(context),
                      ),
                      const SizedBox(height: 12),
                      _BigButton(
                        icon: Icons.videocam,
                        title: 'Join as camera',
                        subtitle: 'Let a host control this phone\'s camera',
                        onTap: () =>
                            Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const JoinScreen())),
                      ),
                      const SizedBox(height: 12),
                      _BigButton(
                        icon: Icons.photo_library_outlined,
                        title: 'Gallery',
                        subtitle: 'Takes from sessions this phone hosted',
                        onTap: () async {
                          final library = await TakeLibrary.open();
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(builder: (_) => GalleryScreen(library: library)),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'v${AppVersion.current}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    Text(subtitle, style: const TextStyle(color: Colors.white60)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// "A new version is available" card. Android downloads the APK in the
/// browser (Android then offers to install it over the current app); iOS
/// opens the release page, since iPhone builds have to be signed separately.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.release, required this.onClose});
  final ReleaseInfo release;
  final VoidCallback onClose;

  Future<void> _open(BuildContext context) async {
    final url = Platform.isAndroid ? (release.apkUrl ?? release.pageUrl) : release.pageUrl;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  void _notes(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(release.name),
        content: SingleChildScrollView(child: Text(release.notes.isEmpty ? 'No release notes.' : release.notes)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update, color: scheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'SyncCam ${release.version} is available (you have ${AppVersion.current})',
                    style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(onPressed: () => _notes(context), child: const Text("What's new")),
                TextButton(
                  onPressed: () {
                    UpdateChecker.skip(release);
                    onClose();
                  },
                  child: const Text('Skip version'),
                ),
                FilledButton(
                  onPressed: () => _open(context),
                  child: Text(Platform.isAndroid ? 'Download update' : 'View release'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
