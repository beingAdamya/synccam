import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'external_camera.dart';
import 'host_server.dart';

/// Connect a dedicated camera (any brand) that can lead the rig: its own
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
    await server.setExternal(
      ExternalConfig(
        kind: _kind,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? _kind.defaultPort,
        https: _https,
        user: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera link')),
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
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Camera', border: OutlineInputBorder()),
                items: [
                  for (final k in _ordered)
                    DropdownMenuItem(
                      value: k,
                      child: Text('${k.brand} · ${k.label}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (k) => _pickKind(k!),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _cap(_kind.canLead, 'Its REC button starts the phones'),
                  _cap(_kind.canControl, 'SyncCam starts the camera'),
                  _cap(true, 'Frame-aligned by sound'),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${_kind.setupHint}\n\n${_kind.maturity}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              if (_kind.needsConnection) ...[
                Row(
                  children: [
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
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Login (GoPro Home Network, Theta client mode, Canon/Blackmagic HTTPS)'),
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('HTTPS'),
                      value: _https,
                      onChanged: (v) => setState(() => _https = v),
                    ),
                    TextField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: 'User'),
                    ),
                    TextField(
                      controller: _pass,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.link),
                label: Text(
                  !_kind.needsConnection
                      ? 'Use sync by sound'
                      : cam == null
                      ? 'Connect'
                      : 'Reconnect with these settings',
                ),
              ),
              if (cam != null && cam.config.kind.needsConnection)
                TextButton.icon(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _LogScreen(camera: cam))),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Connection log'),
                ),
              const SizedBox(height: 8),
              if (cam == null || cam.config.kind.canLead)
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
                'Camera not listed or no Wi-Fi? Choose "Any camera: sync by sound". Every camera with a '
                'microphone can be lined up with the phones to the frame afterwards.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Brands in a friendly order; "any camera" last.
  static final List<ExternalKind> _ordered = [...ExternalKind.values]
    ..sort((a, b) {
      if (a == ExternalKind.sound) return 1;
      if (b == ExternalKind.sound) return -1;
      if (a == ExternalKind.ptp) return 1;
      if (b == ExternalKind.ptp) return -1;
      return a.brand.compareTo(b.brand);
    });

  Widget _cap(bool yes, String text) => Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(
      yes ? Icons.check_circle : Icons.remove_circle_outline,
      size: 16,
      color: yes ? Colors.greenAccent : Colors.white38,
    ),
    label: Text(text, style: TextStyle(fontSize: 12, color: yes ? null : Colors.white38)),
  );

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
    final color = !cam.connected
        ? Colors.redAccent
        : cam.recording
        ? Colors.red
        : Colors.greenAccent;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(cam.recording ? Icons.fiber_manual_record : Icons.videocam, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${cam.model ?? cam.config.kind.label} · '
                  '${!cam.connected
                      ? 'not connected'
                      : cam.recording
                      ? 'recording'
                      : server.externalLeads
                      ? 'leads the rig'
                      : 'connected'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every request and answer exchanged with the camera, to diagnose a camera
/// that doesn't behave. "Copy" puts it on the clipboard to send to support.
class _LogScreen extends StatelessWidget {
  const _LogScreen({required this.camera});
  final ExternalCamera camera;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: camera.log.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: camera,
        builder: (context, _) => ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: camera.log.length,
          reverse: true,
          itemBuilder: (_, i) => Text(
            camera.log[camera.log.length - 1 - i],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ),
    );
  }
}
