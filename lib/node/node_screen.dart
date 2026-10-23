import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/clock.dart';
import '../core/util.dart';
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
      if (node.recording || node.countdownTargetLocalUs != null) setState(() {});
    });
  }

  void _changed() {
    if (mounted) setState(() {});
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (c != null && c.value.isInitialized)
            Center(child: CameraPreview(c, child: node.settings.showGrid ? const _Grid() : null))
          else
            const Center(child: CircularProgressIndicator()),
          SafeArea(child: _overlay(context)),
          if (_countdownText() case final t?)
            IgnorePointer(
              child: Center(
                child: Text(t,
                    style: const TextStyle(
                        fontSize: 120,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 24)])),
              ),
            ),
          if (identify)
            Container(
              color: Colors.white,
              alignment: Alignment.center,
              child: Text('#${node.slot + 1}\n${node.identity.name}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Colors.black)),
            ),
          if (_dimmed)
            GestureDetector(
              onTap: () => setState(() => _dimmed = false),
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: Text(
                  '${node.identity.name}\n${node.recording ? '● REC' : 'Standby'}\n\nTap to wake',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: node.recording ? Colors.red : Colors.white24, fontSize: 18),
                ),
              ),
            ),
        ],
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

  Widget _overlay(BuildContext context) {
    final clock = node.clock;
    final linkColor = switch (node.link) {
      LinkState.connected => Colors.greenAccent,
      LinkState.connecting => Colors.amber,
      LinkState.disconnected => Colors.redAccent,
    };
    final rec = node.recordStartLocalUs;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _chip(Icons.circle, linkColor,
                  '#${node.slot + 1} ${node.identity.name}${node.sessionName.isEmpty ? '' : ' · ${node.sessionName}'}'),
              const Spacer(),
              if (clock != null)
                _chip(Icons.sync, clock.isSynced ? Colors.greenAccent : Colors.amber,
                    clock.isSynced ? '±${clock.errorMs.toStringAsFixed(1)} ms' : 'syncing…'),
            ],
          ),
        ),
        if (rec != null)
          _chip(Icons.fiber_manual_record, Colors.red,
              'REC ${formatDuration(Duration(microseconds: MonoClock.nowUs() - rec))}'),
        const Spacer(),
        if (node.lastError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(node.lastError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'Leave session',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.logout),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Dim screen (saves battery, keeps recording)',
                onPressed: () => setState(() => _dimmed = true),
                icon: const Icon(Icons.brightness_2),
              ),
              const Spacer(),
              _chip(Icons.photo_library, Colors.white70, '${node.capturesThisSession}'),
              if (node.pendingUploads > 0) ...[
                const SizedBox(width: 8),
                _chip(Icons.upload, Colors.lightBlueAccent, '${node.pendingUploads}'),
              ],
            ],
          ),
        ),
        const Text('Controlled by host', style: TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _chip(IconData icon, Color color, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ]),
      );
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
