import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'external_camera.dart';
import 'external_camera_screen.dart';
import 'host_server.dart';

/// A camera found on the network.
class FoundCamera {
  FoundCamera(this.host, this.port, this.name, this.kinds);
  final String host;
  final int port;
  final String name;

  /// What it could be. One entry when the camera said who it is; several
  /// for PTP/IP cameras, which the user picks from.
  final List<ExternalKind> kinds;
}

/// Looks for Wi-Fi cameras: each brand's usual address when the phone is on
/// the camera's own Wi-Fi, plus every address on this network, then asks
/// each open port who it is.
class CameraScanner {
  static const _connectTimeout = Duration(milliseconds: 350);

  static Future<List<FoundCamera>> scan(
    List<String> myAddresses, {
    void Function(double)? onProgress,
  }) async {
    final hosts = <String>{
      for (final k in ExternalKind.values)
        if (k.defaultHost.isNotEmpty) k.defaultHost,
    };
    for (final a in myAddresses) {
      final parts = a.split('.');
      if (parts.length != 4) continue;
      final net = parts.take(3).join('.');
      for (var i = 1; i < 255; i++) {
        final h = '$net.$i';
        if (h != a) hosts.add(h);
      }
    }
    const ports = [15740, 8080, 80];
    final jobs = [
      for (final h in hosts)
        for (final p in ports) (h, p),
    ];
    final open = <(String, int)>[];
    var done = 0;
    // A few dozen probes at a time keeps the phone's network stack happy.
    for (var i = 0; i < jobs.length; i += 48) {
      final batch = jobs.sublist(i, (i + 48).clamp(0, jobs.length));
      await Future.wait(
        batch.map((j) async {
          if (await _isOpen(j.$1, j.$2)) open.add(j);
        }),
      );
      done += batch.length;
      onProgress?.call(done / jobs.length);
    }
    final found = <FoundCamera>[];
    await Future.wait(
      open.map((o) async {
        final f = await identify(o.$1, o.$2);
        if (f != null) found.add(f);
      }),
    );
    found.sort((a, b) => a.name.compareTo(b.name));
    return found;
  }

  static Future<bool> _isOpen(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: _connectTimeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _get(String host, int port, String path) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await c.getUrl(
        Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: path.split('?').first,
          query: path.contains('?') ? path.split('?').last : null,
        ),
      );
      final res = await req.close().timeout(const Duration(seconds: 2));
      if (res.statusCode >= 400) {
        await res.drain<void>();
        return null;
      }
      return await utf8.decoder
          .bind(res)
          .join()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// Asks an open port who it is. Null when it isn't a camera SyncCam knows.
  @visibleForTesting
  static Future<FoundCamera?> identify(String host, int port) async {
    if (port == 15740) {
      // PTP/IP doesn't say the brand before pairing; the usual camera-Wi-Fi
      // addresses are a good hint.
      final hint = switch (host) {
        '192.168.122.1' => [ExternalKind.sonyPtp],
        '192.168.0.1' => [ExternalKind.fujifilm, ExternalKind.ptp],
        _ => [
          ExternalKind.nikon,
          ExternalKind.sonyPtp,
          ExternalKind.canonPtp,
          ExternalKind.fujifilm,
          ExternalKind.ptp,
        ],
      };
      return FoundCamera(
        host,
        port,
        hint.length == 1 ? '${hint.first.brand} camera' : 'Camera (PTP/IP)',
        hint,
      );
    }
    if (port == 8080) {
      final ccapi = await _get(host, port, '/ccapi');
      if (ccapi != null && ccapi.contains('ver1')) {
        final info = await _get(host, port, '/ccapi/ver100/deviceinformation');
        final name = _json(info)?['productname'] as String?;
        return FoundCamera(host, port, name ?? 'Canon camera', [
          ExternalKind.canon,
        ]);
      }
      final gopro = await _get(host, port, '/gopro/camera/state');
      if (gopro != null && gopro.contains('"status"')) {
        return FoundCamera(host, port, 'GoPro', [ExternalKind.gopro]);
      }
      if (host == '192.168.122.1') {
        return FoundCamera(host, port, 'Sony camera', [ExternalKind.sonyApi]);
      }
      return null;
    }
    // Port 80
    final osc = _json(await _get(host, port, '/osc/info'));
    if (osc != null && osc['model'] != null) {
      return FoundCamera(
        host,
        port,
        '${osc['manufacturer'] ?? ''} ${osc['model']}'.trim(),
        [ExternalKind.osc],
      );
    }
    final bm = _json(await _get(host, port, '/control/api/v1/system/product'));
    if (bm != null && bm['productName'] != null) {
      return FoundCamera(host, port, bm['productName'] as String, [
        ExternalKind.blackmagic,
      ]);
    }
    final lumix = await _get(
      host,
      port,
      '/cam.cgi?mode=getinfo&type=capability',
    );
    if (lumix != null && lumix.contains('<camrply>')) {
      final model = RegExp(
        r'<productinfo>.*?<modelName>(.*?)</modelName>',
        dotAll: true,
      ).firstMatch(lumix)?.group(1);
      return FoundCamera(host, port, model ?? 'Panasonic Lumix', [
        ExternalKind.lumix,
      ]);
    }
    final om = await _get(host, port, '/get_caminfo.cgi');
    if (om != null && om.contains('<model>')) {
      final model = RegExp(r'<model>(.*?)</model>').firstMatch(om)?.group(1);
      return FoundCamera(host, port, model ?? 'OM System camera', [
        ExternalKind.olympus,
      ]);
    }
    return null;
  }

