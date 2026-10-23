import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Serializes async camera operations so a settings change can never race a
/// scheduled capture.
class AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// A short 2 kHz tone burst as a 16-bit mono WAV, used for the audio slate.
/// A sharp, loud transient is easy to spot on a waveform and gives audio
/// cross-correlation a clean peak.
Uint8List slateWav({int ms = 120, int hz = 2000, int rate = 44100}) {
  final n = rate * ms ~/ 1000;
  final data = ByteData(44 + n * 2);
  void str(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    // 2 ms fade in/out avoids clicks that smear the transient.
    final env = min(1.0, min(i, n - i) / (rate * 0.002));
    final s = sin(2 * pi * hz * i / rate) * env * 0.95;
    data.setInt16(44 + i * 2, (s * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Non-loopback IPv4 addresses of this device (Wi-Fi, hotspot, ethernet).
Future<List<String>> localIPv4s() async {
  final out = <String>[];
  try {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
  } catch (_) {}
  // Prefer typical LAN / hotspot ranges first.
  int rank(String ip) => ip.startsWith('192.168.')
      ? 0
      : ip.startsWith('172.20.10.') // iPhone hotspot
          ? 1
          : ip.startsWith('10.')
              ? 2
              : 3;
  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return out;
}

String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
