import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Turns raw camera stream frames (YUV420 on Android, BGRA on iOS) into small
/// JPEGs for the host's live view. Work runs on a long-lived background
/// isolate; if a frame is still being encoded the next one is dropped, so the
/// camera pipeline is never blocked.
class FrameEncoder {
  Isolate? _isolate;
  SendPort? _toWorker;
  final ReceivePort _fromWorker = ReceivePort();
  Completer<Uint8List?>? _pending;

  bool get busy => _pending != null;

  Future<void> start() async {
    final ready = Completer<SendPort>();
    _fromWorker.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else {
        final c = _pending;
        _pending = null;
        c?.complete(msg is TransferableTypedData ? msg.materialize().asUint8List() : null);
      }
    });
    _isolate = await Isolate.spawn(_workerMain, _fromWorker.sendPort);
    _toWorker = await ready.future;
  }

  /// Returns null if busy or the format is unsupported.
  Future<Uint8List?> encode(
    CameraImage image, {
    required int rotation,
    required bool mirror,
    int maxDim = 360,
    int quality = 55,
  }) {
    final port = _toWorker;
    if (port == null || _pending != null) return Future.value(null);
    final group = image.format.group;
    if (group != ImageFormatGroup.yuv420 && group != ImageFormatGroup.bgra8888) {
      return Future.value(null);
    }
    _pending = Completer<Uint8List?>();
    port.send({
      'fmt': group == ImageFormatGroup.bgra8888 ? 'bgra' : 'yuv',
      'w': image.width,
      'h': image.height,
      'planes': [for (final p in image.planes) TransferableTypedData.fromList([p.bytes])],
      'rows': [for (final p in image.planes) p.bytesPerRow],
      'pix': [for (final p in image.planes) p.bytesPerPixel ?? 1],
      'rot': rotation,
      'mirror': mirror,
      'max': maxDim,
      'q': quality,
    });
    return _pending!.future;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _fromWorker.close();
    _pending?.complete(null);
    _pending = null;
  }
}

void _workerMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((m) {
    try {
      final jpeg = _convert(m as Map);
      out.send(TransferableTypedData.fromList([jpeg]));
    } catch (_) {
      out.send(null);
    }
  });
}

Uint8List _convert(Map m) {
  final w = m['w'] as int;
  final h = m['h'] as int;
  final planes = [
    for (final t in (m['planes'] as List)) (t as TransferableTypedData).materialize().asUint8List()
  ];
  final rows = (m['rows'] as List).cast<int>();
  final pix = (m['pix'] as List).cast<int>();
  final maxDim = m['max'] as int;
  final step = max(1, (max(w, h) / maxDim).ceil());
  final ow = w ~/ step;
  final oh = h ~/ step;
  final rgb = Uint8List(ow * oh * 3);
  var o = 0;

  if (m['fmt'] == 'bgra') {
    final p = planes[0];
    final row = rows[0];
    for (var oy = 0; oy < oh; oy++) {
      final base = oy * step * row;
      for (var ox = 0; ox < ow; ox++) {
        final i = base + ox * step * 4;
        rgb[o++] = p[i + 2];
        rgb[o++] = p[i + 1];
        rgb[o++] = p[i];
      }
    }
  } else {
    final yP = planes[0], uP = planes[1], vP = planes[2];
    final yRow = rows[0], uvRow = rows[1], uvPix = pix[1];
    for (var oy = 0; oy < oh; oy++) {
      final sy = oy * step;
      final yBase = sy * yRow;
      final uvBase = (sy >> 1) * uvRow;
      for (var ox = 0; ox < ow; ox++) {
        final sx = ox * step;
        final yv = yP[yBase + sx];
        final uvi = uvBase + (sx >> 1) * uvPix;
        final u = (uvi < uP.length ? uP[uvi] : 128) - 128;
        final v = (uvi < vP.length ? vP[uvi] : 128) - 128;
        rgb[o++] = (yv + 1.402 * v).round().clamp(0, 255);
        rgb[o++] = (yv - 0.344 * u - 0.714 * v).round().clamp(0, 255);
        rgb[o++] = (yv + 1.772 * u).round().clamp(0, 255);
      }
    }
  }

  var image = img.Image.fromBytes(width: ow, height: oh, bytes: rgb.buffer, numChannels: 3);
  final rot = m['rot'] as int;
  if (rot % 360 != 0) image = img.copyRotate(image, angle: rot);
  if (m['mirror'] == true) img.flipHorizontal(image);
  return img.encodeJpg(image, quality: m['q'] as int);
}
