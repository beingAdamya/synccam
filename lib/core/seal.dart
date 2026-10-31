import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// End-to-end encryption for signaling messages that cross a public relay:
/// AES-256-GCM, envelope = base64url(iv[12] || ciphertext || tag[16]).
/// Byte-compatible with `seal`/`open` in assets/web/transport.js (WebCrypto).
class Sealer {
  Sealer(this.key) : assert(key.length == 32);

  final Uint8List key;

  static Sealer random() {
    final r = Random.secure();
    return Sealer(Uint8List.fromList(List.generate(32, (_) => r.nextInt(256))));
  }

  static Sealer fromBase64Url(String k) => Sealer(b64urlDecode(k));

  String get keyBase64Url => b64urlEncode(key);

  String seal(Map<String, dynamic> message) {
    final r = Random.secure();
    final iv = Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
    final c = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ct = c.process(Uint8List.fromList(utf8.encode(jsonEncode(message))));
    return b64urlEncode(Uint8List.fromList([...iv, ...ct]));
  }

  /// Throws if the message was not sealed with this key or was altered.
  Map<String, dynamic> open(String envelope) {
    final b = b64urlDecode(envelope);
    if (b.length < 12 + 16) throw const FormatException('envelope too short');
    final c = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, Uint8List.sublistView(b, 0, 12), Uint8List(0)));
    final pt = c.process(Uint8List.sublistView(b, 12));
    return jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
  }

  static String b64urlEncode(Uint8List b) => base64Url.encode(b).replaceAll('=', '');
  static Uint8List b64urlDecode(String s) => base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));
}
