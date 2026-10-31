import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/util.dart';

/// PTP/IP (CIPA DC-005 / ISO 15740 over TCP), the "connect to computer over
/// Wi-Fi" protocol most camera makers share. Two TCP connections to port
/// 15740: a command channel for transactions and an event channel.
///
/// Packet = u32 length (incl. 8-byte header) + u32 type + payload, all
/// little-endian.
class Ptp {
  // packet types
  static const initCommandRequest = 1, initCommandAck = 2, initEventRequest = 3, initEventAck = 4, initFail = 5;
  static const operationRequest = 6, operationResponse = 7, event = 8;
  static const startData = 9, data = 10, cancel = 11, endData = 12, probeRequest = 13, probeResponse = 14;

  // standard operations / responses
  static const getDeviceInfo = 0x1001, openSession = 0x1002, closeSession = 0x1003;
  static const setDevicePropValue = 0x1016, terminateOpenCapture = 0x1018, initiateOpenCapture = 0x101C;
  static const ok = 0x2001, deviceBusy = 0x2019, sessionAlreadyOpen = 0x201E;
}

class PtpResponse {
  PtpResponse(this.code, this.transactionId, this.params, this.data);
  final int code;
  final int transactionId;
  final List<int> params;
  final Uint8List data;
  bool get ok => code == Ptp.ok;
  String get codeHex => '0x${code.toRadixString(16).padLeft(4, '0')}';
}

class PtpEvent {
  PtpEvent(this.code, this.params);
  final int code;
  final List<int> params;
  @override
  String toString() => 'event 0x${code.toRadixString(16)} $params';
}

class PtpException implements Exception {
  PtpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a camera says about itself (PTP DeviceInfo dataset).
class PtpDeviceInfo {
  PtpDeviceInfo({
    required this.vendorExtensionId,
    required this.operations,
    required this.events,
    required this.properties,
    required this.manufacturer,
    required this.model,
    required this.version,
  });
  final int vendorExtensionId;
  final Set<int> operations;
  final Set<int> events;
  final Set<int> properties;
  final String manufacturer;
  final String model;
  final String version;

  static PtpDeviceInfo parse(Uint8List b) {
    final r = PtpReader(b);
    r.u16(); // standard version
    final vendor = r.u32();
    r.u16(); // vendor extension version
    r.string(); // vendor extension description
    r.u16(); // functional mode
    final ops = r.u16Array().toSet();
    final events = r.u16Array().toSet();
    final props = r.u16Array().toSet();
    r.u16Array(); // capture formats
    r.u16Array(); // image formats
    return PtpDeviceInfo(
      vendorExtensionId: vendor,
      operations: ops,
      events: events,
      properties: props,
      manufacturer: r.string(),
      model: r.string(),
      version: r.string(),
    );
  }
}

/// Little-endian reader for PTP datasets.
class PtpReader {
  PtpReader(this.b) : _d = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData _d;
  int pos = 0;

  bool get done => pos >= b.length;
  int u8() => _d.getUint8(pos++);
  int u16() {
    final v = _d.getUint16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int u32() {
    final v = _d.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    final v = _d.getUint64(pos, Endian.little);
    pos += 8;
    return v;
  }

  List<int> u16Array() => List.generate(u32(), (_) => u16());

  /// PTP string: u8 character count (incl. terminating NUL), UTF-16LE.
  String string() {
    final n = u8();
    if (n == 0) return '';
    final units = List.generate(n, (_) => u16());
    return String.fromCharCodes(units.where((u) => u != 0));
  }

  void skip(int n) => pos += n;
}

class PtpWriter {
  final BytesBuilder _b = BytesBuilder();
  void u16(int v) => _b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void u32(int v) => _b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => _b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void bytes(List<int> v) => _b.add(v);
  void utf16z(String s) {
    for (final c in s.codeUnits) {
      u16(c);
    }
    u16(0);
  }

  Uint8List take() => _b.takeBytes();
}

class _Packet {
  _Packet(this.type, this.payload);
  final int type;
  final Uint8List payload;
}

/// Splits a TCP byte stream into PTP/IP packets.
class _Channel {
  _Channel(this.socket, this.onProbe) {
    _sub = socket.listen(_onData, onError: _fail, onDone: () => _fail(const SocketException('camera closed the connection')));
  }

  final Socket socket;
  final void Function() onProbe;
  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  final List<_Packet> _queue = [];
  final List<Completer<_Packet>> _waiting = [];
  Object? _error;
  void Function(_Packet)? onUnsolicited;

  void _onData(Uint8List chunk) {
    _buf.add(chunk);
    var all = _buf.takeBytes();
    var off = 0;
    while (all.length - off >= 8) {
      final d = ByteData.sublistView(all, off);
      final len = d.getUint32(0, Endian.little);
      if (len < 8) {
        _fail(PtpException('bad packet length $len'));
        return;
      }
      if (all.length - off < len) break;
      final type = d.getUint32(4, Endian.little);
      final payload = Uint8List.fromList(Uint8List.sublistView(all, off + 8, off + len));
      off += len;
      _deliver(_Packet(type, payload));
    }
    if (off < all.length) _buf.add(Uint8List.sublistView(all, off));
  }

  void _deliver(_Packet p) {
    if (p.type == Ptp.probeRequest) {
      onProbe();
      return;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(p);
    } else if (onUnsolicited != null) {
      onUnsolicited!(p);
    } else {
      _queue.add(p);
    }
  }

  void _fail(Object e) {
    _error ??= e;
    for (final w in _waiting) {
      w.completeError(e);
    }
    _waiting.clear();
  }

