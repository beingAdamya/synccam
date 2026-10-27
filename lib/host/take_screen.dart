import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../core/util.dart';
import 'compare_screen.dart';
import 'host_server.dart';
import 'playback.dart';
import 'take.dart';

/// Every camera's result for one take, side by side, with timing and export.
class TakeScreen extends StatefulWidget {
  const TakeScreen({super.key, required this.library, required this.take, this.server, this.calibrate = false});
  final TakeLibrary library;

  /// The live session; calibration needs it to set per-camera trims.
  final HostServer? server;
  final Take take;
  final bool calibrate;

  @override
  State<TakeScreen> createState() => _TakeScreenState();
}

class _TakeScreenState extends State<TakeScreen> {
  int _shot = 0;
  bool _busy = false;

  Take get take => widget.take;

  List<File> get _files => [
        for (final it in take.items)
          if (take.fileFor(it) case final f? when f.existsSync()) f,
      ];

  Future<void> _saveAll() async {
    setState(() => _busy = true);
    var n = 0;
    try {
      if (await Gal.requestAccess(toAlbum: true)) {
        for (final it in take.items) {
          final f = take.fileFor(it);
          if (f == null || !f.existsSync()) continue;
          it.kind == 'video'
              ? await Gal.putVideo(f.path, album: 'SyncCam')
              : await Gal.putImage(f.path, album: 'SyncCam');
          n++;
        }
      }
    } catch (e) {
      _snack('Save failed: $e');
    }
    setState(() => _busy = false);
    _snack('Saved $n files to Photos');
  }

  Future<void> _share() async {
    final files = [..._files, File('${take.dir.path}/manifest.json')];
    await SharePlus.instance.share(ShareParams(files: [for (final f in files) XFile(f.path)]));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete take?'),
        content: const Text('Files on this host are removed. Copies kept on each camera are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.library.delete(take);
    if (mounted) Navigator.pop(context);
  }

  /// The user reads the calibration clock in each photo. A phone whose photo
  /// shows a later time fired late, so it gets a positive trim (fire earlier)
  /// of the difference from the median.
  Future<void> _calibrate() async {
    final its = take.itemsForShot(_shot);
    final ctls = {for (final it in its) it.deviceId: TextEditingController()};
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clock readings'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Type the time shown in each photo (e.g. 42.318).'),
            for (final it in its)
              TextField(
                controller: ctls[it.deviceId],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: take.device(it.deviceId)?.name ?? it.deviceId),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply trims')),
        ],
      ),
    );
    if (apply != true) return;
    final readings = <String, double>{};
    ctls.forEach((id, c) {
      final v = double.tryParse(c.text.replaceAll(',', '.'));
      if (v != null) readings[id] = v * 1000;
    });
    if (readings.length < 2) return _snack('Enter at least two readings');
    // Unwrap the 60 s rollover relative to the first reading.
    final ref = readings.values.first;
    readings.updateAll((_, v) => v - ref > 30000 ? v - 60000 : (ref - v > 30000 ? v + 60000 : v));
    final sorted = readings.values.toList()..sort();
    final median = sorted[sorted.length ~/ 2];
    final server = widget.server!;
    final devs = {for (final d in server.devices) d.id: d};
    final report = <String>[];
    readings.forEach((id, v) {
      final d = devs[id];
      final dev = take.device(id);
      if (d == null || dev == null) return;
      // Remove intentional stagger before comparing.
      final err = v - median - dev.slot * take.staggerMs;
      server.setTrim(d, d.trimMs + err);
      report.add('${d.name}: ${err >= 0 ? '+' : ''}${err.toStringAsFixed(0)} ms');
    });
    _snack('Trims updated · ${report.join(' · ')}');
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final its = take.itemsForShot(_shot);
        final starts = [
          for (final it in its)
            if (it.startUs != null) it.startUs! - (take.device(it.deviceId)?.slot ?? 0) * take.staggerMs * 1000
        ];
        final earliest = starts.isEmpty ? 0 : starts.reduce(min);
        final heads = take.headTrimsMs();
        final spread = take.spreadMs(_shot);
        return Scaffold(
          appBar: AppBar(
            title: Text(take.kind == 'video' ? 'Video take' : 'Photo take'),
            actions: [
              if (widget.server != null && (widget.calibrate || take.kind != 'video'))
                IconButton(tooltip: 'Calibrate from clock', icon: const Icon(Icons.tune), onPressed: _calibrate),
              if (take.receivedFiles > 0)
                IconButton(
                  tooltip: 'Compare angles',
                  icon: const Icon(Icons.compare),
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute<void>(builder: (_) => CompareScreen(take: take, shot: _shot))),
                ),
              IconButton(tooltip: 'Save all to Photos', icon: const Icon(Icons.download), onPressed: _busy ? null : _saveAll),
              IconButton(tooltip: 'Share', icon: const Icon(Icons.share), onPressed: _share),
              IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
            ],
          ),
          body: Column(
            children: [
              ListTile(
                dense: true,
                title: Text('${take.receivedFiles}/${take.items.length} files received from ${take.devices.length} cameras'),
                subtitle: Text([
                  if (spread != null) 'Trigger spread ${spread.toStringAsFixed(1)} ms',
                  if (take.staggerMs > 0) 'Stagger ${take.staggerMs} ms',
                  if (take.slates.isNotEmpty) '${take.slates.length} slate(s) logged',
                ].join(' · ')),
              ),
              if (take.shots > 1)
                Row(children: [
                  const SizedBox(width: 16),
                  Text('Shot ${_shot + 1}/${take.shots}'),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: (take.shots - 1).toDouble(),
                      divisions: take.shots - 1,
                      value: _shot.toDouble(),
                      onChanged: (v) => setState(() => _shot = v.round()),
                    ),
                  ),
                ]),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    childAspectRatio: 3 / 4.6,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: its.length,
                  itemBuilder: (_, i) {
                    final it = its[i];
                    final dev = take.device(it.deviceId);
                    final f = take.fileFor(it);
                    final s = it.startUs;
                    final delta = s == null ? null : (s - (dev?.slot ?? 0) * take.staggerMs * 1000 - earliest) / 1000.0;
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: f == null || !f.existsSync()
                              ? Container(
                                  color: Colors.black26,
                                  alignment: Alignment.center,
                                  child: const Column(mainAxisSize: MainAxisSize.min, children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 8),
                                    Text('receiving…', style: TextStyle(fontSize: 12)),
                                  ]),
                                )
                              : it.kind == 'video'
                                  ? InkWell(
                                      onTap: () => Navigator.push(
                                          context, MaterialPageRoute<void>(builder: (_) => VideoPlayerPage(file: f, title: dev?.name))),
                                      child: Container(
                                        color: Colors.black,
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.play_circle, size: 56, color: Colors.white),
                                      ),
                                    )
                                  : InkWell(
                                      onTap: () => Navigator.push(
                                          context, MaterialPageRoute<void>(builder: (_) => _PhotoPage(file: f))),
                                      child: Image.file(f, fit: BoxFit.cover, cacheWidth: 480, width: double.infinity),
                                    ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('#${(dev?.slot ?? 0) + 1} ${dev?.name ?? it.deviceId}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        [
                          if (delta != null) '+${delta.toStringAsFixed(1)} ms',
                          if (heads[it.deviceId] case final h?) 'trim head ${h.toStringAsFixed(0)} ms',
                          formatBytes(it.size),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ]);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({required this.file});
  final File file;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: InteractiveViewer(maxScale: 8, child: Center(child: Image.file(file))),
      );
}
