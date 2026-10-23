package com.synccam.synccam

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Same contract as DeviceHealthPlugin in ios/Runner/AppDelegate.swift.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synccam/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "health" -> result.success(health())
                    else -> result.notImplemented()
                }
            }
    }

    private fun health(): Map<String, Any> {
        val out = mutableMapOf<String, Any>()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        out["lowPower"] = pm.isPowerSaveMode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Map Android's 7 levels onto the 4 iOS names the app uses.
            out["thermal"] = when (pm.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> "nominal"
                PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> "fair"
                PowerManager.THERMAL_STATUS_SEVERE -> "serious"
                else -> "critical"
            }
        }
        val stat = StatFs(filesDir.path)
        out["freeBytes"] = stat.availableBytes
        out["totalBytes"] = stat.totalBytes
        return out
    }
}
