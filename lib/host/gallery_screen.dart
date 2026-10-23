import 'package:flutter/material.dart';

import 'host_server.dart';
import 'take.dart';
import 'take_screen.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.server});
  final HostServer server;

  static IconData iconFor(String kind) => switch (kind) {
        'video' => Icons.videocam,
        'burst' => Icons.burst_mode,
        'interval' => Icons.timelapse,
        _ => Icons.photo_camera,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Takes')),
      body: ListenableBuilder(
        listenable: server,
        builder: (context, _) {
          if (server.takes.isEmpty) {
            return const Center(child: Text('No takes yet. Press the shutter to capture on every camera.'));
          }
          return ListView.separated(
            itemCount: server.takes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = server.takes[i];
              final spread = t.spreadMs(0);
              return ListTile(
                leading: _thumb(t),
                title: Text(t.label.isNotEmpty ? t.label : '${t.kind[0].toUpperCase()}${t.kind.substring(1)} · ${_time(t.createdAt)}'),
                subtitle: Text('${t.devices.length} cameras · ${t.receivedFiles}/${t.items.length} files received'
                    '${t.shots > 1 ? ' · ${t.shots} shots' : ''}'
                    '${spread != null ? ' · spread ${spread.toStringAsFixed(1)} ms' : ''}'),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => TakeScreen(server: server, take: t))),
              );
            },
          );
        },
      ),
    );
  }

  Widget _thumb(Take t) {
    for (final it in t.items) {
      final f = t.fileFor(it);
      if (it.kind == 'photo' && f != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(f, width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 96),
        );
      }
    }
    return SizedBox(width: 48, height: 48, child: Icon(iconFor(t.kind)));
  }

  static String _time(DateTime d) =>
      '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
}
