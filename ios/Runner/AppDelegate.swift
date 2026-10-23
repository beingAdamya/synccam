import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceHealthPlugin") {
      DeviceHealthPlugin.register(with: registrar)
    }
  }
}

/// Reports the device conditions that silently ruin a multi-camera take:
/// thermal throttling (iOS stops recording at `critical`), Low Power Mode
/// (lowers camera frame rates), and free storage.
///
/// Dart side: lib/core/device_health.dart, channel "synccam/device".
final class DeviceHealthPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "synccam/device", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DeviceHealthPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "health":
      result(health())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func health() -> [String: Any] {
    let info = ProcessInfo.processInfo
    var out: [String: Any] = [
      "thermal": thermalName(info.thermalState),
      "lowPower": info.isLowPowerModeEnabled,
    ]
    // "Important usage" capacity is what iOS will actually free up for a
    // user-initiated save, so it is the right number for "can I record?".
    let home = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? home.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ]) {
      if let free = values.volumeAvailableCapacityForImportantUsage {
        out["freeBytes"] = NSNumber(value: free)
      }
      if let total = values.volumeTotalCapacity {
        out["totalBytes"] = NSNumber(value: total)
      }
    }
    return out
  }

  private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }
}
