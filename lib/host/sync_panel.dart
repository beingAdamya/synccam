import 'package:flutter/material.dart';

import 'calibration_screen.dart';
import 'host_server.dart';

Color syncColor(RemoteDevice d) {
  if (!d.online) return Colors.redAccent;
  if (!d.synced) return Colors.amber;
  return d.errMs < 5 ? Colors.greenAccent : d.errMs < 15 ? Colors.amber : Colors.redAccent;
}

/// One-glance answer to "are my cameras in sync?", shown in the host title
/// bar. Tap for the per-camera breakdown.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key, required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    final online = server.onlineDevices;
    final synced = online.where((d) => d.synced && d.errMs < 15).toList();
    final worst = synced.fold<double>(0, (a, d) => d.errMs > a ? d.errMs : a);
    final (IconData icon, Color color, String text) = online.isEmpty
        ? (Icons.sync_disabled, Colors.white54, 'No cameras yet')
        : synced.length == online.length
            ? (
                Icons.check_circle,
                Colors.greenAccent,
                'All ${online.length} in sync · ±${worst.toStringAsFixed(1)} ms · ${HostServer.syncQuality(worst)}'
              )
            : (Icons.sync_problem, Colors.amber, '${synced.length} of ${online.length} in sync · tap for details');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SyncSheet(server: server),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

class SyncSheet extends StatelessWidget {
  const SyncSheet({super.key, required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final list = server.devices;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Clock sync', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                'Every camera keeps matching its clock to this host. ±ms is the worst-case clock '
                'error, so each camera fires within about that much of the shared trigger instant.',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No cameras connected.')),
              for (final d in list)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle, size: 12, color: syncColor(d)),
                  title: Text('#${d.slot + 1} ${d.name}'),
                  trailing: Text(
                    !d.online
                        ? 'Offline'
                        : !d.synced
                            ? 'Syncing…'
                            : '±${d.errMs.toStringAsFixed(1)} ms · ${HostServer.syncQuality(d.errMs)}',
                    style: TextStyle(color: syncColor(d), fontWeight: FontWeight.w600),
                  ),
                ),
              const Divider(),
              const Text(
                'Excellent < 2 ms · Good < 5 ms · Fair < 15 ms. Camera hardware adds its own '
                'shutter delay on top of this; the calibration clock measures and removes it.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.timer_outlined),
                  label: const Text('Open calibration clock'),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                        context, MaterialPageRoute<void>(builder: (_) => CalibrationScreen(server: server)));
                  },
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
