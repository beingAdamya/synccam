import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/protocol.dart';
import '../core/updates.dart';
import '../ui/guides.dart';
import '../ui/theme.dart';
import '../ui/update_dialog.dart';
import '../ui/widgets.dart';
import 'calibration_screen.dart';
import 'host_server.dart';

/// Settings: the look, how the app feels, rig defaults (when a shoot is
/// running), help, updates and privacy.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, this.server, this.onEnd});

  /// The running shoot, or null when opened from the start screen.
  final HostServer? server;
  final VoidCallback? onEnd;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _checking = false;

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    final r = await UpdateChecker.check(
      force: true,
      includeSkipped: true,
    ).catchError((_) => null);
    if (!mounted) return;
    setState(() => _checking = false);
    if (r == null) {
      showSnack(
        context,
        'You have the latest version (${AppVersion.current}).',
      );
    } else {
      await showUpdateDialog(context, r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final top = MediaQuery.of(context).padding.top;
    return ListenableBuilder(
      listenable: Listenable.merge([AppPrefs.theme, ?server]),
      builder: (context, _) {
        final t = context.sync;
        return ListView(
          padding: EdgeInsets.fromLTRB(16, top + 12, 16, 24),
          children: [
            Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
            const SectionTitle('Look'),
            GlassCard(
              padding: const EdgeInsets.all(8),
              child: RadioGroup<ThemeChoice>(
                groupValue: AppPrefs.theme.value,
                onChanged: (v) {
                  if (v != null) AppPrefs.setTheme(v);
                },
                child: Column(
                  children: [
                    for (final c in ThemeChoice.values)
                      RadioListTile<ThemeChoice>(
                        value: c,
                        title: Text(c.label),
                        subtitle: Text(switch (c) {
                          ThemeChoice.studio =>
                            'Dark and calm. Best for judging video.',
                          ThemeChoice.daylight =>
                            'Light gallery and setup. Live video stays dark.',
                          ThemeChoice.highContrast => 'Pure black, white text and thicker outlines for bright sun.',
                        }, style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
            const SectionTitle('Feel'),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SwitchListTile(
                title: const Text('Vibration'),
                subtitle: Text(
                  'A tap on the shutter, a double tap when every camera is ready',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: AppPrefs.haptics,
                onChanged: (v) => setState(() => AppPrefs.setHaptics(v)),
              ),
            ),
            if (server != null) ..._rig(server),
            const SectionTitle('Help'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.menu_book_rounded),
                    title: const Text('Guides'),
                    subtitle: const Text(
                      'Adding cameras, iPhones, Wi-Fi cameras and more',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const HelpScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.system_update_rounded),
                    title: const Text('Check for updates'),
                    subtitle: Text(
                      'Version ${AppVersion.current}',
                      style: mono(size: 12, color: t.muted),
                    ),
                    trailing: _checking
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: _checking ? null : _checkUpdates,
                  ),
                ],
              ),
            ),
            const SectionTitle('Privacy'),
            GlassCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_rounded, color: t.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No account. Nothing leaves your devices. Photos and videos go only between your own phones '
                      'and cameras on your Wi-Fi. SyncCam collects no analytics and no crash data. The only internet '
                      'it uses is to check for updates, and to say hello when an iPhone joins without the app.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            if (server != null && widget.onEnd != null) ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Status.recording,
                  side: const BorderSide(color: Status.recording),
                ),
                onPressed: widget.onEnd,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('End shoot'),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _rig(HostServer server) {
    final cfg = server.config;
    final g = server.global;
    void policy(void Function() f) {
      f();
      server.updatePolicy();
    }

    return [
      const SectionTitle('This shoot'),
      GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Copy everything to this phone'),
              subtitle: Text(
                'Every camera sends its photos and videos here, sorted by take',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: cfg.autoUpload,
              onChanged: (v) => policy(() => cfg.autoUpload = v),
            ),
            SwitchListTile(
              title: const Text('Keep a copy on each camera'),
              subtitle: Text(
                'Saved in the camera phone\'s Photos, in a SyncCam album',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: cfg.keepCopyOnDevice,
              onChanged: (v) => policy(() => cfg.keepCopyOnDevice = v),
            ),
            ListTile(
              title: const Text('Hold the picture steady'),
              subtitle: Text(
                'Lock which way photos and videos are saved',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: DropdownButton<OrientationLock>(
                value: g.orientation,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(
                    value: OrientationLock.auto,
                    child: Text('Auto'),
                  ),
                  DropdownMenuItem(
                    value: OrientationLock.portrait,
                    child: Text('Portrait'),
                  ),
                  DropdownMenuItem(
                    value: OrientationLock.landscape,
                    child: Text('Landscape'),
                  ),
                ],
                onChanged: (v) =>
                    server.updateGlobal((s) => s.orientation = v!),
              ),
            ),
            ListTile(
              title: const Text('Photo quality'),
              subtitle: Slider(
                min: 50,
                max: 100,
                divisions: 50,
                value: g.jpegQuality.toDouble(),
                label: '${g.jpegQuality}',
                onChanged: (v) =>
                    server.updateGlobal((s) => s.jpegQuality = v.round()),
              ),
              trailing: Text('${g.jpegQuality}', style: mono(size: 13)),
            ),
          ],
        ),
      ),
      const SectionTitle('Timing'),
      GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          children: [
            ListTile(
              title: const Text('Prep time before each shot'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Slider(
                    min: 300,
                    max: 3000,
                    divisions: 27,
                    value: cfg.leadMs.toDouble(),
                    onChanged: (v) => policy(() => cfg.leadMs = v.round()),
                  ),
                  Text(
                    'Raise it if some cameras miss shots on slow Wi-Fi.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              trailing: Text('${cfg.leadMs} ms', style: mono(size: 13)),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Fine-tune timing'),
              subtitle: Text(
                'Measure and correct each camera\'s delay',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CalibrationScreen(server: server),
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }
}
