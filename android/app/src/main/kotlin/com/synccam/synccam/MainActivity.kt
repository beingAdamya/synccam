package com.synccam.synccam

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
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
                    "installApk" -> result.success(installApk(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            }
    }

    /// Opens Android's installer for a downloaded update. If SyncCam isn't
    /// yet allowed to install apps, opens that setting and returns
    /// "needs_permission" so the app can ask the user to try again.
    private fun installApk(path: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return "started"
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
