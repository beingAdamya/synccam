import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/util.dart';
import 'device_tile.dart';
import 'host_server.dart';

/// Full-screen live view of one camera with per-device controls.
///
/// Changes made here are stored as overrides for this device only; the
/// global controls keep driving everything else.
class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({super.key, required this.server, required this.device});
  final HostServer server;
  final RemoteDevice device;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  Offset? _tapMark;
  bool _focusAll = false;

  HostServer get server => widget.server;
  RemoteDevice get d => widget.device;

  @override
  void initState() {
    super.initState();
    server.setFocused(d.id);
  }

  @override
  void dispose() {
    server.setFocused(null);
    super.dispose();
  }

  CameraSettings get _effective => server.global.merged(d.override);

  /// Converts a tap on the (possibly host-rotated) view back to the device's
  /// own preview coordinates.
  Offset _unrotate(double u, double v) => switch (d.viewTurns) {
        1 => Offset(v, 1 - u),
        2 => Offset(1 - u, 1 - v),
        3 => Offset(1 - v, u),
        _ => Offset(u, v),
      };

  Future<void> _rename() async {
    final ctl = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename camera'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) server.rename(d, name);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final s = _effective;
        return Scaffold(
          appBar: AppBar(
            title: Text('#${d.slot + 1} ${d.name}'),
            actions: [
              IconButton(tooltip: 'Identify (flash phone)', icon: const Icon(Icons.flare), onPressed: () => server.identify(d)),
              IconButton(tooltip: 'Rotate view', icon: const Icon(Icons.rotate_90_degrees_cw), onPressed: () => server.rotateView(d)),
              IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit), onPressed: _rename),
            ],
          ),
          body: ListView(
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: LayoutBuilder(builder: (context, c) {
                  return GestureDetector(
                    onTapUp: (e) {
                      final u = e.localPosition.dx / c.maxWidth;
                      final v = e.localPosition.dy / c.maxHeight;
                      final p = _unrotate(u, v);
                      server.focusAt(d, p.dx, p.dy, all: _focusAll);
                      setState(() => _tapMark = e.localPosition);
                    },
                    child: Stack(fit: StackFit.expand, children: [
                      LiveView(device: d, fit: BoxFit.contain),
                      if (_tapMark != null)
                        Positioned(
                          left: _tapMark!.dx - 30,
                          top: _tapMark!.dy - 30,
                          child: Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(border: Border.all(color: Colors.yellowAccent, width: 2)),
                          ),
                        ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Text('${d.liveFps.toStringAsFixed(0)} fps live',
                            style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      ),
                    ]),
                  );
                }),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Tap-to-focus applies to all cameras'),
                value: _focusAll,
                onChanged: (v) => setState(() => _focusAll = v),
              ),
              _section('This camera only'),
              ListTile(
                title: const Text('Lens'),
                trailing: SegmentedButton<LensChoice>(
                  showSelectedIcon: false,
                  segments: [
                    for (final l in LensChoice.values)
                      if (d.lenses.isEmpty || d.lenses.contains(l.name))
                        ButtonSegment(value: l, label: Text(l.name)),
                  ],
                  selected: {s.lens},
                  onSelectionChanged: (v) => server.updateDevice(d, 'lens', v.first.name),
                ),
              ),
              ListTile(
                title: Text('Zoom ${s.zoom.toStringAsFixed(1)}×  (${d.minZoom.toStringAsFixed(1)}–${d.maxZoom.toStringAsFixed(0)}×)'),
                subtitle: Slider(
                  min: d.minZoom,
                  max: d.maxZoom <= d.minZoom ? d.minZoom + 1 : d.maxZoom,
                  value: s.zoom.clamp(d.minZoom, d.maxZoom <= d.minZoom ? d.minZoom + 1 : d.maxZoom),
                  onChanged: (v) => server.updateDevice(d, 'zoom', v),
                ),
              ),
              ListTile(
                title: Text('Exposure ${s.exposureOffset.toStringAsFixed(1)} EV'),
                subtitle: Slider(
                  min: d.minEv < 0 ? d.minEv : -3,
                  max: d.maxEv > 0 ? d.maxEv : 3,
                  value: s.exposureOffset.clamp(d.minEv < 0 ? d.minEv : -3, d.maxEv > 0 ? d.maxEv : 3),
                  onChanged: (v) => server.updateDevice(d, 'exposureOffset', v),
                ),
              ),
              ListTile(
                title: const Text('Flash'),
                trailing: DropdownButton<FlashChoice>(
                  value: s.flash,
                  items: [for (final f in FlashChoice.values) DropdownMenuItem(value: f, child: Text(f.name))],
                  onChanged: (f) => server.updateDevice(d, 'flash', f!.name),
                ),
              ),
              if (d.override.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: Text('Reset to global settings (${d.override.keys.join(', ')})'),
                  onTap: () => server.clearOverrides(d),
                ),
              _section('Timing'),
              ListTile(
                title: Text('Trigger trim: ${d.trimMs.toStringAsFixed(0)} ms'),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Slider(
                    min: -300,
                    max: 300,
                    divisions: 120,
                    value: d.trimMs.clamp(-300, 300),
                    onChanged: (v) => server.setTrim(d, v),
                  ),
                  const Text(
                      'Positive fires this phone earlier, to cancel a slower shutter. '
                      'Use the Sync calibration clock to measure it.',
                      style: TextStyle(fontSize: 12)),
                ]),
              ),
              _section('Device'),
              ListTile(dense: true, title: const Text('Model'), trailing: Text(d.model)),
              ListTile(
                dense: true,
                title: const Text('Clock sync'),
                trailing: Text(d.synced ? '±${d.errMs.toStringAsFixed(2)} ms' : 'syncing'),
              ),
              ListTile(dense: true, title: const Text('Battery'), trailing: Text('${d.battery ?? '?'}%${d.charging ? ' (charging)' : ''}')),
              ListTile(dense: true, title: const Text('Captures'), trailing: Text('${d.captures}')),
              ListTile(
                dense: true,
                title: const Text('Free storage'),
                trailing: Text(d.freeBytes == null ? '?' : formatBytes(d.freeBytes!)),
              ),
              ListTile(
                dense: true,
                title: const Text('Thermal state'),
                trailing: Text('${d.thermal ?? 'unknown'}${d.lowPower ? ' · power saving on' : ''}'),
              ),
              if (d.error != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.warning_amber, color: Colors.orange),
                  title: Text(d.error!),
                ),
              ListTile(
                leading: const Icon(Icons.link_off, color: Colors.redAccent),
                title: const Text('Remove from session'),
                onTap: () {
                  server.removeDevice(d);
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
