import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/util.dart';
import 'host_server.dart';

/// Live view of one remote camera. Rebuilds only when that camera's frame or
/// status changes, so a dozen tiles stay cheap.
class LiveView extends StatelessWidget {
  const LiveView({super.key, required this.device, this.fit = BoxFit.cover});
  final RemoteDevice device;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: device.frame,
      builder: (context, jpeg, _) {
        if (jpeg == null) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: Icon(Icons.videocam_off, color: Colors.white24, size: 40)),
          );
        }
        return ColoredBox(
          color: Colors.black,
          child: RotatedBox(
            quarterTurns: device.viewTurns,
            child: Image.memory(jpeg, fit: fit, gaplessPlayback: true, filterQuality: FilterQuality.low),
          ),
        );
      },
    );
  }
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.device, required this.server, this.onTap});
  final RemoteDevice device;
  final HostServer server;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final d = device;
        final syncColor = !d.synced
            ? Colors.amber
            : d.errMs < 3
                ? Colors.greenAccent
                : d.errMs < 10
                    ? Colors.amber
                    : Colors.redAccent;
        return GestureDetector(
          onTap: onTap,
          onLongPress: () => server.identify(d),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Opacity(opacity: d.online ? 1 : 0.35, child: LiveView(device: d)),
                if (d.recording)
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.red, width: 3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                Positioned(
                  left: 6,
                  top: 6,
                  right: 6,
                  child: Row(
                    children: [
                      _badge('${d.slot + 1}', Colors.white, bg: Colors.blueGrey.shade700),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(d.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)])),
                      ),
                      if (d.override.isNotEmpty) const Icon(Icons.tune, size: 14, color: Colors.lightBlueAccent),
                      if (d.error != null) const Icon(Icons.warning_amber, size: 14, color: Colors.orangeAccent),
                    ],
                  ),
                ),
                Positioned(
                  left: 6,
                  bottom: 6,
                  right: 6,
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      if (!d.online)
                        _badge('offline', Colors.redAccent)
                      else ...[
                        _badge(d.synced ? '±${d.errMs.toStringAsFixed(1)}ms' : 'sync…', syncColor),
                        if (d.battery != null)
                          _badge('${d.charging ? '⚡' : ''}${d.battery}%',
                              d.battery! < 20 ? Colors.redAccent : Colors.white70),
                        if (d.recording)
                          _badge(
                              d.recStartHostUs == null
                                  ? '● REC'
                                  : '● ${formatDuration(Duration(microseconds: server.nowUs() - d.recStartHostUs!))}',
                              Colors.red),
                        if (d.pendingUploads > 0) _badge('↑${d.pendingUploads}', Colors.lightBlueAccent),
                        if (d.hot) _badge(d.thermal == 'critical' ? '🔥 critical' : '🔥 hot', Colors.deepOrangeAccent),
                        if (d.lowPower) _badge('low power', Colors.amber),
                        if (d.freeBytes != null)
                          _badge(formatBytes(d.freeBytes!), d.lowStorage ? Colors.redAccent : Colors.white54),
                        if (d.trimMs != 0) _badge('trim ${d.trimMs.toStringAsFixed(0)}ms', Colors.white54),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _badge(String text, Color fg, {Color? bg}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg ?? Colors.black54, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}
