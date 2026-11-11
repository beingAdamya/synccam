import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

import '../core/prefs.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'take.dart';

enum SweepDirection { forward, backward, bounce }

/// Bullet-time: the angles of one moment, in rig order, played as a looping
/// sweep. Adjust speed and direction, scrub frame by frame, then export.
class BulletTimeScreen extends StatefulWidget {
  const BulletTimeScreen({super.key, required this.take, this.shot = 0});
  final Take take;
  final int shot;

  @override
  State<BulletTimeScreen> createState() => _BulletTimeScreenState();
}

class _BulletTimeScreenState extends State<BulletTimeScreen> {
  late final List<(int slot, File file)> _frames = _photos();

  List<(int, File)> _photos() {
    final out = <(int, File)>[];
    for (final it in widget.take.itemsForShot(widget.shot)) {
      final f = widget.take.fileFor(it);
      if (it.kind == 'photo' && f != null && f.existsSync()) {
        out.add((widget.take.device(it.deviceId)?.slot ?? 0, f));
      }
    }
    return out;
  }

  int _i = 0;
  int _step = 1;
  double _fps = 8;
  SweepDirection _dir = SweepDirection.bounce;
  bool _playing = true;
  Timer? _timer;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final (_, f) in _frames) {
      precacheImage(FileImage(f), context);
    }
  }

  void _restart() {
    _timer?.cancel();
    if (!_playing || _frames.length < 2) return;
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / _fps).round()),
      (_) => setState(_advance),
    );
  }

  void _advance() {
    final n = _frames.length;
    switch (_dir) {
      case SweepDirection.forward:
        _i = (_i + 1) % n;
      case SweepDirection.backward:
        _i = (_i - 1 + n) % n;
      case SweepDirection.bounce:
        if (_i + _step >= n || _i + _step < 0) _step = -_step;
        _i += _step;
    }
  }

  /// Frame order for export, matching the preview's direction.
  List<int> get _order {
    final n = _frames.length;
    final fwd = [for (var i = 0; i < n; i++) i];
    return switch (_dir) {
      SweepDirection.forward => fwd,
      SweepDirection.backward => fwd.reversed.toList(),
      SweepDirection.bounce => [...fwd, ...fwd.reversed.skip(1).take(n - 2)],
    };
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final paths = [for (final i in _order) _frames[i].$2.path];
      final out = '${widget.take.dir.path}/bullet-time-${widget.shot + 1}.gif';
      final delayMs = (1000 / _fps).round();
      await Isolate.run(() => _encodeGif(paths, out, delayMs));
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(out)]));
    } catch (e) {
      if (mounted) showSnack(context, 'Couldn\'t make the animation: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return Theme(
      data: buildTheme(
        t.choice == ThemeChoice.daylight ? ThemeChoice.studio : t.choice,
      ),
      child: Builder(
        builder: (context) {
          return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              title: const Text('Bullet-time'),
              backgroundColor: Colors.black,
            ),
            body: _frames.length < 2
                ? const Center(
                    child: Text(
                      'Bullet-time needs photos from at least two cameras.',
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              _frames[_i].$2,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                            Positioned(
                              left: 12,
                              top: 12,
                              child: NumberBadge(_frames[_i].$1),
                            ),
                          ],
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    tooltip: _playing ? 'Pause' : 'Play',
                                    icon: Icon(
                                      _playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                    onPressed: () {
                                      setState(() => _playing = !_playing);
                                      _restart();
                                    },
                                  ),
                                  Expanded(
                                    child: Slider(
                                      min: 0,
                                      max: (_frames.length - 1).toDouble(),
                                      divisions: _frames.length - 1,
                                      value: _i.toDouble(),
                                      onChanged: (v) {
                                        if (v.round() != _i) Haptic.tick();
                                        setState(() {
                                          _i = v.round();
                                          _playing = false;
                                        });
                                        _restart();
                                      },
                                    ),
                                  ),
                                  Text(
                                    '${_i + 1}/${_frames.length}',
                                    style: mono(size: 13),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  Text(
                                    'Speed',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                  Expanded(
                                    child: Slider(
                                      min: 2,
                                      max: 24,
                                      value: _fps,
                                      onChanged: (v) {
                                        setState(() => _fps = v);
                                        _restart();
                                      },
                                    ),
                                  ),
                                  Text(
                                    '${_fps.round()} fps',
                                    style: mono(size: 13),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SegmentedButton<SweepDirection>(
                                showSelectedIcon: false,
                                segments: const [
                                  ButtonSegment(
                                    value: SweepDirection.forward,
                                    icon: Icon(Icons.arrow_forward_rounded),
                                    label: Text('Forward'),
                                  ),
                                  ButtonSegment(
                                    value: SweepDirection.backward,
                                    icon: Icon(Icons.arrow_back_rounded),
                                    label: Text('Back'),
                                  ),
                                  ButtonSegment(
                                    value: SweepDirection.bounce,
                                    icon: Icon(Icons.swap_horiz_rounded),
                                    label: Text('Bounce'),
                                  ),
                                ],
                                selected: {_dir},
                                onSelectionChanged: (v) =>
                                    setState(() => _dir = v.first),
                              ),
                              const SizedBox(height: 12),
                              PrimaryButton(
                                label: _exporting
                                    ? 'Making animation…'
                                    : 'Export animation',
                                icon: Icons.ios_share_rounded,
                                onPressed: _exporting ? null : _export,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// Builds a looping GIF from photos, scaled to 720 px wide.
void _encodeGif(List<String> paths, String out, int delayMs) {
  img.Image? anim;
  for (final p in paths) {
    var frame = img.decodeImage(File(p).readAsBytesSync());
    if (frame == null) continue;
    frame = img.bakeOrientation(frame);
    frame = img.copyResize(frame, width: 720);
    frame.frameDuration = delayMs;
    if (anim == null) {
      anim = frame;
      anim.loopCount = 0;
    } else {
      // Every frame must match the first one's size.
      if (frame.width != anim.width || frame.height != anim.height) {
        frame = img.copyResize(frame, width: anim.width, height: anim.height)
          ..frameDuration = delayMs;
      }
      anim.addFrame(frame);
    }
  }
  if (anim == null) throw StateError('no frames');
  File(out).writeAsBytesSync(img.encodeGif(anim, samplingFactor: 20));
}
