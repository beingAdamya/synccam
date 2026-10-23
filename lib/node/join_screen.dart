import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/protocol.dart';
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not a SyncCam code')));
      }
      return;
    }
    _join(uri.host, uri.hasPort ? uri.port : Net.httpPort);
  }

  @override
  Widget build(BuildContext context) {
    final services = _discovery?.services ?? const <nsd.Service>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Join as camera')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(labelText: 'This camera\'s name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          Row(children: [
            Text('Hosts nearby', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 8),
          if (_discoveryError != null)
            Text('Auto-discovery unavailable: $_discoveryError', style: const TextStyle(color: Colors.orange)),
          if (services.isEmpty && _discoveryError == null)
            const Text('Searching the local network… Make sure both phones are on the same Wi-Fi or hotspot.',
                style: TextStyle(color: Colors.grey)),
          for (final s in services)
            Card(
              child: ListTile(
                leading: const Icon(Icons.videocam),
                title: Text(s.name ?? 'SyncCam host'),
                subtitle: Text('${s.addresses?.map((a) => a.address).join(', ') ?? s.host ?? ''}:${s.port}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _joinService(s),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan host QR code'),
          ),
          const SizedBox(height: 24),
          Text('Or enter the host address', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ipCtl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: '192.168.1.20', border: OutlineInputBorder()),
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
      appBar: AppBar(title: const Text('Scan host code')),
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
