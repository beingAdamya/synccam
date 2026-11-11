import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/protocol.dart';
import '../ui/rig_widgets.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'host_server.dart';

/// Set once, apply to all: every control changes every camera, then the
/// apply row shows which cameras took it and what the others used instead.
Future<void> showRigSettings(BuildContext context, HostServer server) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) =>
            RigSettingsSheet(server: server, scroll: scroll),
      ),
    );

class RigSettingsSheet extends StatelessWidget {
  const RigSettingsSheet({super.key, required this.server, this.scroll});
  final HostServer server;
  final ScrollController? scroll;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final g = server.global;
        final cfg = server.config;
        final rolling = server.anyRecording;
        bool mixed(String key) {
          final v = g.toJson()[key];
          return server.onlineDevices.any(
            (d) => d.override.containsKey(key) && d.override[key] != v,
          );
        }

        void set(void Function(CameraSettings s) f) => server.updateGlobal(f);
        void policy(void Function() f) {
          f();
          server.updatePolicy();
        }

        final maxZoom = server.onlineDevices.isEmpty
            ? 10.0
            : server.onlineDevices
                  .map((d) => d.maxZoom)
                  .reduce((a, b) => a > b ? a : b)
                  .clamp(1.0, 20.0);

        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            Text('Rig settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Every change goes to all cameras.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ApplyRow(server: server),
            if (rolling)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: StatusPill(
                  'Format changes wait until recording stops',
                  color: Status.syncing,
                  icon: Icons.schedule_rounded,
                ),
              ),
            SectionTitle('Format'),
            _Row(
              label: 'Resolution',
              mixed: mixed('resolution'),
              child: SegmentedButton<ResChoice>(
                showSelectedIcon: false,
                segments: [
                  for (final r in const [
                    ResChoice.medium,
                    ResChoice.high,
                    ResChoice.veryHigh,
                    ResChoice.ultraHigh,
                  ])
                    ButtonSegment(
                      value: r,
                      label: Text(
                        resLabel(r),
                        style: mono(size: 13, weight: FontWeight.w600),
                      ),
                    ),
                ],
                selected: {g.resolution},
                emptySelectionAllowed: true,
                onSelectionChanged: (v) {
                  if (v.isNotEmpty) set((s) => s.resolution = v.first);
                },
              ),
            ),
            _Row(
              label: 'Frame rate',
              mixed: mixed('fps'),
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (final f in const [0, 24, 30, 60])
                    ButtonSegment(
                      value: f,
                      label: Text(
                        f == 0 ? 'Auto' : '$f',
                        style: mono(size: 13, weight: FontWeight.w600),
                      ),
                    ),
                ],
                selected: {g.fps ?? 0},
                onSelectionChanged: (v) =>
                    set((s) => s.fps = v.first == 0 ? null : v.first),
              ),
            ),
            _Switch(
              'Sound',
              'Record audio with video',
              g.enableAudio,
              mixed('enableAudio'),
              (v) => set((s) => s.enableAudio = v),
            ),
            _Switch(
              'Stabilization',
              'Smoother handheld video; off keeps timing tightest',
              g.stabilization,
              mixed('stabilization'),
              (v) => set((s) => s.stabilization = v),
            ),
            SectionTitle('Lens'),
            _Row(
              label: 'Camera',
              mixed: mixed('lens'),
              child: SegmentedButton<LensChoice>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: LensChoice.back,
                    label: Text('Back'),
                    icon: Icon(Icons.camera_rear_rounded),
                  ),
                  ButtonSegment(
                    value: LensChoice.front,
                    label: Text('Front'),
                    icon: Icon(Icons.camera_front_rounded),
                  ),
                ],
                selected: {
                  g.lens == LensChoice.external ? LensChoice.back : g.lens,
                },
                onSelectionChanged: (v) => set((s) => s.lens = v.first),
              ),
            ),
            _Row(
              label: 'Zoom',
              mixed: mixed('zoom'),
              value: '${g.zoom.toStringAsFixed(1)}×',
              child: ValueDial(
                values: [for (var z = 1.0; z <= maxZoom + 0.001; z += 0.5) z],
                value: g.zoom,
                format: (v) => '${v.toStringAsFixed(1)}×',
                onChanged: (v) => set((s) => s.zoom = v),
              ),
            ),
            _Row(
              label: 'Flash',
              mixed: mixed('flash'),
              child: SegmentedButton<FlashChoice>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: FlashChoice.off, label: Text('Off')),
                  ButtonSegment(value: FlashChoice.auto, label: Text('Auto')),
                  ButtonSegment(value: FlashChoice.always, label: Text('On')),
                  ButtonSegment(value: FlashChoice.torch, label: Text('Light')),
                ],
                selected: {g.flash},
                onSelectionChanged: (v) => set((s) => s.flash = v.first),
              ),
            ),
            SectionTitle('Exposure'),
            _Row(
              label: 'Brightness',
              mixed: mixed('exposureOffset'),
              value: _ev(g.exposureOffset),
              child: ValueDial(
                values: [
                  for (var e = -3.0; e <= 3.001; e += 1 / 3)
                    double.parse(e.toStringAsFixed(2)),
                ],
                value: g.exposureOffset,
                format: _ev,
                onChanged: (v) => set((s) => s.exposureOffset = v),
              ),
            ),
            _Switch(
              'Lock light',
              'Keep brightness steady when the scene changes',
              g.exposureLocked,
              mixed('exposureLocked'),
              (v) => set((s) => s.exposureLocked = v),
            ),
            SectionTitle('Focus'),
            _Switch(
              'Lock focus',
              'Tap a spot on a camera to focus there first',
              g.focusLocked,
              mixed('focusLocked'),
              (v) => set((s) => s.focusLocked = v),
            ),
            SectionTitle('Capture'),
            _Row(
              label: 'Countdown',
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (final c in const [0, 3, 5, 10])
                    ButtonSegment(
                      value: c,
                      label: Text(
                        c == 0 ? 'Off' : '${c}s',
                        style: mono(size: 13, weight: FontWeight.w600),
                      ),
                    ),
                ],
                selected: {cfg.countdownSec},
                onSelectionChanged: (v) =>
                    policy(() => cfg.countdownSec = v.first),
              ),
            ),
            _Row(
              label: 'Burst',
              value:
                  '${cfg.burstCount} shots · ${cfg.burstIntervalMs} ms apart',
              child: Slider(
                min: 2,
                max: 20,
                divisions: 18,
                value: cfg.burstCount.toDouble(),
                onChanged: (v) => policy(() => cfg.burstCount = v.round()),
              ),
            ),
            _Row(
              label: 'Sweep between cameras',
              value: cfg.staggerMs == 0
                  ? 'Off · all at once'
                  : '${cfg.staggerMs} ms',
              child: Slider(
                min: 0,
                max: 500,
                divisions: 50,
                value: cfg.staggerMs.toDouble(),
                onChanged: (v) => policy(() => cfg.staggerMs = v.round()),
              ),
            ),
            _Switch(
              'Sync tone',
              'A short chirp at the start of each video, for cameras that sync by sound',
              cfg.autoSlate,
              false,
              (v) => policy(() => cfg.autoSlate = v),
            ),
            _Switch(
              'Time-lapse',
              'Video mode takes a photo on every camera every ${cfg.intervalSec} s instead',
              cfg.mode == CaptureMode.interval,
              false,
              (v) {
                if (rolling) return;
                policy(
                  () => cfg.mode = v ? CaptureMode.interval : CaptureMode.video,
                );
              },
            ),
            if (cfg.mode == CaptureMode.interval)
              _Row(
                label: 'Time-lapse interval',
                value: '${cfg.intervalSec} s',
                child: Slider(
                  min: 1,
                  max: 60,
                  divisions: 59,
                  value: cfg.intervalSec.toDouble(),
                  onChanged: (v) => policy(() => cfg.intervalSec = v.round()),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _ev(double v) => v.abs() < 0.05
      ? '±0'
      : '${v > 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)}';
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.child,
    this.mixed = false,
    this.value,
  });
  final String label;
  final Widget child;
  final bool mixed;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              if (mixed) ...[
                const SizedBox(width: 8),
                const StatusPill('Mixed', color: Status.syncing),
              ],
              const Spacer(),
              if (value != null)
                Text(
                  value!,
                  style: mono(
                    size: 13,
                    color: t.accent,
                    weight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: child),
        ],
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch(
    this.title,
    this.subtitle,
    this.value,
    this.mixed,
    this.onChanged,
  );
  final String title;
  final String subtitle;
  final bool value;
  final bool mixed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Row(
      children: [
        Flexible(child: Text(title)),
        if (mixed) ...[
          const SizedBox(width: 8),
          const StatusPill('Mixed', color: Status.syncing),
        ],
      ],
    ),
    subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
    value: value,
    onChanged: onChanged,
  );
}