  static Map<String, dynamic>? _json(String? s) {
    if (s == null) return null;
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// "Find Wi-Fi cameras": scan, tap to connect, and step-by-step pairing help
/// for each brand.
class FindCamerasScreen extends StatefulWidget {
  const FindCamerasScreen({super.key, required this.server});
  final HostServer server;

  @override
  State<FindCamerasScreen> createState() => _FindCamerasScreenState();
}

class _FindCamerasScreenState extends State<FindCamerasScreen> {
  List<FoundCamera>? _found;
  double _progress = 0;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _progress = 0;
    });
    final found = await CameraScanner.scan(
      widget.server.addresses,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _found = found;
      _scanning = false;
    });
  }

  Future<void> _use(FoundCamera f) async {
    var kind = f.kinds.first;
    if (f.kinds.length > 1) {
      final picked = await showModalBottomSheet<ExternalKind>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Which camera is this?')),
              for (final k in f.kinds)
                ListTile(
                  title: Text(k.brand),
                  subtitle: Text(k.label),
                  onTap: () => Navigator.pop(ctx, k),
                ),
            ],
          ),
        ),
      );
      if (picked == null) return;
      kind = picked;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ExternalCameraScreen(
          server: widget.server,
          initial: ExternalConfig(kind: kind, host: f.host, port: f.port),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    final brands = <String, List<ExternalKind>>{};
    for (final k in ExternalKind.values) {
      if (k == ExternalKind.sound) continue;
      (brands[k.brand] ??= []).add(k);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Find Wi-Fi cameras')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _scanning
                            ? 'Looking for cameras…'
                            : '${_found?.length ?? 0} found',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (!_scanning)
                      TextButton.icon(
                        onPressed: _scan,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Look again'),
                      ),
                  ],
                ),
                if (_scanning) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _progress,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Turn on the camera\'s Wi-Fi or remote control first, on the same network as this phone.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final f in _found ?? const <FoundCamera>[]) ...[
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: const EdgeInsets.all(12),
                    onTap: () => _use(f),
                    child: Row(
                      children: [
                        IconBadge(
                          Icons.photo_camera_rounded,
                          size: 40,
                          color: t.accent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                f.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'Tap to connect',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SectionTitle('Pairing help by brand'),
          for (final e in brands.entries)
            Card(
              child: ExpansionTile(
                shape: const Border(),
                title: Text(
                  e.key,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  for (final k in e.value) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        k.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      k.setupHint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => ExternalCameraScreen(
                              server: widget.server,
                              initial: ExternalConfig(
                                kind: k,
                                host: k.defaultHost,
                                port: k.defaultPort,
                              ),
                            ),
                          ),
                        ),
                        child: const Text('Set up'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
