import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'host_server.dart';
import 'take.dart';
import 'take_screen.dart';

/// A millisecond clock to point every camera at. Fire a test shot, then read
/// the clock in each phone's photo: the differences are each phone's real
/// shutter latency, which the take screen turns into per-device trims.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.server});
  final HostServer server;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}))..start();
  Take? _last;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = (widget.server.nowUs() ~/ 1000) % 60000;
    final sec = ms ~/ 1000;
    final milli = ms % 1000;
    final hundreds = milli ~/ 100;
    final tens = (milli ~/ 10) % 10;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Sync calibration')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: FittedBox(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    Text(
                      '${sec.toString().padLeft(2, '0')}.${milli.toString().padLeft(3, '0')}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 120,
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    _blocks(hundreds, Colors.cyanAccent),
                    const SizedBox(height: 8),
                    _blocks(tens, Colors.amberAccent),
                  ]),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Point every camera at this screen, then fire a test shot. The top bar shows hundreds '
                'of ms, the bottom bar tens. Screen refresh limits precision to about one frame (8–16 ms).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.server.onlineDevices.isEmpty
                        ? null
                        : () => setState(() => _last = widget.server.testShot()),
                    icon: const Icon(Icons.camera),
                    label: const Text('Test shot'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _last == null
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                  builder: (_) => TakeScreen(server: widget.server, take: _last!, calibrate: true)),
                            ),
                    icon: const Icon(Icons.tune),
                    label: const Text('Review & calibrate'),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blocks(int lit, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 10; i++)
            Container(
              width: 56,
              height: 40,
              margin: const EdgeInsets.all(3),
              color: i == lit ? color : Colors.white10,
              alignment: Alignment.center,
              child: Text('$i', style: TextStyle(color: i == lit ? Colors.black : Colors.white24, fontSize: 18)),
            ),
        ],
      );
}
