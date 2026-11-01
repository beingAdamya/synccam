import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'updates.dart';

/// Downloads an update inside the app and hands it to Android's installer,
/// so updating is: tap Update → watch the progress bar → tap Install.
class UpdateInstaller {
  static const _channel = MethodChannel('synccam/device');

  /// Streams the APK to the app's cache, reporting progress 0..1. Verifies
  /// the size and SHA-256 GitHub published, so a broken or tampered file is
  /// never installed.
  static Future<File> download(ReleaseInfo r,
      {required void Function(double) onProgress, bool Function()? cancelled, Directory? into}) async {
    final url = r.apkUrl;
    if (url == null) throw StateError('This release has no Android app file.');
    final dir = into ?? Directory('${(await getTemporaryDirectory()).path}/updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}/SyncCam-${r.tag}.apk');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Download failed (HTTP ${res.statusCode})');
      final total = r.apkSize ?? (res.contentLength > 0 ? res.contentLength : null);
      final sink = file.openWrite();
      final sha = SHA256Digest();
      var got = 0;
      await for (final chunk in res) {
        if (cancelled?.call() ?? false) {
          await sink.close();
          throw const _Cancelled();
        }
        sink.add(chunk);
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        sha.update(bytes, 0, bytes.length);
        got += chunk.length;
        if (total != null) onProgress((got / total).clamp(0, 1));
      }
      await sink.close();
      if (r.apkSize != null && got != r.apkSize) {
        throw StateError('The download was incomplete. Please try again.');
      }
      final out = Uint8List(32);
      sha.doFinal(out, 0);
      final hex = out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (r.apkSha256 != null && hex != r.apkSha256) {
        await file.delete();
        throw StateError('The downloaded file didn\'t match the release, so it wasn\'t installed. Please try again.');
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }

  /// Opens Android's install screen. Returns false if the user first has to
  /// allow SyncCam to install updates (Android opens that setting).
  static Future<bool> install(File apk) async {
    final r = await _channel.invokeMethod<String>('installApk', {'path': apk.path});
    return r == 'started';
  }

  static bool isCancel(Object e) => e is _Cancelled;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// "A new version is ready" notifications, including when the app is closed.
class UpdateNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _notifiedKey = 'update.notifiedTag';
  static bool _ready = false;

  /// Set when the user opens the app by tapping an update notification.
  static final ValueNotifier<bool> openedFromNotification = ValueNotifier(false);

  static Future<void> init() async {
    if (_ready || !(Platform.isAndroid || Platform.isIOS)) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (_) => openedFromNotification.value = true,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) openedFromNotification.value = true;
    _ready = true;
  }

  /// Asks for permission to show notifications (Android 13+, iOS).
  static Future<bool> requestPermission() async {
    await init();
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
  }

  /// Shows the notification once per version.
  static Future<void> notify(ReleaseInfo r) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_notifiedKey) == r.tag) return;
    await init();
    await _plugin.show(
      id: 7001,
      title: 'SyncCam ${r.version} is ready',
      body: 'Tap to see what\'s new and update in one step.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'updates',
          'App updates',
          channelDescription: 'Tells you when a new version of SyncCam is available',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
    await prefs.setString(_notifiedKey, r.tag);
  }
}

/// Checks for updates in the background every few hours (Android), so users
/// hear about a new version without opening the app.
class BackgroundUpdates {
  static const _task = 'synccam.updateCheck';

  static Future<void> schedule() async {
    if (!Platform.isAndroid) return;
    await Workmanager().initialize(updateCheckDispatcher);
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: const Duration(hours: 6),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}

@pragma('vm:entry-point')
void updateCheckDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await AppVersion.load();
      final r = await UpdateChecker.check(force: true);
      if (r != null) await UpdateNotifications.notify(r);
    } catch (_) {
      // offline or rate-limited: try again next time
    }
    return true;
  });
}
