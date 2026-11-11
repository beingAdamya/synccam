import 'dart:typed_data';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../core/util.dart';
import '../core/widgets.dart';
import '../ui/cam_status.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'host_server.dart';

/// Live view of one remote camera. Rebuilds only when that camera's frame
/// changes, so a dozen tiles stay cheap.
class LiveView extends StatelessWidget {
  const LiveView({
    super.key,
    required this.device,
    this.fit = BoxFit.cover,
    this.grey = false,
  });
  final RemoteDevice device;
  final BoxFit fit;

  /// Desaturated (a lost camera keeps its last frame, greyed).
  final bool grey;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: device.frame,
      builder: (context, jpeg, _) {
        if (jpeg == null) {
          return const ColoredBox(
            color: Color(0xFF050507),
            child: Center(
              child: Icon(
                Icons.videocam_off_rounded,
                color: Colors.white24,
                size: 36,
              ),
            ),
          );
        }
        Widget img = RotatedBox(
          quarterTurns: device.viewTurns,
          child: Image.memory(
            jpeg,
            fit: fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        );
        if (grey) {
          img = ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              0.2, 0.6, 0.1, 0, 0, //
              0.2, 0.6, 0.1, 0, 0,
              0.2, 0.6, 0.1, 0, 0,
              0, 0, 0, 0.55, 0,
            ]),
            child: img,
          );
        }
        return ColoredBox(color: const Color(0xFF050507), child: img);
      },
    );
  }
}

/// One camera on the live wall: picture first, with its number, status,
/// and only the warnings that matter, kept to the edges.
class CameraTile extends StatelessWidget {
  const CameraTile({
    super.key,
    required this.device,
    required this.server,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.flash,
    this.overlays = true,
    this.fit = BoxFit.cover,
  });
  final RemoteDevice device;
  final HostServer server;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;

  /// Fires when every tile should flash at once (capture proof).
  final ValueNotifier<int>? flash;

  /// False hides the badges so nothing covers the picture.
  final bool overlays;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final d = device;
        final st = statusOf(d);
        final identity = CameraColors.forSlot(d.slot);
        final edge = switch (st.state) {
          CamState.recording => Status.recording,
          CamState.warning => Status.warning,
          CamState.lost => Status.lost,
          _ => identity,
        };
        final lowBattery = d.battery != null && d.battery! < 20 && !d.charging;
        final lowSpace = d.lowStorage;
        return Semantics(
          label: semanticsLabel(d),
          button: true,
          child: GestureDetector(
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onLongPress: onLongPress,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(SyncTheme.tileRadius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LiveView(device: d, grey: !d.online, fit: fit),
                  if (flash != null) _FlashLayer(flash!),
                  if (!d.online)
                    const Center(
                      child: StatusPill(
                        'Reconnecting…',
                        color: Status.lost,
                        icon: Icons.link_off_rounded,
                        outlined: true,
                      ),
                    ),
                  if (d.online &&
                      d.recording &&
                      d.recStartHostUs != null &&
                      overlays)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: Every(
                          const Duration(milliseconds: 500),
                          builder: (_) => _MonoChip(
                            formatDuration(
                              Duration(
                                microseconds:
                                    server.nowUs() - d.recStartHostUs!,
                              ),
                            ),
                            color: Status.recording,
                          ),
                        ),
                      ),
                    ),
                  if (overlays) ...[
                    Positioned(
                      left: 6,
                      top: 6,
                      right: 6,
                      child: Row(
                        children: [
                          NumberBadge(d.slot),
                          if (d.override.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: t.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: StatusPill(
                                st.reason != null &&
                                        st.state == CamState.warning
                                    ? st.reason!
                                    : st.word,
                                color: st.color,
                                icon: st.icon,
                                outlined: st.state == CamState.lost,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (lowBattery || lowSpace)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Row(
                          children: [
                            if (lowBattery)
                              _MonoChip(
                                '${d.battery}%',
                                color: Status.warning,
                                icon: Icons.battery_alert_rounded,
                              ),
                            if (lowBattery && lowSpace)
                              const SizedBox(width: 4),
                            if (lowSpace)
                              _MonoChip(
                                formatBytes(d.freeBytes ?? 0),
                                color: Status.warning,
                                icon: Icons.sd_card_alert_outlined,
                              ),
                          ],
                        ),
                      ),
                  ],
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _EdgePainter(
                        color: edge,
                        width:
                            st.state == CamState.recording ||
                                st.state == CamState.warning
                            ? t.statusBorder + 0.5
                            : t.statusBorder,
                        dashed: st.state == CamState.lost,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FlashLayer extends StatefulWidget {
  const _FlashLayer(this.flash);
  final ValueNotifier<int> flash;
  @override
  State<_FlashLayer> createState() => _FlashLayerState();
}

class _FlashLayerState extends State<_FlashLayer> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    widget.flash.addListener(_go);
  }

  @override
  void dispose() {
    widget.flash.removeListener(_go);
    super.dispose();
  }

  Future<void> _go() async {
    if (MediaQuery.of(context).disableAnimations) return;
    setState(() => _on = true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (mounted) setState(() => _on = false);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ColoredBox(
      color: _on ? Colors.white.withValues(alpha: 0.3) : Colors.transparent,
    ),
  );
}

class _MonoChip extends StatelessWidget {
  const _MonoChip(this.text, {required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
        ],
        Text(
          text,
          style: mono(size: 11, color: color, weight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.color,
    required this.width,
    required this.dashed,
  });
  final Color color;
  final double width;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(width / 2),
      const Radius.circular(SyncTheme.tileRadius),
    );
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (!dashed) {
      canvas.drawRRect(r, p);
      return;
    }
    final path = Path()..addRRect(r);
    for (final PathMetric m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 12) {
        canvas.drawPath(m.extractPath(d, d + 7), p);
      }
    }
  }

  @override
  bool shouldRepaint(_EdgePainter o) =>
      o.color != color || o.width != width || o.dashed != dashed;
}
