import 'package:flutter/material.dart';

import '../core/protocol.dart';
import 'host_server.dart';

class HostSettingsScreen extends StatefulWidget {
  const HostSettingsScreen({super.key, required this.server});
  final HostServer server;

  @override
  State<HostSettingsScreen> createState() => _HostSettingsScreenState();
}

class _HostSettingsScreenState extends State<HostSettingsScreen> {
  HostServer get server => widget.server;
  CaptureConfig get cfg => server.config;

  void _cfg(void Function() f) {
    setState(f);
    server.updatePolicy();
  }

  void _global(void Function(CameraSettings s) f) {
    server.updateGlobal(f);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final g = server.global;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _h('Synchronization'),
          ListTile(
            title: Text('Prep time before each shot: ${cfg.leadMs} ms'),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Slider(
                min: 300,
                max: 3000,
                divisions: 27,
                value: cfg.leadMs.toDouble(),
                onChanged: (v) => _cfg(() => cfg.leadMs = v.round()),
              ),
              const Text(
                  'How long the cameras get to prepare after you press the shutter. Raise it if some cameras '
                  'miss shots on a busy or weak Wi-Fi.',
                  style: TextStyle(fontSize: 12)),
            ]),
          ),
          ListTile(
            title: Text('Sweep delay between cameras: ${cfg.staggerMs} ms'),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Slider(
                min: 0,
                max: 500,
                divisions: 100,
                value: cfg.staggerMs.toDouble(),
                onChanged: (v) => _cfg(() => cfg.staggerMs = v.round()),
              ),
              const Text(
                  '0 = every camera shoots at the same instant (frozen moment). Above 0, they shoot one after '
                  'another in camera order, for a "bullet time" sweep.',
                  style: TextStyle(fontSize: 12)),
            ]),
          ),
          SwitchListTile(
            title: const Text('Sync beep when recording starts'),
            subtitle: const Text('A short beep every camera hears, so videos can be lined up perfectly later'),
            value: cfg.autoSlate,
            onChanged: (v) => _cfg(() => cfg.autoSlate = v),
          ),
          _h('Burst & time-lapse'),
          ListTile(
            title: Text('Burst: ${cfg.burstCount} shots every ${cfg.burstIntervalMs} ms'),
            subtitle: Row(children: [
              Expanded(
                child: Slider(
                  min: 2,
                  max: 20,
                  divisions: 18,
                  value: cfg.burstCount.toDouble(),
                  onChanged: (v) => _cfg(() => cfg.burstCount = v.round()),
                ),
              ),
              Expanded(
                child: Slider(
                  min: 200,
                  max: 2000,
                  divisions: 18,
                  value: cfg.burstIntervalMs.toDouble(),
                  onChanged: (v) => _cfg(() => cfg.burstIntervalMs = v.round()),
                ),
              ),
            ]),
          ),
          ListTile(
            title: Text('Time-lapse interval: ${cfg.intervalSec} s'),
            subtitle: Slider(
              min: 1,
              max: 60,
              divisions: 59,
              value: cfg.intervalSec.toDouble(),
              onChanged: (v) => _cfg(() => cfg.intervalSec = v.round()),
            ),
          ),
          _h('Media'),
          SwitchListTile(
            title: const Text('Collect everything on this phone'),
            subtitle: const Text('Every camera sends its photos and videos here, sorted by shot'),
            value: cfg.autoUpload,
            onChanged: (v) => _cfg(() => cfg.autoUpload = v),
          ),
          SwitchListTile(
            title: const Text('Keep a copy on each camera'),
            subtitle: const Text('Saved to the phone\'s gallery in a "SyncCam" album'),
            value: cfg.keepCopyOnDevice,
            onChanged: (v) => _cfg(() => cfg.keepCopyOnDevice = v),
          ),
          _h('Camera (all devices)'),
          ListTile(
            title: const Text('Frame rate'),
            trailing: DropdownButton<int?>(
              value: g.fps,
              items: const [
                DropdownMenuItem(value: null, child: Text('Auto')),
                DropdownMenuItem(value: 24, child: Text('24')),
                DropdownMenuItem(value: 25, child: Text('25')),
                DropdownMenuItem(value: 30, child: Text('30')),
                DropdownMenuItem(value: 60, child: Text('60')),
              ],
              onChanged: (v) => _global((s) => s.fps = v),
            ),
          ),
          ListTile(
            title: const Text('Lock orientation'),
            trailing: DropdownButton<OrientationLock>(
              value: g.orientation,
              items: [for (final o in OrientationLock.values) DropdownMenuItem(value: o, child: Text(o.name))],
              onChanged: (v) => _global((s) => s.orientation = v!),
            ),
          ),
          SwitchListTile(
            title: const Text('Video stabilization'),
            subtitle: const Text('Smoother handheld video; off keeps timing tightest'),
            value: g.stabilization,
            onChanged: (v) => _global((s) => s.stabilization = v),
          ),
          ListTile(
            title: Text('Photo quality: ${g.jpegQuality}'),
            subtitle: Slider(
              min: 50,
              max: 100,
              divisions: 50,
              value: g.jpegQuality.toDouble(),
              onChanged: (v) => _global((s) => s.jpegQuality = v.round()),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
