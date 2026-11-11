import 'package:flutter/material.dart';

import '../core/util.dart';
import '../host/host_server.dart';
import 'theme.dart';

enum CamState { ready, recording, syncing, warning, lost, soundSync }

/// What a camera is doing right now, as a word, an icon and a colour, plus
/// the one thing to do about it when something is wrong.
class CamStatus {
  const CamStatus(this.state, this.word, {this.reason, this.fix});
  final CamState state;
  final String word;

  /// Short reason shown on warnings ("Low battery").
  final String? reason;

  /// One plain sentence on how to fix it.
  final String? fix;

  Color get color => switch (state) {
    CamState.ready => Status.ready,
    CamState.recording => Status.recording,
    CamState.syncing => Status.syncing,
    CamState.warning => Status.warning,
    CamState.lost => Status.lost,
    CamState.soundSync => Status.sound,
  };

  IconData get icon => switch (state) {
    CamState.ready => Icons.check_circle_rounded,
    CamState.recording => Icons.fiber_manual_record_rounded,
    CamState.syncing => Icons.sync_rounded,
    CamState.warning => Icons.warning_amber_rounded,
    CamState.lost => Icons.link_off_rounded,
    CamState.soundSync => Icons.graphic_eq_rounded,
  };

  bool get isReady => state == CamState.ready || state == CamState.recording;
}

/// Sync drift above this (ms) is a warning.
const driftLimitMs = 10.0;

CamStatus statusOf(RemoteDevice d) {
  if (!d.online) {
    return const CamStatus(
      CamState.lost,
      'Lost',
      reason: 'Reconnecting…',
      fix: 'Keep SyncCam open on that phone and on the same Wi-Fi. It reconnects by itself.',
    );
  }
  if (d.recording) return const CamStatus(CamState.recording, 'REC');
  if (d.incompatible) {
    return CamStatus(
      CamState.warning,
      'Update',
      reason: 'Old app',
      fix: 'Update SyncCam on ${d.name} to the same version as this phone.',
    );
  }
  if (!d.cameraReady) {
    return CamStatus(
      CamState.syncing,
      'Starting…',
      fix:
          d.error ??
          'The camera is starting. If it stays like this, open SyncCam on ${d.name}.',
    );
  }
  if (!d.synced) {
    return const CamStatus(
      CamState.syncing,
      'Syncing…',
      fix: 'Matching clocks. This takes a few seconds.',
    );
  }
  if (d.errMs > driftLimitMs) {
    return CamStatus(
      CamState.warning,
      'Drift',
      reason: '±${d.errMs.toStringAsFixed(0)} ms',
      fix:
          'Wi-Fi is slow for ${d.name}. Move closer to the router or use this phone\'s hotspot.',
    );
  }
  if (d.battery != null && d.battery! < 15 && !d.charging) {
    return CamStatus(
      CamState.warning,
      'Battery',
      reason: '${d.battery}%',
      fix: '${d.name} is at ${d.battery}% battery. Plug it in.',
    );
  }
  if (d.lowStorage) {
    return CamStatus(
      CamState.warning,
      'Space',
      reason: formatBytes(d.freeBytes ?? 0),
      fix:
          '${d.name} is low on space. Free up some space or lower the resolution.',
    );
  }
  if (d.hot) {
    return CamStatus(
      CamState.warning,
      'Hot',
      reason: 'Too hot',
      fix:
          '${d.name} is too hot. Take it out of direct sun or remove its case.',
    );
  }
  return const CamStatus(CamState.ready, 'Ready');
}

/// Cameras that aren't ready, with their status (for the ready counter).
List<(RemoteDevice, CamStatus)> notReady(HostServer server) => [
  for (final d in server.devices)
    if (statusOf(d) case final s when !s.isReady) (d, s),
];

/// Screen-reader label for a camera tile.
String semanticsLabel(RemoteDevice d) {
  final s = statusOf(d);
  return [
    'Camera ${d.slot + 1}',
    d.name,
    s.word == 'REC' ? 'recording' : s.word.toLowerCase(),
    ?s.reason,
    if (d.battery != null) 'battery ${d.battery}%',
  ].join(', ');
}
