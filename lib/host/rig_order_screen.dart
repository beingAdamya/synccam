import 'package:flutter/material.dart';

import 'host_server.dart';

/// Drag cameras into their physical left-to-right order. Slot order drives
/// bullet-time stagger and file naming (01_, 02_, …).
class RigOrderScreen extends StatelessWidget {
  const RigOrderScreen({super.key, required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rig order & timing')),
      body: ListenableBuilder(
        listenable: server,
        builder: (context, _) {
          final list = server.devices;
          if (list.isEmpty) return const Center(child: Text('No cameras yet'));
          return ReorderableListView.builder(
            itemCount: list.length,
            onReorderItem: server.reorder,
            itemBuilder: (_, i) {
              final d = list[i];
              final fire = i * server.config.staggerMs - d.trimMs;
              return ListTile(
                key: ValueKey(d.id),
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(d.name),
                subtitle: Text('${d.online ? 'online' : 'offline'} · fires at '
                    '${fire >= 0 ? '+' : ''}${fire.toStringAsFixed(0)} ms · trim ${d.trimMs.toStringAsFixed(0)} ms'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.flare), tooltip: 'Identify', onPressed: () => server.identify(d)),
                  const Icon(Icons.drag_handle),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