  Future<_Packet> next(Duration timeout) {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    if (_error != null) return Future.error(_error!);
    final c = Completer<_Packet>();
    _waiting.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiting.remove(c);
      throw TimeoutException('camera did not answer');
    });
  }

  void send(int type, Uint8List payload) {
    final w = PtpWriter()
      ..u32(payload.length + 8)
      ..u32(type)
      ..bytes(payload);
    socket.add(w.take());
  }

  Future<void> close() async {
    await _sub.cancel();
    socket.destroy();
  }
}

/// One PTP/IP connection (command + event channels) with serialized
/// transactions.
class PtpIpSession {
  PtpIpSession({required this.host, this.port = 15740, required this.guid, this.name = 'SyncCam', this.trace});

  final String host;
  final int port;
  final Uint8List guid;
  final String name;
  final void Function(String)? trace;

  _Channel? _cmd, _evt;
  int connectionNumber = 0;
  String cameraName = '';
  int _tid = 0;
  final AsyncLock _lock = AsyncLock();
  final StreamController<PtpEvent> _events = StreamController.broadcast();
  Stream<PtpEvent> get events => _events.stream;

  /// Transaction id of the last completed operation.
  int lastTransactionId = 0;

  Future<void> connect({Duration timeout = const Duration(seconds: 5)}) async {
    final cmdSock = await Socket.connect(host, port, timeout: timeout);
    cmdSock.setOption(SocketOption.tcpNoDelay, true);
    final cmd = _cmd = _Channel(cmdSock, () => _cmd?.send(Ptp.probeResponse, Uint8List(0)));
    final req = PtpWriter()
      ..bytes(guid)
      ..utf16z(name)
      ..u32(0x00010000); // protocol version 1.0
    cmd.send(Ptp.initCommandRequest, req.take());
    final ack = await cmd.next(const Duration(seconds: 30)); // cameras may wait for the user to accept pairing
    if (ack.type == Ptp.initFail) {
      final reason = ack.payload.length >= 4 ? ByteData.sublistView(ack.payload).getUint32(0, Endian.little) : 0;
      throw PtpException('camera refused the connection (reason $reason). Accept SyncCam on the camera, '
          'or pair again from its network menu.');
    }
    if (ack.type != Ptp.initCommandAck) throw PtpException('unexpected reply type ${ack.type} to init');
    final r = PtpReader(ack.payload);
    connectionNumber = r.u32();
    r.skip(16);
    final units = <int>[];
    while (r.pos + 2 <= ack.payload.length) {
      final u = r.u16();
      if (u == 0) break;
      units.add(u);
    }
    cameraName = String.fromCharCodes(units);
    trace?.call('PTP/IP command channel open: "$cameraName", connection $connectionNumber');

    final evtSock = await Socket.connect(host, port, timeout: timeout);
    evtSock.setOption(SocketOption.tcpNoDelay, true);
    final evt = _evt = _Channel(evtSock, () => _evt?.send(Ptp.probeResponse, Uint8List(0)));
    evt.send(Ptp.initEventRequest, (PtpWriter()..u32(connectionNumber)).take());
    final eack = await evt.next(timeout);
    if (eack.type != Ptp.initEventAck) throw PtpException('event channel refused (type ${eack.type})');
    evt.onUnsolicited = (p) {
      if (p.type != Ptp.event || p.payload.length < 6) return;
      final rr = PtpReader(p.payload);
      final code = rr.u16();
      rr.u32(); // transaction id
      final params = <int>[];
      while (rr.pos + 4 <= p.payload.length) {
        params.add(rr.u32());
      }
      final e = PtpEvent(code, params);
      trace?.call('← $e');
      _events.add(e);
    };
    trace?.call('PTP/IP event channel open');
  }

  /// Runs one PTP operation. [dataOut] sends a data phase to the camera;
  /// any data the camera returns is in [PtpResponse.data].
  Future<PtpResponse> transaction(int op, {List<int> params = const [], Uint8List? dataOut, Duration timeout = const Duration(seconds: 5)}) {
    return _lock.run(() async {
      final cmd = _cmd;
      if (cmd == null) throw PtpException('not connected');
      final tid = op == Ptp.openSession ? 0 : ++_tid;
      final w = PtpWriter()
        ..u32(dataOut == null ? 1 : 2) // data phase: 1 = none or camera→us, 2 = us→camera
        ..u16(op)
        ..u32(tid);
      for (final p in params) {
        w.u32(p);
      }
      cmd.send(Ptp.operationRequest, w.take());
      if (dataOut != null) {
        cmd.send(Ptp.startData, (PtpWriter()
              ..u32(tid)
              ..u64(dataOut.length))
            .take());
        cmd.send(Ptp.endData, (PtpWriter()
              ..u32(tid)
              ..bytes(dataOut))
            .take());
      }
      final data = BytesBuilder(copy: false);
      while (true) {
        final p = await cmd.next(timeout);
        switch (p.type) {
          case Ptp.startData:
            break;
          case Ptp.data || Ptp.endData:
            data.add(Uint8List.sublistView(p.payload, 4));
          case Ptp.operationResponse:
            final r = PtpReader(p.payload);
            final code = r.u16();
            final rtid = r.u32();
            final rp = <int>[];
            while (r.pos + 4 <= p.payload.length) {
              rp.add(r.u32());
            }
            lastTransactionId = rtid;
            return PtpResponse(code, rtid, rp, data.takeBytes());
          case Ptp.event:
            // Some cameras put events on the command channel too.
            break;
          default:
            throw PtpException('unexpected packet type ${p.type}');
        }
      }
    });
  }

  Future<void> close() async {
    await _cmd?.close();
    await _evt?.close();
    _cmd = _evt = null;
  }
}
