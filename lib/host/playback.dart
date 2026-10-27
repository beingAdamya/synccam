import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// One camera's media in a take.
class Angle {
  Angle({required this.label, required this.file, required this.isVideo, this.offsetMs = 0});
  final String label;
  final File file;
  final bool isVideo;

  /// How far into this clip the shared timeline's zero lies (the take's
  /// head trim for this camera), so every angle shows the same instant.
  final double offsetMs;
}

/// Plays several clips as one: a shared timeline, shared play/pause/seek,
/// and continuous drift correction so the angles stay aligned.
class SyncedPlayback extends ChangeNotifier {
  SyncedPlayback(this.angles);

  final List<Angle> angles;
  final List<VideoPlayerController?> players = [];
  bool ready = false;
  String? error;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool loop = true;
  double speed = 1;
  int audioFrom = 0;

  /// Apply per-camera start offsets. Off shows each file from its own start.
  bool aligned = true;

  Timer? _tick;
  int _lastDriftFix = 0;
  bool _scrubbing = false;

  static const frame = Duration(microseconds: 33333); // 1/30 s step

  int get _master => players.indexWhere((p) => p != null);
  bool get hasVideo => _master >= 0;

  Duration _offset(int i) => aligned ? Duration(microseconds: (angles[i].offsetMs * 1000).round()) : Duration.zero;

  Future<void> init() async {
    try {
      for (final a in angles) {
        if (!a.isVideo) {
          players.add(null);
          continue;
        }
        final c = VideoPlayerController.file(a.file);
        await c.initialize();
        await c.setLooping(false);
        players.add(c);
      }
      audioFrom = max(0, _master);
      await _applyVolumes();
      _computeDuration();
      ready = true;
      await seek(Duration.zero);
      _tick = Timer.periodic(const Duration(milliseconds: 50), (_) => _onTick());
    } catch (e) {
      error = 'Could not open video: $e';
    }
    notifyListeners();
  }

  void _computeDuration() {
    var d = const Duration(days: 1);
    for (var i = 0; i < players.length; i++) {
      final p = players[i];
      if (p == null) continue;
      final usable = p.value.duration - _offset(i);
      if (usable < d) d = usable;
    }
    duration = hasVideo && d > Duration.zero ? d : Duration.zero;
  }

  Future<void> _applyVolumes() async {
    for (var i = 0; i < players.length; i++) {
      await players[i]?.setVolume(i == audioFrom ? 1 : 0);
    }
  }

  void _onTick() {
    final m = _master;
    if (!ready || m < 0 || _scrubbing) return;
    final mp = players[m]!;
    position = mp.value.position - _offset(m);
    if (position < Duration.zero) position = Duration.zero;
    if (playing && position >= duration) {
      if (loop) {
        seek(Duration.zero).then((_) => _playAll());
      } else {
        pause();
      }
    }
    // Every half second, pull any angle that drifted more than ~2 frames
    // back onto the master's timeline.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (playing && now - _lastDriftFix > 500) {
      _lastDriftFix = now;
      for (var i = 0; i < players.length; i++) {
        final p = players[i];
        if (p == null || i == m) continue;
        final want = position + _offset(i);
        if ((p.value.position - want).inMilliseconds.abs() > 70) p.seekTo(want);
      }
    }
    notifyListeners();
  }

  Future<void> _playAll() async {
    await Future.wait([for (final p in players) if (p != null) p.play()]);
  }

  Future<void> play() async {
    if (!hasVideo) return;
    if (position >= duration) await seek(Duration.zero);
    playing = true;
    await _playAll();
    notifyListeners();
  }

  Future<void> pause() async {
    playing = false;
    await Future.wait([for (final p in players) if (p != null) p.pause()]);
    notifyListeners();
  }

  Future<void> toggle() => playing ? pause() : play();

  Future<void> seek(Duration t) async {
    if (t < Duration.zero) t = Duration.zero;
    if (t > duration) t = duration;
    position = t;
    await Future.wait([
      for (var i = 0; i < players.length; i++)
        if (players[i] != null) players[i]!.seekTo(t + _offset(i)),
    ]);
    notifyListeners();
  }

  /// Scrubbing: pause while the finger is on the bar, resume after.
  bool _resumeAfterScrub = false;
  void scrubStart() {
    _scrubbing = true;
    _resumeAfterScrub = playing;
    if (playing) pause();
  }

  Future<void> scrubTo(Duration t) async {
    position = t;
    notifyListeners();
    await seek(t);
  }

  Future<void> scrubEnd() async {
    _scrubbing = false;
    if (_resumeAfterScrub) await play();
  }

  Future<void> step(int frames) async {
    if (playing) await pause();
    await seek(position + frame * frames);
  }

  Future<void> setSpeed(double s) async {
    speed = s;
    await Future.wait([for (final p in players) if (p != null) p.setPlaybackSpeed(s)]);
    notifyListeners();
  }

  Future<void> setAudio(int i) async {
    audioFrom = i;
    await _applyVolumes();
    notifyListeners();
  }

  Future<void> setAligned(bool v) async {
    aligned = v;
    _computeDuration();
    await seek(position);
  }

  void setLoop(bool v) {
    loop = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final p in players) {
      p?.dispose();
    }
    super.dispose();
  }
}

