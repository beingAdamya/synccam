import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/protocol.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_node.dart';
import 'node_screen.dart';

/// Lets a phone find a host (Bonjour/NSD auto-discovery, QR code, or typed IP)
/// and join as a camera.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  nsd.Discovery? _discovery;
  NodeIdentity? _identity;
  final _ipCtl = TextEditingController();
  final _nameCtl = TextEditingController();
  String? _discoveryError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final id = await NodeIdentity.load();
    final prefs = await SharedPreferences.getInstance();
    _ipCtl.text = prefs.getString('node.lastHost') ?? '';
    setState(() {
      _identity = id;
      _nameCtl.text = id.name;
    });
    try {
      final d = await nsd.startDiscovery(Net.serviceType, ipLookupType: nsd.IpLookupType.v4);
      d.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _discovery = d);
    } catch (e) {
      setState(() => _discoveryError = '$e');
    }
  }

  @override
  void dispose() {
    final d = _discovery;
    if (d != null) nsd.stopDiscovery(d);
    _ipCtl.dispose();
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _join(String host, int port) async {
    final id = _identity;
    if (id == null) return;
    final name = _nameCtl.text.trim();
    if (name.isNotEmpty && name != id.name) await id.rename(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('node.lastHost', host);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NodeScreen(node: CameraNode(hostAddress: host, port: port, identity: id)),
    ));
  }

  void _joinService(nsd.Service s) {
    final addr = s.addresses?.firstWhere((a) => a.type == InternetAddressType.IPv4,
        orElse: () => s.addresses!.first);
    final host = addr?.address ?? s.host;
    if (host == null) return;
    _join(host, s.port ?? Net.httpPort);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
    if (code == null) return;
    final uri = Uri.tryParse(code);
    if (uri == null || uri.scheme != 'synccam' || uri.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That isn\'t a SyncCam code. Scan the code on the controlling phone.')));
      }
      return;
    }
    _join(uri.host, uri.hasPort ? uri.port : Net.httpPort);
  }

  @override
  Widget build(BuildContext context) {
    final services = _discovery?.services ?? const <nsd.Service>[];
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Join as a camera')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text('Connect this phone to the same Wi-Fi (or hotspot) as the phone running the shoot, then pick the shoot below.',
              style: t.bodyMedium?.copyWith(color: Brand.textDim)),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(labelText: 'Name for this camera', prefixIcon: Icon(Icons.badge_outlined)),
          ),
          const SectionTitle('Shoots nearby'),
          if (_discoveryError != null)
            Text('Can\'t look for shoots automatically on this network. Use Scan code instead.',
                style: t.bodyMedium?.copyWith(color: Brand.warn)),
          if (services.isEmpty && _discoveryError == null)
            GlassCard(
              child: Row(children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Looking for shoots… Make sure both phones are on the same Wi-Fi.',
                      style: t.bodyMedium?.copyWith(color: Brand.textDim)),
                ),
              ]),
            ),
          for (final svc in services) ...[
            ActionCard(
              icon: Icons.videocam_rounded,
              color: Brand.good,
              title: svc.name ?? 'SyncCam shoot',
              subtitle: 'Tap to join',
              highlight: true,
              onTap: () => _joinService(svc),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 16),
          PrimaryButton(label: 'Scan code', icon: Icons.qr_code_scanner_rounded, onPressed: _scan),
          const SizedBox(height: 6),
          Text('The code is under "Add cameras" on the controlling phone.',
              textAlign: TextAlign.center, style: t.bodySmall),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('Type the address instead', style: t.titleSmall),
            children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ipCtl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(hintText: 'e.g. 192.168.1.20'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final v = _ipCtl.text.trim();
                    if (v.isEmpty) return;
                    final parts = v.split(':');
                    _join(parts[0], parts.length > 1 ? int.tryParse(parts[1]) ?? Net.httpPort : Net.httpPort);
                  },
                  child: const Text('Join'),
                ),
              ]),
              const SizedBox(height: 12),
            ],
          ),
        ],
      ),
    );
  }
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the code on the controlling phone')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final v = capture.barcodes.firstOrNull?.rawValue;
          if (v == null) return;
          _done = true;
          Navigator.of(context).pop(v);
        },
      ),
    );
  }
}
