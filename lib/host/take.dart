import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  /// "Take 14": counts up on this phone and never changes.
  int number = 0;

  /// Things worth knowing about this take, e.g. "Camera 4 rejoined at 0:31".
  final List<String> notes = [];

  /// Length of the longest clip, when known.
  Duration? get length {
    int? best;
    for (final it in items) {
      final a = it.timing['startReturnedHostUs'] ?? it.timing['startCalledHostUs'];
      final b = it.timing['stopReturnedHostUs'] ?? it.timing['stopCalledHostUs'];
      if (a != null && b != null && b > a) best = max(best ?? 0, b - a);
    }
    return best == null ? null : Duration(microseconds: best);
  }

  /// Angles that have a file on this phone.
  int get anglesHere => {for (final it in items) if (it.file != null) it.deviceId}.length;

  /// The Wi-Fi camera that led this take, if any: model, and when its
  /// recording start was seen (host clock).
  Map<String, dynamic>? external;

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

  /// A small picture of what [deviceId] saw: its photo, or for video the
  /// last live frame before recording started.
  File? thumbFor(String deviceId) {
    for (final it in items) {
      if (it.deviceId == deviceId && it.kind == 'photo' && it.file != null) {
        final f = fileFor(it)!;
        if (f.existsSync()) return f;
      }
    }
    final t = File('${dir.path}/thumb_$deviceId.jpg');
    return t.existsSync() ? t : null;
  }

  /// Devices in rig order.
  List<TakeDevice> get angles => [...devices]..sort((a, b) => a.slot.compareTo(b.slot));

  /// Removes one file from this take (from this phone only).
  Future<void> removeItem(TakeItem it) async {
    final f = fileFor(it);
    items.remove(it);
    if (f != null && await f.exists()) await f.delete();
    await save();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'label': label,
        'number': number,
        'createdAt': createdAt.toIso8601String(),
        'scheduledHostUs': scheduledHostUs,
        'staggerMs': staggerMs,
        'devices': devices.map((d) => d.toJson()).toList(),
        'items': items.map((i) => i.toJson()).toList(),
        'slatesHostUs': slates,
        if (notes.isNotEmpty) 'notes': notes,
        if (external != null) 'externalCamera': external,
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
        t.number = (j['number'] as num?)?.toInt() ?? 0;
        t.notes.addAll(((j['notes'] as List?) ?? const []).cast<String>());
        t.external = (j['externalCamera'] as Map?)?.cast<String, dynamic>();
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

/// All takes stored on this phone. Shared by a live host session and the
/// home-screen gallery, which opens it without starting a session.
class TakeLibrary extends ChangeNotifier {
  TakeLibrary._(this.dir);

  final Directory dir;
  final List<Take> takes = [];

  static Future<TakeLibrary> open() async {
    final lib = TakeLibrary._(Directory('${(await getApplicationDocumentsDirectory()).path}/takes'));
    await lib.dir.create(recursive: true);
    lib.takes.addAll(await Take.loadAll(lib.dir));
    // Takes from before 0.6.0 get numbers in the order they were shot.
    var n = lib.takes.fold(0, (a, t) => max(a, t.number));
    for (final t in lib.takes.reversed) {
      if (t.number == 0) t.number = ++n;
    }
    return lib;
  }

  /// A library in [dir], without loading (tests).
  @visibleForTesting
  factory TakeLibrary.at(Directory dir) => TakeLibrary._(dir);

  int get nextNumber => takes.fold(0, (a, t) => max(a, t.number)) + 1;

  void add(Take t) {
    if (t.number == 0) t.number = nextNumber;
    takes.insert(0, t);
    notifyListeners();
  }

  /// Hides takes from the gallery; [purge] deletes them, [restore] undoes.
  void remove(Iterable<Take> list) {
    for (final t in list.toList()) {
      takes.remove(t);
    }
    notifyListeners();
  }

  void restore(Iterable<Take> list) {
    for (final t in list) {
      if (!takes.contains(t)) takes.add(t);
    }
    takes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  Future<void> purge(Iterable<Take> list) async {
    for (final t in list) {
      if (takes.contains(t)) continue;
      if (await t.dir.exists()) await t.dir.delete(recursive: true);
    }
  }

  Take? byId(String? id) {
    for (final t in takes) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> delete(Take t) async {
    takes.remove(t);
    if (await t.dir.exists()) await t.dir.delete(recursive: true);
    notifyListeners();
  }

  void changed() => notifyListeners();
}
