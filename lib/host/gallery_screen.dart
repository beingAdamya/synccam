import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../core/prefs.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'host_server.dart';
import 'take.dart';
import 'take_screen.dart';

/// The gallery as its own page (from the start screen).
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.library, this.server});
  final TakeLibrary library;
  final HostServer? server;

  static IconData iconFor(String kind) => switch (kind) {
    'video' => Icons.videocam_rounded,
    'burst' => Icons.burst_mode_rounded,
    'interval' => Icons.timelapse_rounded,
    _ => Icons.photo_camera_rounded,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GalleryView(library: library, server: server, showBack: true),
  );
}

/// Takes grouped newest first, each a strip of its angles in rig order.
/// Long-press (or Select) to pick several, then share, save or delete them.
class GalleryView extends StatefulWidget {
  const GalleryView({
    super.key,
    required this.library,
    this.server,
    this.showBack = false,
  });
  final TakeLibrary library;
  final HostServer? server;
  final bool showBack;

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final Set<Take> _selected = {};
  bool _selecting = false;
  bool _busy = false;

  TakeLibrary get library => widget.library;

  void _toggle(Take t) {
    Haptic.tick();
    setState(() {
      if (!_selected.remove(t)) _selected.add(t);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _startSelecting([Take? first]) {
    Haptic.light();
    setState(() {
      _selecting = true;
      if (first != null) _selected.add(first);
    });
  }

  void _done() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  List<File> _files(Iterable<Take> takes) => [
    for (final t in takes)
      for (final it in t.items)
        if (t.fileFor(it) case final f? when f.existsSync()) f,
  ];

  Future<void> _share() async {
    final files = _files(_selected);
    if (files.isEmpty) {
      return showSnack(context, 'These takes have no files on this phone yet.');
    }
    await SharePlus.instance.share(
      ShareParams(files: [for (final f in files) XFile(f.path)]),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final n = await saveToPhotos(
      _selected.expand((t) => [for (final it in t.items) (t, it)]),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(
      context,
      n < 0
          ? 'SyncCam needs access to Photos to save.'
          : 'Saved $n file${n == 1 ? '' : 's'} to Photos',
    );
  }

  Future<void> _delete() async {
    final list = _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Delete ${list.length} take${list.length == 1 ? '' : 's'}?',
        ),
        content: const Text(
          'They are deleted from this phone only. Copies the cameras kept in their own Photos stay there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Status.recording,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete from this phone'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _done();
    deleteWithUndo(context, library, list);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    final top = MediaQuery.of(context).padding.top;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        _selected.removeWhere((x) => !library.takes.contains(x));
        final takes = library.takes;
        return Column(
          children: [
            SizedBox(height: top + 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: SizedBox(
                height: 56,
                child: _selecting
                    ? Row(
                        children: [
                          IconButton(
                            tooltip: 'Done',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _done,
                          ),
                          Expanded(
                            child: Text(
                              '${_selected.length} selected',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _selected.length == takes.length
                                  ? _selected.clear()
                                  : _selected.addAll(takes);
                            }),
                            child: Text(
                              _selected.length == takes.length
                                  ? 'Select none'
                                  : 'Select all',
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (widget.showBack)
                            const BackButton()
                          else
                            const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Gallery',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          if (takes.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => _startSelecting(),
                              icon: const Icon(
                                Icons.check_circle_outline_rounded,
                              ),
                              label: const Text('Select'),
                            ),
                        ],
                      ),
              ),
            ),
            Expanded(
              child: takes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.photo_library_outlined,
                              size: 48,
                              color: t.muted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No takes yet',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Press the shutter to shoot on every camera at once.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, box) {
                        final cols = box.maxWidth > 900
                            ? 3
                            : (box.maxWidth > 600 ? 2 : 1);
                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols,
                                mainAxisExtent: 168,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                              ),
                          itemCount: takes.length,
                          itemBuilder: (_, i) {
                            final take = takes[i];
                            return TakeCard(
                              take: take,
                              selecting: _selecting,
                              selected: _selected.contains(take),
                              onTap: _selecting
                                  ? () => _toggle(take)
                                  : () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (_) => TakeScreen(
                                          library: library,
                                          server: widget.server,
                                          take: take,
                                        ),
                                      ),
                                    ),
                              onLongPress: _selecting
                                  ? () => _toggle(take)
                                  : () => _startSelecting(take),
                            );
                          },
                        );
                      },
                    ),
            ),
            if (_selecting)
              _SelectionBar(
                enabled: _selected.isNotEmpty && !_busy,
                busy: _busy,
                onShare: _share,
                onSave: _save,
                onDelete: _delete,
              ),
          ],
        );
      },
    );
  }
}

