import 'package:flutter/material.dart';

import 'host_server.dart';
import 'take.dart';
import 'take_screen.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.library, this.server});
  final TakeLibrary library;

  /// The live session, when opened from the host. Null from the home screen.
  final HostServer? server;

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
        listenable: library,
        builder: (context, _) {
          if (library.takes.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No takes on this phone yet.\n\nTakes are collected on the phone that hosts the session. '
                  'Photos and videos this phone captured as a camera are in your Photos app, in the SyncCam album.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: library.takes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = library.takes[i];
              final spread = t.spreadMs(0);
              return ListTile(
                leading: _thumb(t),
                title: Text(t.label.isNotEmpty ? t.label : '${t.kind[0].toUpperCase()}${t.kind.substring(1)} · ${_time(t.createdAt)}'),
                subtitle: Text('${t.devices.length} cameras · ${t.receivedFiles}/${t.items.length} files received'
                    '${t.shots > 1 ? ' · ${t.shots} shots' : ''}'
                    '${spread != null ? ' · spread ${spread.toStringAsFixed(1)} ms' : ''}'),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => TakeScreen(library: library, server: server, take: t))),
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