String formatPosition(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final cs = (d.inMilliseconds.remainder(1000) ~/ 10).toString().padLeft(2, '0');
  return '$m:$s.$cs';
}

/// Renders one angle: the video frame, or the photo.
class AngleView extends StatelessWidget {
  const AngleView({super.key, required this.playback, required this.index, this.fit = BoxFit.contain});
  final SyncedPlayback playback;
  final int index;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final p = index < playback.players.length ? playback.players[index] : null;
    final a = playback.angles[index];
    Widget child;
    if (!a.isVideo) {
      child = Image.file(a.file, fit: fit);
    } else if (p == null || !p.value.isInitialized) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      child = FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: p.value.size.width, height: p.value.size.height, child: VideoPlayer(p)),
      );
    }
    return ColoredBox(color: Colors.black, child: child);
  }
}

/// Transport bar: seek slider with timecode, frame step, play/pause, speed,
/// loop and (for several angles) which angle's audio to hear.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key, required this.playback, this.showAudio = false});
  final SyncedPlayback playback;
  final bool showAudio;

  @override
  Widget build(BuildContext context) {
    final pb = playback;
    final maxMs = max(1, pb.duration.inMilliseconds).toDouble();
    return Material(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(formatPosition(pb.position),
                  style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
              Expanded(
                child: Slider(
                  value: pb.position.inMilliseconds.clamp(0, maxMs).toDouble(),
                  max: maxMs,
                  onChangeStart: (_) => pb.scrubStart(),
                  onChanged: (v) => pb.scrubTo(Duration(milliseconds: v.round())),
                  onChangeEnd: (_) => pb.scrubEnd(),
                ),
              ),
              Text(formatPosition(pb.duration),
                  style: const TextStyle(color: Colors.white54, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                tooltip: 'Loop',
                color: pb.loop ? Colors.redAccent : Colors.white54,
                icon: const Icon(Icons.repeat),
                onPressed: () => pb.setLoop(!pb.loop),
              ),
              IconButton(
                  tooltip: 'Back 1 frame',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => pb.step(-1)),
              IconButton.filled(
                iconSize: 32,
                tooltip: pb.playing ? 'Pause' : 'Play',
                icon: Icon(pb.playing ? Icons.pause : Icons.play_arrow),
                onPressed: pb.toggle,
              ),
              IconButton(
                  tooltip: 'Forward 1 frame',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => pb.step(1)),
              PopupMenuButton<double>(
                tooltip: 'Speed',
                initialValue: pb.speed,
                onSelected: pb.setSpeed,
                itemBuilder: (_) => [
                  for (final s in const [0.1, 0.25, 0.5, 1.0, 1.5, 2.0])
                    PopupMenuItem(value: s, child: Text('${s}x')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('${pb.speed}x', style: const TextStyle(color: Colors.white)),
                ),
              ),
              if (showAudio)
                PopupMenuButton<int>(
                  tooltip: 'Audio from',
                  initialValue: pb.audioFrom,
                  onSelected: pb.setAudio,
                  itemBuilder: (_) => [
                    for (var i = 0; i < pb.angles.length; i++)
                      if (pb.angles[i].isVideo) PopupMenuItem(value: i, child: Text(pb.angles[i].label)),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.volume_up, color: Colors.white),
                  ),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Full-screen single clip with the seek bar.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.file, this.title});
  final File file;
  final String? title;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final SyncedPlayback _pb =
      SyncedPlayback([Angle(label: widget.title ?? '', file: widget.file, isVideo: true)]);

  @override
  void initState() {
    super.initState();
    _pb.init().then((_) => _pb.play());
  }

  @override
  void dispose() {
    _pb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(widget.title ?? '')),
      body: ListenableBuilder(
        listenable: _pb,
        builder: (context, _) => Column(children: [
          Expanded(
            child: _pb.error != null
                ? Center(child: Text(_pb.error!, style: const TextStyle(color: Colors.white)))
                : GestureDetector(onTap: _pb.toggle, child: AngleView(playback: _pb, index: 0)),
          ),
          PlaybackBar(playback: _pb),
        ]),
      ),
    );
  }
}
