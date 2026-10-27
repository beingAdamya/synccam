import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// A tiny local certificate authority, so an iPhone can open the host's
/// camera page over HTTPS without installing the app.
///
/// Safari only allows the camera (getUserMedia) and secure WebSockets on a
/// trusted HTTPS origin. Each host phone makes its own CA once; the user
/// installs that CA on each iPhone a single time (Settings profile), and the
/// host then issues itself a server certificate for its current IP addresses.
///
/// Certificates follow Apple's TLS requirements: ECDSA P-256 + SHA-256,
/// subjectAltName with real iPAddress entries, serverAuth EKU, and a
/// server-certificate lifetime under 825 days.
class LocalCa {
  LocalCa._(this._caKey, this.caCertDer);

  final ECPrivateKey _caKey;
  final Uint8List caCertDer;

  static final _curve = ECDomainParameters('prime256v1');

  String get caCertPem => _pem('CERTIFICATE', caCertDer);

  /// SHA-256 fingerprint of the CA, shown so users can check what they install.
  String get fingerprint => _hex(SHA256Digest().process(caCertDer), sep: ':');

  /// Loads the CA from [dir], or creates one on first use.
  static Future<LocalCa> loadOrCreate(Directory dir, {String name = 'SyncCam'}) async {
    await dir.create(recursive: true);
    final keyFile = File('${dir.path}/ca.key');
    final certFile = File('${dir.path}/ca.der');
    if (await keyFile.exists() && await certFile.exists()) {
      final d = BigInt.parse((await keyFile.readAsString()).trim(), radix: 16);
      return LocalCa._(ECPrivateKey(d, _curve), await certFile.readAsBytes());
    }
    final ca = create(name: name);
    await keyFile.writeAsString(ca._caKey.d!.toRadixString(16));
    await certFile.writeAsBytes(ca.caCertDer);
    return ca;
  }

  static LocalCa create({String name = 'SyncCam'}) {
    final pair = _newKeyPair();
    final subject = _name('$name Local CA ${_hex(_randomBytes(3))}');
    final now = DateTime.now().toUtc();
    final der = _sign(
      issuer: subject,
      subject: subject,
      publicKey: pair.publicKey as ECPublicKey,
      signer: pair.privateKey as ECPrivateKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      extensions: [
        _ext(_oidBasicConstraints, _seq([_bool(true), _int(BigInt.zero)]), critical: true),
        _ext(_oidKeyUsage, _bitString(Uint8List.fromList([0x86]), unused: 1), critical: true), // digSig, keyCertSign, cRLSign
        _ext(_oidSubjectKeyId, _octet(_keyId(pair.publicKey as ECPublicKey))),
      ],
    );
    return LocalCa._(pair.privateKey as ECPrivateKey, der);
  }

