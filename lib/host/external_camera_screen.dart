import 'package:flutter/material.dart';

import 'external_camera.dart';
import 'host_server.dart';

/// Connect a Wi-Fi camera (GoPro, Canon, Lumix) that leads the rig: its own
/// record button starts and stops every phone.
class ExternalCameraScreen extends StatefulWidget {
  const ExternalCameraScreen({super.key, required this.server});
  final HostServer server;

  @override
  State<ExternalCameraScreen> createState() => _ExternalCameraScreenState();
}

class _ExternalCameraScreenState extends State<ExternalCameraScreen> {
  late ExternalKind _kind;
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _https = false;

  HostServer get server => widget.server;

  @override
  void initState() {
    super.initState();
    final c = server.external?.config;
    _kind = c?.kind ?? ExternalKind.gopro;
    _host.text = c?.host ?? _kind.defaultHost;
    _port.text = '${c?.port ?? _kind.defaultPort}';
    _user.text = c?.user ?? '';
    _pass.text = c?.password ?? '';
    _https = c?.https ?? false;
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _pickKind(ExternalKind k) => setState(() {
        _kind = k;
        _host.text = k.defaultHost;
        _port.text = '${k.defaultPort}';
      });

  Future<void> _connect() async {
    await server.setExternal(ExternalConfig(
      kind: _kind,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? _kind.defaultPort,
      https: _https,
      user: _user.text.trim(),
      password: _pass.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi camera')),
      body: ListenableBuilder(
        listenable: server,
        builder: (context, _) {
          final cam = server.external;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Connect a camera with Wi-Fi. Start recording on the camera and every phone in the session '
                '(app or browser) starts too; stop it and they all stop. Recording from SyncCam also starts the camera.',
              ),
              const SizedBox(height: 16),
              if (cam != null) _status(cam),
              const SizedBox(height: 8),
              DropdownButtonFormField<ExternalKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Camera', border: OutlineInputBorder()),
                items: [for (final k in ExternalKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
                onChanged: (k) => _pickKind(k!),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_kind.setupHint, style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Camera IP', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                  ),
                ),
              ]),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Login (GoPro Home Network, Canon with password)'),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('HTTPS'),
                    value: _https,
                    onChanged: (v) => setState(() => _https = v),
                  ),
                  TextField(controller: _user, decoration: const InputDecoration(labelText: 'User')),
                  TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                  const SizedBox(height: 8),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.link),
                label: Text(cam == null ? 'Connect' : 'Reconnect with these settings'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Camera leads the phones'),
                subtitle: const Text('Its record button starts and stops every phone'),
                value: server.externalLeads,
                onChanged: server.setExternalLeads,
              ),
              if (cam != null)
                TextButton.icon(
                  onPressed: () => server.setExternal(null),
                  icon: const Icon(Icons.link_off, color: Colors.redAccent),
                  label: const Text('Disconnect camera', style: TextStyle(color: Colors.redAccent)),
                ),
              const Divider(height: 32),
              const Text(
                'Timing: SyncCam sees the camera start within about 0.1–0.3 s and starts the phones ~0.35 s later, '
                'on the shared clock. The auto slate (beep) is recorded by the camera\'s microphone too, so '
                'tools/align_clips.py --extra camera_file.mp4 lines the camera\'s clip up with the phones exactly.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 8),
              const Text(
                'Not supported over Wi-Fi yet: Nikon, Sony and Fujifilm, which use PTP/IP or desktop SDKs.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _status(ExternalCamera cam) {
    final (color, text) = !cam.connected
        ? (Colors.redAccent, cam.error ?? 'Connecting…')
        : cam.recording
            ? (Colors.red, '● Recording')
            : (Colors.greenAccent, 'Connected · ready');
    return Card(
      child: ListTile(
        leading: Icon(Icons.videocam, color: color),
        title: Text(cam.model ?? cam.config.kind.label),
        subtitle: Text('$text${cam.connected ? ' · ${cam.lastRoundTripMs} ms' : ''}'),
        trailing: cam.connected
            ? FilledButton.tonal(
                onPressed: () => cam.recording ? server.stopVideo() : server.startVideo(),
                child: Text(cam.recording ? 'Stop all' : 'Record all'),
              )
            : null,
      ),
    );
  }
}

/// Compact status strip for the host dashboard.
class ExternalCameraStrip extends StatelessWidget {
  const ExternalCameraStrip({super.key, required this.server, required this.onTap});
  final HostServer server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cam = server.external;
    if (cam == null) return const SizedBox.shrink();
    final color = !cam.connected ? Colors.redAccent : cam.recording ? Colors.red : Colors.greenAccent;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Icon(cam.recording ? Icons.fiber_manual_record : Icons.videocam, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${cam.model ?? cam.config.kind.label} · '
                '${!cam.connected ? 'not connected' : cam.recording ? 'recording' : server.externalLeads ? 'leads the rig' : 'connected'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ]),
        ),
      ),
    );
  }
}
