import 'dart:math';

import 'package:flutter/material.dart';

import 'playback.dart';
import 'take.dart';

enum CompareMode { grid, side, wipe, overlay, switcher }

extension on CompareMode {
  String get label => switch (this) {
        CompareMode.grid => 'Grid',
        CompareMode.side => 'Side by side',
        CompareMode.wipe => 'Wipe',
        CompareMode.overlay => 'Overlay',
        CompareMode.switcher => 'Switcher',
      };
  IconData get icon => switch (this) {
        CompareMode.grid => Icons.grid_view,
        CompareMode.side => Icons.view_column,
        CompareMode.wipe => Icons.compare,
        CompareMode.overlay => Icons.layers,
        CompareMode.switcher => Icons.switch_video,
      };
}

/// Every angle of one take (one shot), played in sync on one timeline.
class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, required this.take, this.shot = 0});
  final Take take;
  final int shot;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late final SyncedPlayback _pb;
  CompareMode _mode = CompareMode.grid;
  int _a = 0, _b = 1;
  double _wipe = 0.5;
  double _opacity = 0.5;

  @override
  void initState() {
    super.initState();
    final take = widget.take;
    final heads = take.headTrimsMs();
    final angles = <Angle>[];
    for (final it in take.itemsForShot(widget.shot)) {
      final f = take.fileFor(it);
      if (f == null || !f.existsSync()) continue;
      final d = take.device(it.deviceId);
      angles.add(Angle(
        label: '#${(d?.slot ?? 0) + 1} ${d?.name ?? it.deviceId}',
        file: f,
        isVideo: it.kind == 'video',
        offsetMs: heads[it.deviceId] ?? 0,
      ));
    }
    _pb = SyncedPlayback(angles);
    _b = min(1, max(0, angles.length - 1));
    _pb.init();
  }

  @override
  void dispose() {
    _pb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = _pb.angles.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Compare angles'),
        actions: [
          if (_pb.hasVideo)
            ListenableBuilder(
              listenable: _pb,
              builder: (_, _) => IconButton(
                tooltip: _pb.aligned ? 'Aligned to the same instant (tap for raw)' : 'Raw clip starts (tap to align)',
                icon: Icon(_pb.aligned ? Icons.link : Icons.link_off),
                color: _pb.aligned ? Colors.greenAccent : Colors.white54,
                onPressed: () => _pb.setAligned(!_pb.aligned),
              ),
            ),
        ],
      ),
      body: n == 0
          ? const Center(child: Text('No files received for this take yet.', style: TextStyle(color: Colors.white)))
          : ListenableBuilder(
              listenable: _pb,
              builder: (context, _) {
                if (_pb.error != null) {
                  return Center(child: Text(_pb.error!, style: const TextStyle(color: Colors.white)));
                }
                return Column(children: [
                  _modeBar(n),
                  if (_needsPair && n >= 2) _pairPicker(),
                  Expanded(child: _view(n)),
                  if (_mode == CompareMode.overlay)
                    _sliderRow('Fade', _opacity, (v) => setState(() => _opacity = v)),
                  if (_pb.hasVideo) PlaybackBar(playback: _pb, showAudio: n > 1),
                ]);
              },
            ),
    );
  }

  bool get _needsPair => _mode == CompareMode.side || _mode == CompareMode.wipe || _mode == CompareMode.overlay;

  Widget _modeBar(int n) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          for (final m in CompareMode.values)
            if (n >= 2 || m == CompareMode.grid)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  avatar: Icon(m.icon, size: 16),
                  label: Text(m.label),
                  selected: _mode == m,
                  onSelected: (_) => setState(() => _mode = m),
                ),
              ),
        ]),
      );

  Widget _pairPicker() {
    DropdownButton<int> pick(int value, ValueChanged<int> onChanged) => DropdownButton<int>(
          value: value,
          dropdownColor: Colors.grey.shade900,
          style: const TextStyle(color: Colors.white),
          underline: const SizedBox(),
          items: [
            for (var i = 0; i < _pb.angles.length; i++) DropdownMenuItem(value: i, child: Text(_pb.angles[i].label)),
          ],
          onChanged: (v) => onChanged(v!),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        const Text('A ', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
        Expanded(child: pick(_a, (v) => setState(() => _a = v))),
        IconButton(
          tooltip: 'Swap',
          color: Colors.white,
          icon: const Icon(Icons.swap_horiz),
          onPressed: () => setState(() {
            final t = _a;
            _a = _b;
            _b = t;
          }),
        ),
        const Text('B ', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
        Expanded(child: pick(_b, (v) => setState(() => _b = v))),
      ]),
    );
  }

  Widget _label(String text, {Color color = Colors.white}) => Positioned(
        left: 6,
        top: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
          child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _tile(int i, {BoxFit fit = BoxFit.contain, Color labelColor = Colors.white}) => Stack(fit: StackFit.expand, children: [
        AngleView(playback: _pb, index: i, fit: fit),
        _label(_pb.angles[i].label, color: labelColor),
      ]);

  Widget _view(int n) {
    switch (_mode) {
      case CompareMode.grid:
        return LayoutBuilder(builder: (context, box) {
          final cols = n <= 1 ? 1 : n <= 4 ? 2 : 3;
          final rows = (n / cols).ceil();
          return GridView.count(
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: cols,
            childAspectRatio: (box.maxWidth / cols) / (box.maxHeight / rows),
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            children: [for (var i = 0; i < n; i++) _tile(i)],
          );
        });
      case CompareMode.side:
        return LayoutBuilder(builder: (context, box) {
          final children = [
            Expanded(child: _tile(_a, labelColor: Colors.cyanAccent)),
            const SizedBox(width: 2, height: 2),
            Expanded(child: _tile(_b, labelColor: Colors.amberAccent)),
          ];
          // Portrait phone: stack vertically so each angle stays large.
          return box.maxWidth > box.maxHeight ? Row(children: children) : Column(children: children);
        });
      case CompareMode.wipe:
        return LayoutBuilder(builder: (context, box) {
          return GestureDetector(
            onHorizontalDragUpdate: (e) =>
                setState(() => _wipe = (e.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
            onTapDown: (e) => setState(() => _wipe = (e.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
            child: Stack(fit: StackFit.expand, children: [
              AngleView(playback: _pb, index: _b),
              ClipRect(
                clipper: _LeftClipper(_wipe),
                child: AngleView(playback: _pb, index: _a),
              ),
              Positioned(
                left: box.maxWidth * _wipe - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.white),
              ),
              Positioned(
                left: box.maxWidth * _wipe - 16,
                top: box.maxHeight / 2 - 16,
                child: const CircleAvatar(
                    radius: 16, backgroundColor: Colors.white, child: Icon(Icons.drag_indicator, size: 18)),
              ),
              _label('A  ${_pb.angles[_a].label}', color: Colors.cyanAccent),
              Positioned(
                right: 6,
                top: 6,
                child: Text('B  ${_pb.angles[_b].label}',
                    style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.w600)),
              ),
            ]),
          );
        });
      case CompareMode.overlay:
        return Stack(fit: StackFit.expand, children: [
          AngleView(playback: _pb, index: _a),
          Opacity(opacity: _opacity, child: AngleView(playback: _pb, index: _b)),
          _label('A ${_pb.angles[_a].label}  +  B ${_pb.angles[_b].label} at ${(100 * _opacity).round()}%'),
        ]);
      case CompareMode.switcher:
        return Column(children: [
          Expanded(child: _tile(_a)),
          SizedBox(
            height: 88,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(4),
              children: [
                for (var i = 0; i < n; i++)
                  GestureDetector(
                    onTap: () => setState(() => _a = i),
                    child: Container(
                      width: 112,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                          border: Border.all(color: i == _a ? Colors.redAccent : Colors.white24, width: 2)),
                      child: _tile(i, fit: BoxFit.cover),
                    ),
                  ),
              ],
            ),
          ),
        ]);
    }
  }

  Widget _sliderRow(String label, double v, ValueChanged<double> onChanged) => Row(children: [
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white)),
        Expanded(child: Slider(value: v, onChanged: onChanged)),
      ]);
}

class _LeftClipper extends CustomClipper<Rect> {
  _LeftClipper(this.fraction);
  final double fraction;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);
  @override
  bool shouldReclip(_LeftClipper old) => old.fraction != fraction;
}
