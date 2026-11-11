import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';

/// App-wide choices from the Settings tab.
class AppPrefs {
  static final theme = ValueNotifier<ThemeChoice>(ThemeChoice.studio);
  static bool haptics = true;
  static bool sounds = false;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString('theme');
    theme.value = ThemeChoice.values.firstWhere(
      (c) => c.name == t,
      orElse: () => ThemeChoice.studio,
    );
    haptics = p.getBool('haptics') ?? true;
    sounds = p.getBool('sounds') ?? false;
  }

  static Future<void> setTheme(ThemeChoice c) async {
    theme.value = c;
    (await SharedPreferences.getInstance()).setString('theme', c.name);
  }

  static Future<void> setHaptics(bool v) async {
    haptics = v;
    (await SharedPreferences.getInstance()).setBool('haptics', v);
  }

  static Future<void> setSounds(bool v) async {
    sounds = v;
    (await SharedPreferences.getInstance()).setBool('sounds', v);
  }
}

/// Haptic patterns from the design: medium on the shutter, light on record
/// start/stop, a double tap when every camera is ready, a warning when one
/// drops out.
class Haptic {
  static void shutter() {
    if (AppPrefs.haptics) HapticFeedback.mediumImpact();
  }

  static void light() {
    if (AppPrefs.haptics) HapticFeedback.lightImpact();
  }

  static void tick() {
    if (AppPrefs.haptics) HapticFeedback.selectionClick();
  }

  static Future<void> allReady() async {
    if (!AppPrefs.haptics) return;
    await HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.lightImpact();
  }

  static Future<void> warning() async {
    if (!AppPrefs.haptics) return;
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await HapticFeedback.heavyImpact();
  }
}