  /// A server certificate + key for [ips] (and optional DNS [names]),
  /// signed by this CA. Returns PEM strings ready for [SecurityContext].
  ({String certPem, String keyPem}) issueServer(List<String> ips, {List<String> names = const []}) {
    final pair = _newKeyPair();
    final caCert = _parseCaSubjectAndKey();
    final now = DateTime.now().toUtc();
    final der = _sign(
      issuer: caCert.subject,
      subject: _name('SyncCam host'),
      publicKey: pair.publicKey as ECPublicKey,
      signer: _caKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 800)), // Apple: at most 825 days
      extensions: [
        _ext(_oidBasicConstraints, _seq([]), critical: true),
        _ext(_oidKeyUsage, _bitString(Uint8List.fromList([0x80]), unused: 7), critical: true), // digitalSignature
        _ext(_oidExtKeyUsage, _seq([_oid(_oidServerAuth)])),
        _ext(
          _oidSubjectAltName,
          _seq([
            for (final ip in ips) _tlv(0x87, Uint8List.fromList(InternetAddress(ip).rawAddress)),
            for (final n in names) _tlv(0x82, Uint8List.fromList(ascii.encode(n))),
          ]),
        ),
        _ext(_oidSubjectKeyId, _octet(_keyId(pair.publicKey as ECPublicKey))),
        _ext(_oidAuthorityKeyId, _seq([_tlv(0x80, caCert.keyId)])),
      ],
    );
    return (certPem: _pem('CERTIFICATE', der), keyPem: _ecPrivateKeyPem(pair.privateKey as ECPrivateKey));
  }

  /// A [SecurityContext] for an HTTPS server on [ips].
  SecurityContext serverContext(List<String> ips) {
    final c = issueServer(ips);
    return SecurityContext()
      ..useCertificateChainBytes(utf8.encode(c.certPem + caCertPem))
      ..usePrivateKeyBytes(utf8.encode(c.keyPem));
  }

  // The CA's subject and key id, needed as issuer fields of issued certs.
  ({Uint8List subject, Uint8List keyId}) _parseCaSubjectAndKey() {
    final pub = _curve.G * _caKey.d;
    return (subject: _caSubject(), keyId: _keyId(ECPublicKey(pub, _curve)));
  }

  Uint8List _caSubject() {
    // Certificate ::= SEQ { tbs SEQ { [0] ver, serial, sigAlg, issuer, ... } }
    final cert = _readTlv(caCertDer, 0);
    final tbs = _readTlv(caCertDer, cert.valueStart);
    var p = tbs.valueStart;
    for (var i = 0; i < 3; i++) {
      p = _readTlv(caCertDer, p).end; // skip version, serial, sigAlg
    }
    final issuer = _readTlv(caCertDer, p);
    return Uint8List.sublistView(caCertDer, p, issuer.end);
  }
}

// --------------------------------------------------------------- crypto

AsymmetricKeyPair<PublicKey, PrivateKey> _newKeyPair() {
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECDomainParameters('prime256v1')), _secureRandom()));
  return gen.generateKeyPair();
}

