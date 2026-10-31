import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../core/seal.dart';
import 'host_server.dart';

/// Lets iPhones join from the SyncCam page on GitHub Pages: no app, no
/// certificate. The page and this host find each other through a public
/// MQTT relay (one encrypted offer and answer), then talk directly over
/// WebRTC data channels on the local network:
///
///   ctl   reliable, ordered    JSON control messages (same protocol as /ws)
///   clk   unordered, no retry  clock-sync ping/pong
///   prev  unordered, no retry  live-view JPEGs
///   file:{json}                one channel per uploaded capture
///
/// The relay only ever sees AES-256-GCM ciphertext; the key is in the QR
/// code's URL fragment, which browsers never send to a server. Must stay in
/// step with assets/web/transport.js.
class RtcGateway extends ChangeNotifier {
  RtcGateway({required this.server});

  final HostServer server;

  static const pageUrl = 'https://beingadamya.github.io/synccam/cam/';
  static const brokers = [('broker.hivemq.com', 8883), ('broker.emqx.io', 8883)];
  static const _ice = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  late final String room = List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final Sealer _sealer = Sealer.random();
  int _broker = 0;
  bool ready = false;
  String status = 'Connecting to the join relay…';
  MqttServerClient? _mqtt;
  StreamSubscription<dynamic>? _updates;
  final Map<String, _Peer> _peers = {};
  bool _disposed = false;

  String get _topic => 'synccam/v1/$room';

  /// What the iPhone opens (shown as a QR code on the host).
  String get joinUrl => '$pageUrl#r=$room&k=${_sealer.keyBase64Url}'
      '&s=${Uri.encodeComponent(server.sessionName)}&b=$_broker';

  Future<void> start() async {
    for (var i = 0; i < brokers.length && !_disposed; i++) {
      final (host, port) = brokers[i];
      final c = MqttServerClient.withPort(host, 'synccam-host-$room-$i', port)
        ..secure = true
        ..keepAlivePeriod = 30
        ..autoReconnect = true
        ..logging(on: false)
        ..connectionMessage = MqttConnectMessage().withClientIdentifier('synccam-host-$room-$i').startClean();
      try {
        await c.connect().timeout(const Duration(seconds: 8));
        if (c.connectionStatus?.state != MqttConnectionState.connected) throw StateError('not connected');
        c.subscribe('$_topic/host', MqttQos.atMostOnce);
        _updates = c.updates?.listen(_onRelay);
        _mqtt = c;
        _broker = i;
        ready = true;
        status = 'Ready: iPhones can join with no app and no certificate';
        _notify();
        return;
      } catch (e) {
        c.disconnect();
        debugPrint('relay $host failed: $e');
      }
    }
    status = 'No internet: iPhones can still join with the offline (certificate) option';
    _notify();
  }

  void _onRelay(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final m in msgs) {
      if (m.topic != '$_topic/host') continue;
      final text = MqttPublishPayload.bytesToStringAsString((m.payload as MqttPublishMessage).payload.message);
      Map<String, dynamic> msg;
      try {
        msg = _sealer.open(text);
      } catch (_) {
        continue; // not ours, or tampered with
      }
      if (msg['type'] == 'offer' && msg['cam'] is String && msg['sdp'] is String) {
        _accept(msg['cam'] as String, msg['sdp'] as String);
      }
    }
  }

  Future<void> _accept(String camId, String sdp) async {
    _peers.remove(camId)?.close();
    final pc = await createPeerConnection(_ice);
    final peer = _Peer(this, pc, camId);
    _peers[camId] = peer;
    pc.onDataChannel = peer.onChannel;
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        peer.lost();
        if (_peers[camId] == peer) _peers.remove(camId);
      }
    };
    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) gathered.complete();
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await pc.setLocalDescription(await pc.createAnswer());
    // One complete answer instead of trickled candidates.
    await gathered.future.timeout(const Duration(milliseconds: 2500), onTimeout: () {});
    final local = await pc.getLocalDescription();
    _publish('$_topic/cam/$camId', _sealer.seal({'type': 'answer', 'sdp': local?.sdp}));
  }

  void _publish(String topic, String text) {
    final b = MqttClientPayloadBuilder()..addString(text);
    _mqtt?.publishMessage(topic, MqttQos.atMostOnce, b.payload!);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _updates?.cancel();
    _mqtt?.disconnect();
    for (final p in _peers.values) {
      p.close();
    }
    _peers.clear();
    super.dispose();
  }
}

/// One browser camera over WebRTC, presented to the host as a [DeviceLink].
class _Peer implements DeviceLink {
  _Peer(this.gw, this.pc, this.camId);

  final RtcGateway gw;
  final RTCPeerConnection pc;
  final String camId;
  RTCDataChannel? _ctl;
  LinkInput? _input;
  bool _closed = false;

  void onChannel(RTCDataChannel ch) {
    final label = ch.label ?? '';
    if (label == 'ctl') {
      _ctl = ch;
      _input = gw.server.attachLink(this, null);
      ch.onMessage = (m) {
        if (!m.isBinary) _input?.onText(m.text, (t) => ch.send(RTCDataChannelMessage(t)));
      };
      ch.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelClosed) lost();
      };
    } else if (label == 'clk') {
      ch.onMessage = (m) {
        if (!m.isBinary) _input?.onText(m.text, (t) => ch.send(RTCDataChannelMessage(t)));
      };
    } else if (label == 'prev') {
      ch.onMessage = (m) {
        if (m.isBinary) _input?.onBinary(m.binary);
      };
    } else if (label.startsWith('file:')) {
      _receiveFile(ch, label.substring(5));
    }
  }

  /// Chunks arrive on the channel; the host stores them like an HTTP upload
  /// and answers "ok" once every byte is on disk.
  void _receiveFile(RTCDataChannel ch, String metaJson) {
    final meta = jsonDecode(metaJson) as Map<String, dynamic>;
    final size = (meta['size'] as num).toInt();
    final data = StreamController<List<int>>();
    var got = 0;
    final stored = gw.server.storeUpload(
      deviceId: meta['device'] as String? ?? camId,
      takeId: meta['take'] as String?,
      shot: (meta['shot'] as num?)?.toInt() ?? 0,
      ext: meta['ext'] as String? ?? 'bin',
      data: data.stream,
    );
    if (size == 0) data.close();
    ch.onMessage = (m) {
      if (!m.isBinary || data.isClosed) return;
      final Uint8List b = m.binary;
      data.add(b);
      got += b.length;
      if (got >= size) data.close();
    };
    stored.then((ok) => ch.send(RTCDataChannelMessage(ok ? 'ok' : 'fail')));
  }

  void lost() {
    if (_closed) return;
    _closed = true;
    _input?.onClosed();
  }

  @override
  void sendText(String text) => _ctl?.send(RTCDataChannelMessage(text));

  @override
  void close() {
    lost();
    pc.close();
  }
}
