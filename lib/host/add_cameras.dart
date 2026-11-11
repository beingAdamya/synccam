import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/protocol.dart';
import '../core/prefs.dart';
import '../ui/cam_status.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_scan.dart';
import 'device_tile.dart';
import 'external_camera.dart';
import 'external_camera_screen.dart';
import 'host_server.dart';

/// Everything about getting cameras into the rig: a big code to scan (with
/// four digits for anyone who can't), the cameras as they arrive, Wi-Fi
/// cameras and sound sync. Drag to set the order; tap a name to rename.
class AddCamerasScreen extends StatefulWidget {
  const AddCamerasScreen({super.key, required this.server});
  final HostServer server;

  @override
  State<AddCamerasScreen> createState() => _AddCamerasScreenState();
}

class _AddCamerasScreenState extends State<AddCamerasScreen> {
  // 0 = phones with the app, 1 = iPhone in the browser, 2 = iPhone offline
  int _mode = 0;

  HostServer get server => widget.server;

  Future<void> _rename(RemoteDevice d) async {
    final c = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Name camera ${d.slot + 1}'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Left wide, Top'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) server.rename(d, name.trim());
  }

  Future<void> _addSound() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.graphic_eq_rounded,
          color: Status.sound,
          size: 36,
        ),
        title: const Text('Add a camera that syncs by sound'),
        content: const Text(
          'Any camera works: it will hear a short tone at the start of each take, and its clip lines up with the others later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add camera'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    server.config.autoSlate = true;
    server.updatePolicy();
    await server.setExternal(
      ExternalConfig(kind: ExternalKind.sound, host: '', port: 0),
      leads: false,
    );
    if (mounted) {
      showSnack(
        context,
        'Sound sync is on. Start recording on that camera before you press the shutter.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return Scaffold(
      appBar: AppBar(title: const Text('Add cameras')),
      body: ListenableBuilder(
        listenable: Listenable.merge([server, server.rtc]),
        builder: (context, _) {
          final devices = server.devices;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.phone_android_rounded),
                    label: Text('App'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.language_rounded),
                    label: Text('iPhone'),
                  ),
                  ButtonSegment(
                    value: 2,
                    icon: Icon(Icons.wifi_off_rounded),
                    label: Text('Offline'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(height: 16),
              _codeCard(t),
              SectionTitle(
                devices.isEmpty
                    ? 'Waiting for cameras…'
                    : 'In this rig · drag to set the order',
                trailing: devices.isEmpty
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              if (devices.isEmpty)
                Text(
                  'Cameras appear here as they join.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: devices.length,
                  onReorderItem: (a, b) {
                    Haptic.tick();
                    server.reorder(a, b);
                  },
                  itemBuilder: (_, i) => _JoinedRow(
                    key: ValueKey(devices[i].id),
                    index: i,
                    device: devices[i],
                    onRename: () => _rename(devices[i]),
                    onIdentify: () => server.identify(devices[i]),
                  ),
                ),
              if (server.external case final cam?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    onTap: cam.config.kind == ExternalKind.sound
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  ExternalCameraScreen(server: server),
                            ),
                          ),
                    child: Row(
                      children: [
                        IconBadge(
                          cam.config.kind == ExternalKind.sound
                              ? Icons.graphic_eq_rounded
                              : Icons.videocam_rounded,
                          color: cam.config.kind == ExternalKind.sound
                              ? Status.sound
                              : t.accent,
                          size: 40,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cam.config.kind == ExternalKind.sound
                                    ? 'Sound sync camera'
                                    : (cam.model ?? cam.config.kind.label),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                cam.config.kind == ExternalKind.sound
                                    ? 'Sound sync · no live control'
                                    : 'Wi-Fi camera',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (cam.config.kind == ExternalKind.sound)
                          const StatusPill(
                            'Sound sync',
                            color: Status.sound,
                            icon: Icons.graphic_eq_rounded,
                          )
                        else if (cam.connected)
                          StatusPill(
                            cam.recording ? 'REC' : 'Ready',
                            color: cam.recording
                                ? Status.recording
                                : Status.ready,
                            icon: cam.recording
                                ? Icons.fiber_manual_record_rounded
                                : Icons.check_circle_rounded,
                          )
                        else
                          const StatusPill(
                            'Lost',
                            color: Status.lost,
                            icon: Icons.link_off_rounded,
                            outlined: true,
                          ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => server.setExternal(null),
                        ),
                      ],
                    ),
                  ),
                ),
              const SectionTitle('Other cameras'),
              ActionCard(
                icon: Icons.wifi_find_rounded,
                title: 'Find Wi-Fi cameras',
                subtitle:
                    'Sony, Canon, Nikon, Fujifilm, Panasonic, GoPro and more',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => FindCamerasScreen(server: server),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ActionCard(
                icon: Icons.graphic_eq_rounded,
                color: Status.sound,
                title: 'Add a camera that syncs by sound',
                subtitle: 'Any camera, no connection needed',
                onTap: _addSound,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _codeCard(SyncTheme t) {
    final ip = server.addresses.isEmpty ? null : server.addresses.first;
    final rtc = server.rtc;
    final (String? qr, String how) = switch (_mode) {
      1 => (
        rtc.ready ? rtc.joinUrl : null,
        'Scan with the iPhone Camera app. It opens in Safari: tap Start camera. Nothing to install.',
      ),
      2 => (
        server.webJoinUrl,
        'For places with no internet. Scan with the iPhone Camera app; a one-time setup step comes first.',
      ),
      _ => (
        ip == null ? null : 'synccam://$ip:${Net.httpPort}',
        'On the other phone, open SyncCam and tap Join as a camera. It finds this rig by itself, or scan this code.',
      ),
    };
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(
            server.sessionName,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(SyncTheme.radius),
            ),
            padding: const EdgeInsets.all(14),
            child: qr != null
                ? QrImageView(data: qr, size: 220, padding: EdgeInsets.zero)
                : SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _mode == 1 ? rtc.status : 'No network yet. Connect to Wi-Fi or turn on this phone\'s hotspot.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ),
                    ),
                  ),
          ),
          if (_mode == 0) ...[
            const SizedBox(height: 16),
            Text(
              'Can\'t scan? Type this code',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              server.rigCode.split('').join(' '),
              style: mono(size: 34, weight: FontWeight.w600, color: t.accent),
            ),
          ],
          if (_mode == 2 && server.webJoinUrl != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              server.webJoinUrl!,
              style: mono(size: 13, color: t.muted),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            how,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            _mode == 1
                ? 'This page only talks to this phone. Internet is used just to say hello.'
                : 'Every camera must be on the same Wi-Fi, or on this phone\'s hotspot.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _JoinedRow extends StatelessWidget {
  const _JoinedRow({
    super.key,
    required this.index,
    required this.device,
    required this.onRename,
    required this.onIdentify,
  });
  final int index;
  final RemoteDevice device;
  final VoidCallback onRename;
  final VoidCallback onIdentify;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final d = device;
        final s = statusOf(d);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GlassCard(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            onLongPress: onIdentify,
            child: Row(
              children: [
                NumberBadge(d.slot, size: 32),
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 58,
                    child: LiveView(device: d, grey: !d.online),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: onRename,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  d.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.edit_rounded,
                                size: 14,
                                color: context.sync.muted,
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              d.kind,
                              if (d.battery != null) '${d.battery}%',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                StatusPill(
                  s.word,
                  color: s.color,
                  icon: s.icon,
                  outlined: s.state == CamState.lost,
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.drag_indicator_rounded),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
