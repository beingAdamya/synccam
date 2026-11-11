import 'dart:convert';
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
  final _codeCtl = TextEditingController();
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
    _codeCtl.dispose();
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

  /// Finds the rig showing this 4-digit code among those on the network.
  void _joinCode() {
    final code = _codeCtl.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 4) return;
    for (final s in _discovery?.services ?? const <nsd.Service>[]) {
      final raw = s.txt?['code'];
      if (raw != null && utf8.decode(raw, allowMalformed: true) == code) {
        _joinService(s);
        return;
      }
    }
    showSnack(context, 'No rig with code $code on this Wi-Fi yet. Check both phones are on the same network.');
  }

  @override
  Widget build(BuildContext context) {
    final services = _discovery?.services ?? const <nsd.Service>[];
    final t = Theme.of(context).textTheme;
    final c = context.sync;
    return Scaffold(
      appBar: AppBar(title: const Text('Join as a camera')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text('Be on the same Wi-Fi (or hotspot) as the controlling phone, then scan its code.',
              style: t.bodyMedium?.copyWith(color: c.muted)),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Scan code', icon: Icons.qr_code_scanner_rounded, onPressed: _scan),
          const SizedBox(height: 16),
          GlassCard(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Can\'t scan? Type the 4-digit code', style: t.titleSmall),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtl,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    style: mono(size: 26, weight: FontWeight.w600),
                    decoration: const InputDecoration(counterText: '', hintText: '0000'),
                    onChanged: (v) {
                      if (v.length == 4) _joinCode();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(onPressed: _joinCode, child: const Text('Join')),
              ]),
            ]),
          ),
          const SectionTitle('Rigs nearby'),
          if (_discoveryError != null)
            Text('Can\'t look for rigs automatically on this network. Use Scan code instead.',
                style: t.bodyMedium?.copyWith(color: Status.warning)),
          if (services.isEmpty && _discoveryError == null)
            GlassCard(
              child: Row(children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 16),
                Expanded(child: Text('Looking for rigs…', style: t.bodyMedium?.copyWith(color: c.muted))),
              ]),
            ),
          for (final svc in services) ...[
            ActionCard(
              icon: Icons.grid_view_rounded,
              title: svc.name ?? 'SyncCam rig',
              subtitle: 'Tap to join',
              highlight: true,
              onTap: () => _joinService(svc),
            ),
            const SizedBox(height: 10),
          ],
          const SectionTitle('This camera'),
          TextField(
            controller: _nameCtl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name, e.g. Left wide', prefixIcon: Icon(Icons.badge_outlined)),
          ),
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
