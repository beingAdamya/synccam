import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/clock.dart';
import '../core/util.dart';
import '../core/widgets.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_node.dart';

/// Full-screen viewfinder shown on a phone that has joined a session as a
/// camera. Everything is driven by the host; the local UI only shows state.
class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key, required this.node});
  final CameraNode node;

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> with WidgetsBindingObserver {
  Timer? _ticker;
  bool _dimmed = false;
  bool _closing = false;
  bool _grid = false;

  /// The screen flashes this camera's colour once when it joins.
  bool _joinFlash = false;
  LinkState? _lastLink;

  CameraNode get node => widget.node;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.enable();
    node.addListener(_changed);
    node.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (node.countdownTargetLocalUs != null) setState(() {});
    });
  }

  void _changed() {
    if (!mounted) return;
    if (node.link == LinkState.connected && _lastLink != LinkState.connected) _flashJoin();
    _lastLink = node.link;
    setState(() {});
    if (node.ended == 'host' && !_closing) {
      _closing = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('The shoot has ended'),
          content: const Text('The host ended this session. Anything you captured is saved in Photos '
              '(SyncCam album) and was sent to the host.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      ).then((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _flashJoin() async {
    // Wait for the rig to assign this camera its number.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || MediaQuery.of(context).disableAnimations) return;
    HapticFeedback.lightImpact();
    setState(() => _joinFlash = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) setState(() => _joinFlash = false);
  }

  Future<void> _confirmLeave() async {
    if (_closing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the rig?'),
        content: Text(node.recording
            ? 'This camera is recording. Leaving stops and saves its clip.'
            : 'This camera will leave the rig.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _closing = true;
    await node.leave();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    node.onLifecycle(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    node.removeListener(_changed);
    node.dispose();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = node.controller;
    final identify = node.identifyUntil != null && DateTime.now().isBefore(node.identifyUntil!);
    final color = CameraColors.forSlot(node.slot);
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized)
              Center(child: CameraPreview(c, child: _grid || node.settings.showGrid ? const _Grid() : null))
            else if (node.lastError != null && node.controller == null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(node.cameraBlocked ? Icons.no_photography_rounded : Icons.error_outline_rounded,
                        size: 48, color: Colors.white54),
                    const SizedBox(height: 12),
                    Text(node.lastError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: node.retryCamera,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                  ]),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),
            // The camera's own colour as a thin frame, so people across a
            // room can match it to its tile; red while recording.
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: node.recording ? Status.recording : color, width: node.recording ? 4 : 3),
                ),
              ),
            ),
            SafeArea(child: _overlay(context, color)),
            if (_countdownText() case final t?)
              IgnorePointer(
                child: Center(
                  child: Text(t,
                      style: mono(size: 120, color: Colors.white, weight: FontWeight.w600)
                          .copyWith(shadows: const [Shadow(blurRadius: 24)])),
                ),
              ),
            if (identify || _joinFlash)
              IgnorePointer(
                child: Container(
                  color: color,
                  alignment: Alignment.center,
                  child: Text('${node.slot + 1}',
                      style: TextStyle(fontSize: 200, fontWeight: FontWeight.w800, color: CameraColors.on(color))),
                ),
              ),
            if (_dimmed)
              GestureDetector(
                onTap: () => setState(() => _dimmed = false),
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Opacity(opacity: 0.5, child: NumberBadge(node.slot, size: 64)),
                    const SizedBox(height: 16),
                    Text(node.recording ? 'Recording' : 'Standby',
                        style: TextStyle(color: node.recording ? Status.recording : Colors.white38, fontSize: 18)),
                    const SizedBox(height: 8),
                    const Text('Tap to wake', style: TextStyle(color: Colors.white24)),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _countdownText() {
    final t = node.countdownTargetLocalUs;
    if (t == null) return null;
    final remain = (t - MonoClock.nowUs()) / 1e6;
    if (remain <= 0 || remain < 0.9) return null; // don't distract at the instant
    return remain.ceil().toString();
  }

  Widget _status() {
    final rec = node.recordStartLocalUs;
    if (node.link != LinkState.connected) {
      return const StatusPill('Lost: reconnecting', color: Status.lost, icon: Icons.link_off_rounded, outlined: true, big: true);
    }
    if (rec != null) {
      return Every(const Duration(milliseconds: 500),
          builder: (_) => StatusPill('Recording ${formatDuration(Duration(microseconds: MonoClock.nowUs() - rec))}',
              color: Status.recording, icon: Icons.fiber_manual_record_rounded, big: true));
    }
    final clock = node.clock;
    if (clock == null || !clock.isSynced || node.controller == null) {
      return const StatusPill('Syncing…', color: Status.syncing, icon: Icons.sync_rounded, big: true);
    }
    return const StatusPill('Ready', color: Status.ready, icon: Icons.check_circle_rounded, big: true);
  }

  Widget _overlay(BuildContext context, Color color) {
    Widget glassButton(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: VideoGlass(
            radius: 24,
            child: IconButton(
              tooltip: tip,
              icon: Icon(icon, color: on ? context.sync.accent : Colors.white),
              onPressed: onTap,
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NumberBadge(node.slot, size: 96),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(node.identity.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 8)])),
                if (node.sessionName.isNotEmpty)
                  Text(node.sessionName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, shadows: [Shadow(blurRadius: 8)])),
                const SizedBox(height: 8),
                _status(),
              ]),
            ),
          ]),
          const Spacer(),
          if (node.lastError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(node.lastError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Status.warning, fontSize: 12, shadows: [Shadow(blurRadius: 6)])),
            ),
          Row(children: [
            VideoGlass(
              radius: 24,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16)),
                onPressed: _confirmLeave,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Leave rig'),
              ),
            ),
            const Spacer(),
            if (node.pendingUploads > 0)
              VideoGlass(
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.upload_rounded, size: 16, color: Colors.white),
                  const SizedBox(width: 4),
                  Text('${node.pendingUploads}', style: mono(size: 13, color: Colors.white)),
                ]),
              ),
            glassButton(Icons.grid_3x3_rounded, _grid ? 'Hide grid' : 'Show framing grid', () => setState(() => _grid = !_grid),
                on: _grid),
            glassButton(Icons.brightness_2_rounded, 'Darken the screen (keeps recording)',
                () => setState(() => _dimmed = true)),
          ]),
          const SizedBox(height: 6),
          const Text('The controlling phone decides everything else.',
              style: TextStyle(color: Colors.white54, fontSize: 12, shadows: [Shadow(blurRadius: 6)])),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GridPainter(), size: Size.infinite);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), p);
      canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
