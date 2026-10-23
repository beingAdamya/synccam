import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'host_server.dart';

class TakeDevice {
  TakeDevice(this.id, this.name, this.slot, this.model, this.trimMs);
  final String id;
  final String name;
  final int slot;
  final String model;
  final double trimMs;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'slot': slot, 'model': model, 'trimMs': trimMs};
  static TakeDevice fromJson(Map<String, dynamic> j) => TakeDevice(j['id'] as String, j['name'] as String,
      (j['slot'] as num).toInt(), j['model'] as String? ?? '', (j['trimMs'] as num?)?.toDouble() ?? 0);
}

/// One file captured by one device in a take, with the host-clock timestamps
/// the device reported around the native capture call.
class TakeItem {
  TakeItem(this.deviceId, this.shot, this.kind);
  final String deviceId;
  final int shot;
  String kind;
  final Map<String, int> timing = {};
  int size = 0;
  String? file;

  /// Best estimate of when this item's capture actually began, host clock.
  int? get startUs => timing['startReturnedHostUs'] ?? timing['calledHostUs'];

  Map<String, dynamic> toJson() =>
      {'device': deviceId, 'shot': shot, 'kind': kind, 'timing': timing, 'size': size, 'file': file};

  static TakeItem fromJson(Map<String, dynamic> j) {
    final it = TakeItem(j['device'] as String, (j['shot'] as num).toInt(), j['kind'] as String);
    (j['timing'] as Map?)?.forEach((k, v) => it.timing[k as String] = (v as num).toInt());
    it.size = (j['size'] as num?)?.toInt() ?? 0;
    it.file = j['file'] as String?;
    return it;
  }
}

/// A synchronized capture event across all cameras: one folder holding every
/// device's files plus `manifest.json` with precise timing for alignment.
class Take {
  Take._(this.id, this.dir, this.kind, this.createdAt, this.scheduledHostUs, this.staggerMs, this.devices);

  final String id;
  final Directory dir;
  final String kind;
  final DateTime createdAt;
  final int scheduledHostUs;
  final int staggerMs;
  final List<TakeDevice> devices;
  final List<TakeItem> items = [];
  final List<int> slates = [];
  String label = '';

  static Take create(Directory root, String kind, int scheduledUs, int staggerMs, List<TakeDevice> devices) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final id = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '-${Random().nextInt(0xffff).toRadixString(16).padLeft(4, '0')}';
    return Take._(id, Directory('${root.path}/$id'), kind, now, scheduledUs, staggerMs, devices);
  }

  TakeDevice? device(String id) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  TakeItem _item(String deviceId, int shot, String kind) {
    for (final it in items) {
      if (it.deviceId == deviceId && it.shot == shot) return it;
    }
    final it = TakeItem(deviceId, shot, kind);
    items.add(it);
    return it;
  }

  void addCapture(RemoteDevice d, Map<String, dynamic> m) {
    final it = _item(d.id, (m['shot'] as num?)?.toInt() ?? 0, m['kind'] as String? ?? kind);
    m.forEach((k, v) {
      if (k.endsWith('HostUs') && v is num) it.timing[k] = v.toInt();
    });
    it.size = (m['size'] as num?)?.toInt() ?? it.size;
  }

  void attachFile(String deviceId, int shot, String fileName) {
    final it = _item(deviceId, shot, kind == 'video' ? 'video' : 'photo');
    it.file = fileName;
  }

  int get shots => items.isEmpty ? 0 : items.map((i) => i.shot).reduce(max) + 1;
  int get receivedFiles => items.where((i) => i.file != null).length;

  List<TakeItem> itemsForShot(int shot) =>
      items.where((i) => i.shot == shot).toList()
        ..sort((a, b) => (device(a.deviceId)?.slot ?? 0).compareTo(device(b.deviceId)?.slot ?? 0));

  /// Spread in ms between the earliest and latest trigger for a shot,
  /// ignoring intentional bullet-time stagger. This is the "how in sync were
  /// we" number.
  double? spreadMs(int shot) {
    final its = itemsForShot(shot);
    final starts = <int>[];
    for (final it in its) {
      final s = it.startUs;
      final d = device(it.deviceId);
      if (s == null || d == null) continue;
      starts.add(s - d.slot * staggerMs * 1000);
    }
    if (starts.length < 2) return null;
    return (starts.reduce(max) - starts.reduce(min)) / 1000.0;
  }

  /// For video: how much to trim from the head of each clip so all clips
  /// begin at the same instant (the latest start).
  Map<String, double> headTrimsMs() {
    final vids = items.where((i) => i.kind == 'video' && i.startUs != null).toList();
    if (vids.isEmpty) return {};
    final latest = vids.map((i) => i.startUs!).reduce(max);
    return {for (final v in vids) v.deviceId: (latest - v.startUs!) / 1000.0};
  }

  File? fileFor(TakeItem it) => it.file == null ? null : File('${dir.path}/${it.file}');

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        'scheduledHostUs': scheduledHostUs,
        'staggerMs': staggerMs,
        'devices': devices.map((d) => d.toJson()).toList(),
        'items': items.map((i) => i.toJson()).toList(),
        'slatesHostUs': slates,
        'headTrimsMs': headTrimsMs(),
        'spreadMs': {for (var s = 0; s < shots; s++) '$s': spreadMs(s)},
      };

  Future<void> save() async {
    await dir.create(recursive: true);
    await File('${dir.path}/manifest.json').writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  static Future<List<Take>> loadAll(Directory root) async {
    final out = <Take>[];
    if (!await root.exists()) return out;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final f = File('${e.path}/manifest.json');
      if (!await f.exists()) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final t = Take._(
          j['id'] as String,
          e,
          j['kind'] as String,
          DateTime.parse(j['createdAt'] as String),
          (j['scheduledHostUs'] as num).toInt(),
          (j['staggerMs'] as num?)?.toInt() ?? 0,
          [for (final d in (j['devices'] as List)) TakeDevice.fromJson((d as Map).cast<String, dynamic>())],
        );
        t.label = j['label'] as String? ?? '';
        for (final i in (j['items'] as List)) {
          t.items.add(TakeItem.fromJson((i as Map).cast<String, dynamic>()));
        }
        t.slates.addAll(((j['slatesHostUs'] as List?) ?? const []).map((v) => (v as num).toInt()));
        out.add(t);
      } catch (_) {}
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }
}
