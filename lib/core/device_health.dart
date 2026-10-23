import 'package:flutter/services.dart';

/// Thermal state, power-saving mode and free storage, read from native code
/// (ios/Runner/AppDelegate.swift, android/.../MainActivity.kt).
class DeviceHealth {
  DeviceHealth({this.thermal, this.lowPower = false, this.freeBytes, this.totalBytes});

  static const _channel = MethodChannel('synccam/device');

  /// nominal | fair | serious | critical (null if the OS doesn't report it).
  final String? thermal;
  final bool lowPower;
  final int? freeBytes;
  final int? totalBytes;

  bool get hot => thermal == 'serious' || thermal == 'critical';

  static Future<DeviceHealth> read() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('health') ?? const {};
      return DeviceHealth(
        thermal: m['thermal'] as String?,
        lowPower: m['lowPower'] as bool? ?? false,
        freeBytes: (m['freeBytes'] as num?)?.toInt(),
        totalBytes: (m['totalBytes'] as num?)?.toInt(),
      );
    } catch (_) {
      return DeviceHealth();
    }
  }
}