SecureRandom _secureRandom() {
  final r = FortunaRandom();
  r.seed(KeyParameter(_randomBytes(32)));
  return r;
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _pubPoint(ECPublicKey k) => k.Q!.getEncoded(false);

Uint8List _keyId(ECPublicKey k) => SHA1Digest().process(_pubPoint(k));

Uint8List _sign({
  required Uint8List issuer,
  required Uint8List subject,
  required ECPublicKey publicKey,
  required ECPrivateKey signer,
  required DateTime notBefore,
  required DateTime notAfter,
  required List<Uint8List> extensions,
}) {
  final serial = _randomBytes(16)..[0] &= 0x7f; // positive
  final algId = _seq([_oid(_oidEcdsaSha256)]);
  final spki = _seq([
    _seq([_oid(_oidEcPublicKey), _oid(_oidPrime256v1)]),
    _bitString(_pubPoint(publicKey)),
  ]);
  final tbs = _seq([
    _tlv(0xA0, _int(BigInt.two)), // v3
    _tlv(0x02, serial),
    algId,
    issuer,
    _seq([_time(notBefore), _time(notAfter)]),
    subject,
    spki,
    _tlv(0xA3, _seq(extensions)),
  ]);
  final s = Signer('SHA-256/DET-ECDSA')..init(true, PrivateKeyParameter<ECPrivateKey>(signer));
  final sig = s.generateSignature(tbs) as ECSignature;
  return _seq([tbs, algId, _bitString(_seq([_int(sig.r), _int(sig.s)]))]);
}

String _ecPrivateKeyPem(ECPrivateKey k) {
  // SEC1 ECPrivateKey ::= SEQ { 1, OCTET d, [0] curve, [1] BIT STRING pub }
  final d = _unsigned(k.d!, 32);
  final pub = ECDomainParameters('prime256v1').G * k.d;
  final der = _seq([
    _int(BigInt.one),
    _octet(d),
    _tlv(0xA0, _oid(_oidPrime256v1)),
    _tlv(0xA1, _bitString(pub!.getEncoded(false))),
  ]);
  return _pem('EC PRIVATE KEY', der);
}

// ------------------------------------------------------------ DER helpers

const _oidEcPublicKey = '1.2.840.10045.2.1';
const _oidPrime256v1 = '1.2.840.10045.3.1.7';
const _oidEcdsaSha256 = '1.2.840.10045.4.3.2';
const _oidCommonName = '2.5.4.3';
const _oidOrg = '2.5.4.10';
const _oidBasicConstraints = '2.5.29.19';
const _oidKeyUsage = '2.5.29.15';
const _oidExtKeyUsage = '2.5.29.37';
const _oidSubjectAltName = '2.5.29.17';
const _oidSubjectKeyId = '2.5.29.14';
const _oidAuthorityKeyId = '2.5.29.35';
const _oidServerAuth = '1.3.6.1.5.5.7.3.1';

Uint8List _tlv(int tag, List<int> value) {
  final len = value.length;
  final List<int> l;
  if (len < 0x80) {
    l = [len];
  } else {
    final bytes = <int>[];
    for (var v = len; v > 0; v >>= 8) {
      bytes.insert(0, v & 0xff);
    }
    l = [0x80 | bytes.length, ...bytes];
  }
  return Uint8List.fromList([tag, ...l, ...value]);
}

Uint8List _seq(List<Uint8List> items) => _tlv(0x30, [for (final i in items) ...i]);
Uint8List _set(List<Uint8List> items) => _tlv(0x31, [for (final i in items) ...i]);
Uint8List _bool(bool v) => _tlv(0x01, [v ? 0xff : 0x00]);
Uint8List _octet(List<int> v) => _tlv(0x04, v);
Uint8List _bitString(List<int> v, {int unused = 0}) => _tlv(0x03, [unused, ...v]);

Uint8List _int(BigInt v) {
  var bytes = _unsigned(v, 0);
  if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
  if (bytes[0] & 0x80 != 0) bytes = Uint8List.fromList([0, ...bytes]);
  return _tlv(0x02, bytes);
}

Uint8List _unsigned(BigInt v, int minLen) {
  final out = <int>[];
  for (var x = v; x > BigInt.zero; x >>= 8) {
    out.insert(0, (x & BigInt.from(0xff)).toInt());
  }
  while (out.length < minLen) {
    out.insert(0, 0);
  }
  return Uint8List.fromList(out);
}

Uint8List _oid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final out = <int>[parts[0] * 40 + parts[1]];
  for (final p in parts.skip(2)) {
    final chunk = <int>[p & 0x7f];
    for (var v = p >> 7; v > 0; v >>= 7) {
      chunk.insert(0, 0x80 | (v & 0x7f));
    }
    out.addAll(chunk);
  }
  return _tlv(0x06, out);
}

Uint8List _name(String cn) => _seq([
      _set([_seq([_oid(_oidCommonName), _tlv(0x0c, utf8.encode(cn))])]),
      _set([_seq([_oid(_oidOrg), _tlv(0x0c, utf8.encode('SyncCam'))])]),
    ]);

Uint8List _time(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final u = t.toUtc();
  if (u.year < 2050) {
    return _tlv(0x17,
        ascii.encode('${two(u.year % 100)}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z'));
  }
  return _tlv(0x18,
      ascii.encode('${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z'));
}

Uint8List _ext(String oid, Uint8List value, {bool critical = false}) =>
    _seq([_oid(oid), if (critical) _bool(true), _octet(value)]);

({int valueStart, int end}) _readTlv(Uint8List b, int p) {
  var len = b[p + 1];
  var hdr = 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[p + 2 + i];
    }
    hdr += n;
  }
  return (valueStart: p + hdr, end: p + hdr + len);
}

String _pem(String label, List<int> der) {
  final b64 = base64.encode(der);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

String _hex(List<int> b, {String sep = ''}) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);
