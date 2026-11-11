import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/prefs.dart';
import '../core/util.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'bullet_time.dart';
import 'compare_screen.dart';
import 'gallery_screen.dart';
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

  final Set<TakeItem> _sel = {};
  bool _selecting = false;

  List<TakeItem> get _targets => _selecting ? _sel.toList() : take.items;

  Future<void> _saveAll() async {
    setState(() => _busy = true);
    final n = await saveToPhotos([for (final it in _targets) (take, it)]);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, n < 0 ? 'SyncCam needs access to Photos to save.' : 'Saved $n file${n == 1 ? '' : 's'} to Photos');
  }

  Future<void> _share() async {
    final files = [
      for (final it in _targets)
        if (take.fileFor(it) case final f? when f.existsSync()) f,
      if (!_selecting) File('${take.dir.path}/manifest.json'),
    ];
    if (files.isEmpty) return showSnack(context, 'Nothing on this phone to share yet.');
    await SharePlus.instance.share(ShareParams(files: [for (final f in files) XFile(f.path)]));
  }

  Future<void> _delete() async {
    if (_selecting) {
      final list = _sel.toList();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete ${list.length} file${list.length == 1 ? '' : 's'}?'),
          content: const Text('They are deleted from this phone only.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Status.recording, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      for (final it in list) {
        await take.removeItem(it);
      }
      widget.library.changed();
      if (mounted) setState(_endSelect);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this take?'),
        content: const Text('It is deleted from this phone only. Copies the cameras kept in their own Photos stay there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Status.recording, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete from this phone'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    deleteWithUndo(context, widget.library, [take]);
    Navigator.pop(context);
  }

  void _toggle(TakeItem it) {
    Haptic.tick();
    setState(() {
      if (!_sel.remove(it)) _sel.add(it);
      if (_sel.isEmpty) _selecting = false;
    });
  }

  void _endSelect() {
    _selecting = false;
    _sel.clear();
  }

  /// Give the shot a name ("Ceremony – first kiss") instead of a timestamp.
  Future<void> _rename() async {
    final ctl = TextEditingController(text: take.label);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this shot'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. First dance')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    take.label = name;
    await take.save();
    widget.library.changed();
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
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adjust timing')),
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
    if (mounted) showSnack(context, m);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final t = context.sync;
        final its = take.itemsForShot(_shot);
        final starts = [
          for (final it in its)
            if (it.startUs != null) it.startUs! - (take.device(it.deviceId)?.slot ?? 0) * take.staggerMs * 1000
        ];
        final earliest = starts.isEmpty ? 0 : starts.reduce(min);
        final heads = take.headTrimsMs();
        final spread = take.spreadMs(_shot);
        final photos = its.where((i) => i.kind == 'photo' && take.fileFor(i)?.existsSync() == true).length;
        return PopScope(
          canPop: !_selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(_endSelect);
          },
          child: Scaffold(
            appBar: _selecting
                ? AppBar(
                    leading: IconButton(
                        tooltip: 'Done', icon: const Icon(Icons.close_rounded), onPressed: () => setState(_endSelect)),
                    title: Text('${_sel.length} selected'),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _sel.length == its.length ? _sel.clear() : _sel.addAll(its)),
                        child: Text(_sel.length == its.length ? 'Select none' : 'Select all'),
                      ),
                    ],
                  )
                : AppBar(
                    title: InkWell(
                      onTap: _rename,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: Text(take.label.isNotEmpty ? take.label : 'Take ${take.number}',
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.edit_rounded, size: 16),
                      ]),
                    ),
                    actions: [
                      if (widget.server != null && (widget.calibrate || take.kind != 'video'))
                        IconButton(
                            tooltip: 'Fine-tune timing from this shot',
                            icon: const Icon(Icons.timer_outlined),
                            onPressed: _calibrate),
                      IconButton(
                        tooltip: 'Select files',
                        icon: const Icon(Icons.check_circle_outline_rounded),
                        onPressed: () => setState(() => _selecting = true),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          switch (v) {
                            case 'save':
                              _saveAll();
                            case 'share':
                              _share();
                            default:
                              _delete();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'save', child: Text('Save all to Photos')),
                          PopupMenuItem(value: 'share', child: Text('Share all')),
                          PopupMenuItem(value: 'delete', child: Text('Delete take')),
                        ],
                      ),
                    ],
                  ),
            body: AppBackground(
              glow: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      if (spread != null)
                        StatusPill('Within ${spread.toStringAsFixed(1)} ms',
                            color: spread < 2 ? Status.ready : (spread < 10 ? Status.syncing : Status.warning),
                            icon: Icons.timer_outlined),
                      StatusPill('${take.receivedFiles} of ${take.items.length} files here',
                          color: take.receivedFiles == take.items.length ? Status.ready : Status.syncing,
                          icon: Icons.download_done_rounded),
                      if (take.staggerMs > 0) StatusPill('Sweep ${take.staggerMs} ms', color: t.secondary),
                      for (final n in take.notes) StatusPill(n, color: Status.warning, icon: Icons.info_outline_rounded),
                    ]),
                  ),
                  if (!_selecting)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(children: [
                        if (take.receivedFiles > 0)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.push(context,
                                  MaterialPageRoute<void>(builder: (_) => CompareScreen(take: take, shot: _shot))),
                              icon: const Icon(Icons.compare_rounded),
                              label: const Text('Compare'),
                            ),
                          ),
                        if (photos >= 2) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => Navigator.push(context,
                                  MaterialPageRoute<void>(builder: (_) => BulletTimeScreen(take: take, shot: _shot))),
                              icon: const Icon(Icons.threesixty_rounded),
                              label: const Text('Make bullet-time'),
                            ),
                          ),
                        ],
                      ]),
                    ),
                  if (take.shots > 1)
                    Row(children: [
                      const SizedBox(width: 16),
                      Text('Shot ${_shot + 1} of ${take.shots}', style: mono(size: 13)),
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
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 240,
                        childAspectRatio: 3 / 4.6,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                      ),
                      itemCount: its.length,
                      itemBuilder: (_, i) => _itemTile(its[i], earliest, heads),
                    ),
                  ),
                  if (_selecting) _selectionBar(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _itemTile(TakeItem it, int earliest, Map<String, double> heads) {
    final t = context.sync;
    final dev = take.device(it.deviceId);
    final slot = dev?.slot ?? 0;
    final f = take.fileFor(it);
    final have = f != null && f.existsSync();
    final s = it.startUs;
    final delta = s == null ? null : (s - slot * take.staggerMs * 1000 - earliest) / 1000.0;
    final sel = _sel.contains(it);
    void open() {
      if (!have) return;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => it.kind == 'video' ? VideoPlayerPage(file: f, title: dev?.name) : _PhotoPage(file: f),
        ),
      );
    }

    final thumb = take.thumbFor(it.deviceId);
    return GestureDetector(
      onTap: _selecting ? () => _toggle(it) : open,
      onLongPress: () {
        if (!_selecting) Haptic.light();
        setState(() => _selecting = true);
        _toggle(it);
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SyncTheme.tileRadius),
              border: Border.all(color: sel ? t.accent : CameraColors.forSlot(slot), width: sel ? 3 : 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(SyncTheme.tileRadius - 2),
              child: Stack(fit: StackFit.expand, children: [
                if (!have)
                  Container(
                    color: Colors.black26,
                    alignment: Alignment.center,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(height: 8),
                      Text('Still on the camera', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  )
                else if (it.kind == 'video') ...[
                  if (thumb != null)
                    Image.file(thumb, fit: BoxFit.cover, cacheWidth: 360)
                  else
                    const ColoredBox(color: Colors.black),
                  const Center(child: Icon(Icons.play_circle_rounded, size: 52, color: Colors.white)),
                ] else
                  Image.file(f, fit: BoxFit.cover, cacheWidth: 480),
                Positioned(left: 6, top: 6, child: NumberBadge(slot)),
                if (_selecting)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Icon(
                      sel ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: sel ? t.accent : Colors.white,
                      shadows: const [Shadow(blurRadius: 6)],
                    ),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(dev?.name ?? it.deviceId,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          [
            if (delta != null) '+${delta.toStringAsFixed(1)} ms',
            if (heads[it.deviceId] case final h? when h > 0) 'trim ${h.toStringAsFixed(0)} ms',
            formatBytes(it.size),
          ].join(' · '),
          style: mono(size: 11, color: t.muted),
        ),
      ]),
    );
  }

  Widget _selectionBar() {
    final t = context.sync;
    Widget action(IconData icon, String label, VoidCallback onTap, {Color? color}) => Expanded(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: color ?? t.text),
            onPressed: _sel.isEmpty || _busy ? null : onTap,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12)),
            ]),
          ),
        );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            action(Icons.ios_share_rounded, 'Share', _share),
            action(Icons.download_rounded, 'Save to Photos', _saveAll),
            action(Icons.delete_outline_rounded, 'Delete', _delete, color: Status.recording),
          ]),
        ),
      ),
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
