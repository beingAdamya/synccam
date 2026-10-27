import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/core/tls.dart';

void main() {
  final ca = LocalCa.create();

  test('TLS handshake to an IP succeeds when only the local CA is trusted', () async {
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ca.serverContext(['127.0.0.1']));
    server.listen((r) => r.response
      ..write('ok')
      ..close());
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(ca.caCertPem)));
    final res = await (await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'))).close();
    expect(await res.transform(utf8.decoder).join(), 'ok');
    client.close();
    await server.close(force: true);
  });

  test('a different CA is rejected (so trust really comes from ours)', () async {
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ca.serverContext(['127.0.0.1']));
    server.listen((r) => r.response.close(), onError: (_) {});
    final other = LocalCa.create();
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(other.caCertPem)));
    await expectLater(
      () async => (await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'))).close(),
      throwsA(isA<HandshakeException>()),
    );
    client.close();
    await server.close(force: true);
  });

  test('openssl accepts the chain and sees IP SANs and serverAuth', () async {
    final which = await Process.run(Platform.isWindows ? 'where' : 'which', ['openssl']);
    if (which.exitCode != 0) {
      markTestSkipped('openssl not installed');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('synccam_tls');
    final leaf = ca.issueServer(['192.168.1.20', '172.20.10.1']);
    await File('${dir.path}/ca.pem').writeAsString(ca.caCertPem);
    await File('${dir.path}/leaf.pem').writeAsString(leaf.certPem);
    final verify = await Process.run('openssl',
        ['verify', '-CAfile', '${dir.path}/ca.pem', '-purpose', 'sslserver', '${dir.path}/leaf.pem']);
    expect(verify.stdout.toString(), contains(': OK'), reason: '${verify.stdout}${verify.stderr}');
    final text = await Process.run('openssl', ['x509', '-in', '${dir.path}/leaf.pem', '-noout', '-text']);
    final out = text.stdout.toString();
    expect(out, contains('IP Address:192.168.1.20'));
    expect(out, contains('IP Address:172.20.10.1'));
    expect(out, contains('TLS Web Server Authentication'));
    expect(out, contains('ecdsa-with-SHA256'));
    final caText = await Process.run('openssl', ['x509', '-in', '${dir.path}/ca.pem', '-noout', '-text']);
    expect(caText.stdout.toString(), contains('CA:TRUE'));
    await dir.delete(recursive: true);
  });
}
