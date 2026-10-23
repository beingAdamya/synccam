import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'host/host_screen.dart';
import 'node/join_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Session name')),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use this phone as a camera too'),
              value: asCamera,
              onChanged: (v) => set(() => asCamera = v),
            ),
          ]),
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
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => HostScreen(sessionName: name, hostIsCamera: asCamera)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const JoinScreen())),
              ),
              const SizedBox(height: 24),
            ],
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
          child: Row(children: [
            Icon(icon, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                Text(subtitle, style: const TextStyle(color: Colors.white60)),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