/// Horizontal scroll dial: the current value in the accent, a light haptic
/// tick per step.
class ValueDial extends StatefulWidget {
  const ValueDial({
    super.key,
    required this.values,
    required this.value,
    required this.format,
    required this.onChanged,
  });
  final List<double> values;
  final double value;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  State<ValueDial> createState() => _ValueDialState();
}

class _ValueDialState extends State<ValueDial> {
  late final FixedExtentScrollController _c = FixedExtentScrollController(
    initialItem: _index(widget.value),
  );

  int _index(double v) {
    var best = 0;
    for (var i = 0; i < widget.values.length; i++) {
      if ((widget.values[i] - v).abs() < (widget.values[best] - v).abs()) {
        best = i;
      }
    }
    return best;
  }

  @override
  void didUpdateWidget(ValueDial old) {
    super.didUpdateWidget(old);
    final i = _index(widget.value);
    if (_c.hasClients &&
        _c.selectedItem != i &&
        !_c.position.isScrollingNotifier.value) {
      _c.jumpToItem(i);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    final sel = _index(widget.value);
    return SizedBox(
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              color: t.surfaceHigh,
              borderRadius: BorderRadius.circular(SyncTheme.radius),
            ),
          ),
          RotatedBox(
            quarterTurns: 3,
            child: ListWheelScrollView.useDelegate(
              controller: _c,
              itemExtent: 64,
              diameterRatio: 3,
              physics: const FixedExtentScrollPhysics(),
              onSelectedItemChanged: (i) {
                if (widget.values[i] == widget.values[_index(widget.value)]) {
                  return;
                }
                Haptic.tick();
                widget.onChanged(widget.values[i]);
              },
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: widget.values.length,
                builder: (context, i) => RotatedBox(
                  quarterTurns: 1,
                  child: Center(
                    child: Text(
                      widget.format(widget.values[i]),
                      style: mono(
                        size: i == sel ? 16 : 13,
                        color: i == sel ? t.accent : t.muted,
                        weight: i == sel ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Container(
              width: 70,
              decoration: BoxDecoration(
                border: Border.all(color: t.accent.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
