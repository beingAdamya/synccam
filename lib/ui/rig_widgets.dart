import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/protocol.dart';
import '../host/host_server.dart';
import 'cam_status.dart';
import 'theme.dart';
import 'widgets.dart';

/// The one shutter: a 76pt circle that never moves.
///
/// Photo is a white disc, Video a red disc that becomes a rounded square
/// while recording, Burst a disc with three ticks. Taps are recognised only
/// as taps, so a scroll or brush never fires it, and stopping a recording
/// longer than 10 s needs a press-and-hold.
class Shutter extends StatefulWidget {
  const Shutter({
    super.key,
    required this.mode,
    required this.active,
    required this.enabled,
    required this.onPressed,
    this.disabledReason,
    this.holdToStop = false,
    this.countdown,
  });
  final CaptureMode mode;
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;
  final String? disabledReason;

  /// Require a 0.6 s hold (used to stop long recordings).
  final bool holdToStop;

  /// 0..1 progress of a running 3-2-1 countdown, shown as a ring.
  final double? countdown;

  @override
  State<Shutter> createState() => _ShutterState();
}

class _ShutterState extends State<Shutter> with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _hold.reset();
          Haptic.shutter();
          widget.onPressed();
        }
      });
  bool _down = false;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _tap() {
    if (!widget.enabled) {
      if (widget.disabledReason != null) {
        showSnack(context, widget.disabledReason!);
      }
      return;
    }
    if (widget.holdToStop) {
      showSnack(context, 'Press and hold to stop recording.');
      return;
    }
    Haptic.shutter();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final video =
        widget.mode == CaptureMode.video || widget.mode == CaptureMode.interval;
    final ring = widget.enabled ? Colors.white : Colors.white30;
    final disc = !widget.enabled
        ? Colors.white24
        : video
        ? Status.recording
        : Colors.white;
    final label = switch ((video, widget.active)) {
      (true, true) => 'Stop recording',
      (true, false) => 'Start recording',
      _ => widget.mode == CaptureMode.burst ? 'Shoot burst' : 'Shoot',
    };
    return Semantics(
      button: true,
      label: label,
      enabled: widget.enabled,
      child: GestureDetector(
        onTap: _tap,
        onLongPressStart: widget.holdToStop && widget.enabled
            ? (_) => _hold.forward()
            : null,
        onLongPressEnd: widget.holdToStop ? (_) => _hold.reverse() : null,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedScale(
          scale: _down ? 0.94 : 1,
          duration: const Duration(milliseconds: 120),
          child: SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ring, width: 4),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  width: widget.active ? 30 : 60,
                  height: widget.active ? 30 : 60,
                  decoration: BoxDecoration(
                    color: disc,
                    borderRadius: BorderRadius.circular(widget.active ? 8 : 30),
                  ),
                ),
                if (widget.mode == CaptureMode.burst && !widget.active)
                  for (var i = -1; i <= 1; i++)
                    Transform.translate(
                      offset: Offset(i * 9.0, 0),
                      child: Container(
                        width: 3,
                        height: 16,
                        color: Colors.black54,
                      ),
                    ),
                AnimatedBuilder(
                  animation: _hold,
                  builder: (_, _) => _hold.value == 0
                      ? const SizedBox()
                      : SizedBox(
                          width: 76,
                          height: 76,
                          child: CircularProgressIndicator(
                            value: _hold.value,
                            strokeWidth: 4,
                            color: Status.recording,
                          ),
                        ),
                ),
                if (widget.countdown != null)
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: CircularProgressIndicator(
                      value: widget.countdown,
                      strokeWidth: 4,
                      color: context.sync.accent,
                      backgroundColor: Colors.white12,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "±0.8 ms" with a 5-segment bar: green under 2 ms, amber to 10, orange above.
class SyncMeter extends StatelessWidget {
  const SyncMeter({super.key, required this.server, this.onTap});
  final HostServer server;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final online = server.onlineDevices.where((d) => d.synced).toList();
    if (online.isEmpty) {
      return Text('±— ms', style: mono(size: 12, color: Colors.white54));
    }
    final worst = online.map((d) => d.errMs).reduce(math.max);
    final color = worst < 2
        ? Status.ready
        : worst <= driftLimitMs
        ? Status.syncing
        : Status.warning;
    final segs = worst < 1
        ? 5
        : worst < 2
        ? 4
        : worst < 5
        ? 3
        : worst <= driftLimitMs
        ? 2
        : 1;
    return Semantics(
      label: 'All cameras fire within ${worst.toStringAsFixed(1)} milliseconds',
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 5; i++)
                Container(
                  width: 4,
                  height: 6.0 + i * 2,
                  margin: const EdgeInsets.only(right: 2),
                  decoration: BoxDecoration(
                    color: i < segs ? color : Colors.white24,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              const SizedBox(width: 4),
              Text(
                '±${worst.toStringAsFixed(1)} ms',
                style: mono(size: 12, color: color, weight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "6 of 6 ready" in green, or "5 of 6 ready" in amber; tap lists who
/// isn't ready and the one fix for each.
class ReadyCounter extends StatelessWidget {
  const ReadyCounter({super.key, required this.server});
  final HostServer server;

  @override
  Widget build(BuildContext context) {
    final all = server.devices;
    final ready = all.where((d) => statusOf(d).isReady).length;
    final ok = all.isNotEmpty && ready == all.length;
    final color = all.isEmpty
        ? Colors.white60
        : (ok ? Status.ready : Status.syncing);
    return Semantics(
      button: true,
      label: '$ready of ${all.length} cameras ready',
      child: InkWell(
        borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
        onTap: all.isEmpty ? null : () => showNotReadySheet(context, server),
        child: StatusPill(
          all.isEmpty ? 'No cameras' : '$ready of ${all.length} ready',
          color: color,
          icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
        ),
      ),
    );
  }
}

void showNotReadySheet(BuildContext context, HostServer server) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final list = notReady(server);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                list.isEmpty ? 'Every camera is ready' : 'Not ready yet',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                Text(
                  'All cameras fire within a few milliseconds of each other.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              for (final (d, s) in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        NumberBadge(d.slot),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      d.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  StatusPill(
                                    s.word,
                                    color: s.color,
                                    icon: s.icon,
                                    outlined: s.state == CamState.lost,
                                  ),
                                ],
                              ),
                              if (s.fix != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  s.fix!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
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

/// After a settings change: each camera's badge with a spinner, a green
/// tick, or an orange note saying what it used instead. Fades after 2 s.
class ApplyRow extends StatefulWidget {
  const ApplyRow({super.key, required this.server});
  final HostServer server;

  @override
  State<ApplyRow> createState() => _ApplyRowState();
}

class _ApplyRowState extends State<ApplyRow> {
  Timer? _fade;
  bool _visible = false;
  int _lastSeq = 0;

  @override
  void initState() {
    super.initState();
    widget.server.addListener(_check);
  }

  @override
  void dispose() {
    _fade?.cancel();
    widget.server.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final devs = widget.server.onlineDevices;
    if (devs.isEmpty) return;
    final top = devs.map((d) => d.sentSeq).reduce(math.max);
    final busy = devs.any((d) => d.applying);
    if (top != _lastSeq && busy) {
      _lastSeq = top;
      _fade?.cancel();
      setState(() => _visible = true);
    } else if (_visible && !busy && (_fade == null || !_fade!.isActive)) {
      final hasNotes = devs.any((d) => d.appliedNote != null);
      _fade = Timer(Duration(seconds: hasNotes ? 4 : 2), () {
        if (mounted) setState(() => _visible = false);
      });
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final devs = widget.server.onlineDevices;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: !_visible || devs.isEmpty
          ? const SizedBox(key: ValueKey(0))
          : Wrap(
              key: const ValueKey(1),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in devs)
                  Container(
                    padding: const EdgeInsets.fromLTRB(3, 3, 8, 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NumberBadge(d.slot, size: 22),
                        const SizedBox(width: 5),
                        if (d.applying)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          )
                        else if (d.appliedNote != null) ...[
                          const Icon(
                            Icons.info_rounded,
                            size: 14,
                            color: Status.warning,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            d.appliedNote!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Status.warning,
                            ),
                          ),
                        ] else
                          const Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: Status.ready,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

String resLabel(ResChoice r) => switch (r) {
  ResChoice.low => '240p',
  ResChoice.medium => '480p',
  ResChoice.high => '720p',
  ResChoice.veryHigh => '1080p',
  ResChoice.ultraHigh => '4K',
  ResChoice.max => 'Max',
};
