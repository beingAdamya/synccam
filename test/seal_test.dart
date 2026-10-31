import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/core/seal.dart';

/// Runs the browser's own seal/open (assets/web/transport.js, WebCrypto) in
/// Node, so the test proves Dart and Safari agree byte for byte.
Future<String?> _node(String js) async {
  final which = await Process.run(Platform.isWindows ? 'where' : 'which', ['node']);
  if (which.exitCode != 0) return null;
  final transport = File('assets/web/transport.js').readAsStringSync();
  final script = '''
globalThis.location = { hash: '' };
globalThis.atob = (s) => Buffer.from(s, 'base64').toString('binary');
globalThis.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
$transport
(async () => { $js })().catch((e) => { console.log('ERR ' + e); process.exit(1); });
''';
  final dir = await Directory.systemTemp.createTemp('seal');
  final f = File('${dir.path}/t.js')..writeAsStringSync(script);
  final r = await Process.run('node', [f.path]);
  await dir.delete(recursive: true);
  return '${r.stdout}'.trim() + (r.exitCode == 0 ? '' : ' ${r.stderr}');
}

void main() {
  test('round trip in Dart, and tampering is rejected', () {
    final s = Sealer.random();
    final env = s.seal({'type': 'answer', 'sdp': 'v=0…'});
    expect(s.open(env)['type'], 'answer');
    final bad = env.substring(0, env.length - 2) + (env.endsWith('A') ? 'BB' : 'AA');
    expect(() => s.open(bad), throwsA(anything));
    expect(() => Sealer.random().open(env), throwsA(anything), reason: 'wrong key must fail');
  });

  test('browser (WebCrypto) and Dart open each other\'s envelopes', () async {
    final s = Sealer.random();
    final fromDart = s.seal({'type': 'answer', 'sdp': 'from dart ✓'});
    final out = await _node('''
      const key = await SyncLinks.importKey('${s.keyBase64Url}');
      const m = await SyncLinks.open(key, '$fromDart');
      const back = await SyncLinks.seal(key, { type: 'offer', cam: 'web1', sdp: 'from browser ✓ ' + m.sdp });
      console.log(back);
    ''');
    if (out == null) {
      markTestSkipped('node not installed');
      return;
    }
    expect(out, isNot(startsWith('ERR')), reason: out);
    final m = s.open(out);
    expect(m['type'], 'offer');
    expect(m['sdp'], 'from browser ✓ from dart ✓');
    expect(jsonEncode(m), contains('web1'));
  });
}
