import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:synccam/core/update_service.dart';
import 'package:synccam/core/updates.dart';
import 'package:synccam/ui/update_dialog.dart';

String _sha(Uint8List b) => SHA256Digest().process(b).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late HttpServer server;
  final apk = Uint8List.fromList(List.generate(300000, (i) => (i * 31) % 251));

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final body = req.uri.path == '/cut.apk' ? apk.sublist(0, 1000) : apk;
      req.response
        ..contentLength = body.length
        ..add(body)
        ..close();
    });
  });
  tearDownAll(() => server.close(force: true));

  ReleaseInfo release(String path, {String? sha, int? size}) => ReleaseInfo(
        tag: 'v9.9.9',
        version: SemVer(9, 9, 9),
        name: 'n',
        notes: '',
        pageUrl: 'x',
        apkUrl: 'http://127.0.0.1:${server.port}$path',
        apkSize: size ?? apk.length,
        apkSha256: sha ?? _sha(apk),
      );

  test('downloads, reports progress, and verifies size + SHA-256', () async {
    final dir = await Directory.systemTemp.createTemp('upd');
    final progress = <double>[];
    final f = await UpdateInstaller.download(release('/ok.apk'), onProgress: progress.add, into: dir);
    expect(await f.readAsBytes(), apk);
    expect(progress.last, 1.0);
    expect(progress.length, greaterThan(1));
    await dir.delete(recursive: true);
  });

  test('a file that does not match the published SHA-256 is rejected and deleted', () async {
    final dir = await Directory.systemTemp.createTemp('upd');
    await expectLater(
      UpdateInstaller.download(release('/ok.apk', sha: 'ab' * 32), onProgress: (_) {}, into: dir),
      throwsA(isA<StateError>()),
    );
    expect(dir.listSync(), isEmpty);
    await dir.delete(recursive: true);
  });

  test('an incomplete download is rejected', () async {
    final dir = await Directory.systemTemp.createTemp('upd');
    await expectLater(
      UpdateInstaller.download(release('/cut.apk'), onProgress: (_) {}, into: dir),
      throwsA(isA<StateError>()),
    );
    await dir.delete(recursive: true);
  });

  test('release notes: what\'s new is the part above ---, as plain bullets', () {
    expect(whatsNew('## New\n- **Big** feature\n- `code` thing\n---\nInstall: do X'), ['New', 'Big feature', 'code thing']);
  });

  test('GitHub asset size and digest are read from the release feed', () {
    final r = UpdateChecker.pickNewest([
      {
        'tag_name': 'v1.0.0',
        'assets': [
          {'name': 'SyncCam-v1.0.0-android.apk', 'browser_download_url': 'u', 'size': 123, 'digest': 'sha256:ABCDEF'},
        ],
      }
    ], '0.1.0')!;
    expect(r.apkSize, 123);
    expect(r.apkSha256, 'abcdef');
  });
}
