import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'host_server.dart';

/// A rig used before, so a regular setup starts again in one tap. Cameras
/// keep their numbers, names and order because the controller remembers
/// each phone.
class RecentRig {
  RecentRig(this.name, this.cameras, this.lastUsed, this.hostIsCamera);
  final String name;
  final List<String> cameras;
  final DateTime lastUsed;
  final bool hostIsCamera;

  Map<String, dynamic> toJson() => {
    'name': name,
    'cameras': cameras,
    'lastUsed': lastUsed.toIso8601String(),
    'hostIsCamera': hostIsCamera,
  };

  static RecentRig? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return RecentRig(
        j['name'] as String,
        ((j['cameras'] as List?) ?? const []).cast<String>(),
        DateTime.parse(j['lastUsed'] as String),
        j['hostIsCamera'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

class RecentRigs {
  static const _key = 'recentRigs.v1';

  static Future<List<RecentRig>> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final list = jsonDecode(p.getString(_key) ?? '[]') as List;
      return list.map(RecentRig.fromJson).nonNulls.toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> remember(
    HostServer server, {
    bool hostIsCamera = false,
  }) async {
    if (server.devices.isEmpty) return;
    final list = await load();
    list.removeWhere((r) => r.name == server.sessionName);
    list.insert(
      0,
      RecentRig(
        server.sessionName,
        [for (final d in server.devices) d.name],
        DateTime.now(),
        hostIsCamera,
      ),
    );
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode([for (final r in list.take(5)) r.toJson()]),
    );
  }

  static Future<void> forget(String name) async {
    final list = await load();
    list.removeWhere((r) => r.name == name);
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode([for (final r in list) r.toJson()]));
  }
}