/// Share / Save / Delete for whatever is selected.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.enabled,
    required this.busy,
    required this.onShare,
    required this.onSave,
    required this.onDelete,
  });
  final bool enabled;
  final bool busy;
  final VoidCallback onShare;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    Widget action(
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color? color,
    }) => Expanded(
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: color ?? context.sync.text,
        ),
        onPressed: enabled ? onTap : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            action(Icons.ios_share_rounded, 'Share', onShare),
            busy
                ? const Expanded(
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : action(Icons.download_rounded, 'Save to Photos', onSave),
            action(
              Icons.delete_outline_rounded,
              'Delete',
              onDelete,
              color: Status.recording,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Take 14 · 6 angles · 0:42" over a strip of its angles in camera order,
/// each with its camera colour underneath.
class TakeCard extends StatelessWidget {
  const TakeCard({
    super.key,
    required this.take,
    required this.onTap,
    required this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });
  final Take take;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    final angles = take.angles;
    final len = take.length;
    final here = take.anglesHere;
    final title = take.label.isNotEmpty ? take.label : 'Take ${take.number}';
    return Semantics(
      selected: selected,
      label: '$title, ${angles.length} angles',
      child: GlassCard(
        selected: selected,
        padding: const EdgeInsets.all(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  GalleryScreen.iconFor(take.kind),
                  size: 18,
                  color: t.muted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text:
                              ' · ${angles.length} angle${angles.length == 1 ? '' : 's'}',
                          style: TextStyle(color: t.muted),
                        ),
                        if (len != null)
                          TextSpan(
                            text: ' · ${_len(len)}',
                            style: mono(size: 13, color: t.muted),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selecting)
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? t.accent : t.muted,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  for (final a in angles.take(8))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Column(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(6),
                                ),
                                child: _Thumb(
                                  file: take.thumbFor(a.id),
                                  kind: take.kind,
                                ),
                              ),
                            ),
                            Container(
                              height: 3,
                              color: CameraColors.forSlot(a.slot),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (angles.length > 8)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '+${angles.length - 8}',
                        style: mono(size: 12, color: t.muted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              [
                _when(take.createdAt),
                if (here < angles.length)
                  '$here of ${angles.length} on this phone',
                if (take.notes.isNotEmpty) take.notes.first,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _len(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _when(DateTime d) {
    final now = DateTime.now();
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'Today $hm';
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} $hm';
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file, required this.kind});
  final File? file;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final f = file;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (f != null)
          Image.file(
            f,
            fit: BoxFit.cover,
            cacheWidth: 160,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
          )
        else
          ColoredBox(color: context.sync.surfaceHigh),
        if (kind == 'video')
          const Center(
            child: Icon(
              Icons.play_arrow_rounded,
              color: Colors.white70,
              size: 20,
            ),
          ),
      ],
    );
  }
}

/// Saves files to the Photos app in a SyncCam album. Returns how many were
/// saved, or -1 without permission.
Future<int> saveToPhotos(Iterable<(Take, TakeItem)> items) async {
  if (!await Gal.requestAccess(toAlbum: true)) return -1;
  var n = 0;
  for (final (t, it) in items) {
    final f = t.fileFor(it);
    if (f == null || !f.existsSync()) continue;
    try {
      it.kind == 'video'
          ? await Gal.putVideo(f.path, album: 'SyncCam')
          : await Gal.putImage(f.path, album: 'SyncCam');
      n++;
    } catch (_) {}
  }
  return n;
}

/// Removes takes now and deletes them for good after 5 s unless Undo is tapped.
void deleteWithUndo(
  BuildContext context,
  TakeLibrary library,
  List<Take> list,
) {
  library.remove(list);
  var undone = false;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(
          'Deleted ${list.length} take${list.length == 1 ? '' : 's'}',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            undone = true;
            library.restore(list);
          },
        ),
      ),
    );
  Timer(const Duration(seconds: 6), () {
    if (!undone) library.purge(list);
  });
}
