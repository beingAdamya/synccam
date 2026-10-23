import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'protocol.dart';

/// Monotonic microsecond clock anchored to wall time at app start.
///
/// DateTime.now() can jump when the OS adjusts the clock (NTP, carrier time),
/// which would wreck a scheduled capture. A Stopwatch never jumps, so all
/// sync math uses this instead.
class MonoClock {
  static final int _epochUs = DateTime.now().microsecondsSinceEpoch;
  static final Stopwatch _sw = Stopwatch()..start();

  static int nowUs() => _epochUs + _sw.elapsedMicroseconds;
}

/// Sleeps coarsely, then busy-waits the last few milliseconds so the action
/// fires within ~0.1 ms of [targetLocalUs] (Dart timers alone jitter by
/// several ms).
Future<void> waitUntilLocal(int targetLocalUs) async {
  const spinWindowUs = 12000;
  while (true) {
    final remaining = targetLocalUs - MonoClock.nowUs();
    if (remaining <= 0) return;
    if (remaining <= spinWindowUs) break;
    await Future<void>.delayed(Duration(microseconds: remaining - spinWindowUs));
  }
  while (MonoClock.nowUs() < targetLocalUs) {
    // spin
  }
}

// Packet layout (little endian):
//   ping : 'P' u32 seq, i64 t0                     (13 bytes)
//   pong : 'R' u32 seq, i64 t0, i64 t1, i64 t2     (29 bytes)
const int _ping = 0x50;
const int _pong = 0x52;

/// Runs on the host. Answers clock-sync pings with its receive/send times.
class ClockSyncServer {
  ClockSyncServer({int Function()? now, this.port = Net.udpPort}) : _now = now ?? MonoClock.nowUs;

  final int Function() _now;
  final int port;
  RawDatagramSocket? _socket;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      final t1 = _now();
      final d = dg.data;
      if (d.length != 13 || d[0] != _ping) return;
      final inBd = ByteData.sublistView(d);
      final out = ByteData(29)
        ..setUint8(0, _pong)
        ..setUint32(1, inBd.getUint32(1, Endian.little), Endian.little)
        ..setInt64(5, inBd.getInt64(5, Endian.little), Endian.little)
        ..setInt64(13, t1, Endian.little);
      out.setInt64(21, _now(), Endian.little);
      _socket!.send(out.buffer.asUint8List(), dg.address, dg.port);
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

class _Sample {
  _Sample(this.offsetUs, this.rttUs, this.atUs);
  final int offsetUs;
  final int rttUs;
  final int atUs;
}

/// Runs on every camera node. NTP-style offset estimation over UDP:
///
///   offset = ((t1 - t0) + (t2 - t3)) / 2     rtt = (t3 - t0) - (t2 - t1)
///
/// Samples with the lowest round-trip time suffer the least queuing delay,
/// so the estimate is the median offset of the fastest few recent samples.
/// On a normal Wi-Fi LAN this lands within ~1-3 ms of the host clock.
class ClockSyncClient {
  ClockSyncClient(this.host, {this.port = Net.udpPort});

  final InternetAddress host;
  final int port;
  RawDatagramSocket? _socket;
  Timer? _timer;
  int _seq = 0;
  final List<_Sample> _samples = [];

  int offsetUs = 0;
  int bestRttUs = 0;
  bool get isSynced => _samples.length >= 8;

  /// Upper bound on clock error: half the best round trip.
  double get errorMs => bestRttUs / 2000.0;
  void Function()? onUpdate;

  int hostNowUs() => MonoClock.nowUs() + offsetUs;
  int hostToLocal(int hostUs) => hostUs - offsetUs;
  int localToHost(int localUs) => localUs + offsetUs;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.listen(_onEvent);
    // Fast initial burst so we are synced within ~1 s of joining.
    _burst(30, 25);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _burst(8, 30));
  }

  void _burst(int count, int spacingMs) {
    for (var i = 0; i < count; i++) {
      Timer(Duration(milliseconds: i * spacingMs), _sendPing);
    }
  }

  void _sendPing() {
    final s = _socket;
    if (s == null) return;
    final bd = ByteData(13)
      ..setUint8(0, _ping)
      ..setUint32(1, _seq++, Endian.little)
      ..setInt64(5, MonoClock.nowUs(), Endian.little);
    s.send(bd.buffer.asUint8List(), host, port);
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final t3 = MonoClock.nowUs();
    final d = dg.data;
    if (d.length != 29 || d[0] != _pong) return;
    final bd = ByteData.sublistView(d);
    final t0 = bd.getInt64(5, Endian.little);
    final t1 = bd.getInt64(13, Endian.little);
    final t2 = bd.getInt64(21, Endian.little);
    final rtt = (t3 - t0) - (t2 - t1);
    if (rtt < 0 || rtt > 500000) return;
    final offset = ((t1 - t0) + (t2 - t3)) ~/ 2;
    _samples.add(_Sample(offset, rtt, t3));
    _recompute();
  }

  void _recompute() {
    // Keep a 30 s window so slow oscillator drift is tracked.
    final cutoff = MonoClock.nowUs() - 30000000;
    _samples.removeWhere((s) => s.atUs < cutoff);
    if (_samples.length > 200) _samples.removeRange(0, _samples.length - 200);
    if (_samples.isEmpty) return;
    final sorted = [..._samples]..sort((a, b) => a.rttUs.compareTo(b.rttUs));
    final best = sorted.take(max(1, min(5, sorted.length))).toList()
      ..sort((a, b) => a.offsetUs.compareTo(b.offsetUs));
    offsetUs = best[best.length ~/ 2].offsetUs;
    bestRttUs = sorted.first.rttUs;
    onUpdate?.call();
  }

  Future<void> restart() async {
    stop();
    _samples.clear();
    await start();
  }

  void stop() {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }
}
