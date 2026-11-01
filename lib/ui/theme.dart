import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// SyncCam's look: deep charcoal with soft colored glows, glassy cards, and a
/// coral-to-red accent gradient taken from the logo's ring.
class Brand {
  static const bg = Color(0xFF0D0E13);
  static const bg2 = Color(0xFF161822);
  static const surface = Color(0xFF1A1C26);
  static const surfaceHigh = Color(0xFF232634);
  static const line = Color(0x1FFFFFFF);
  static const text = Color(0xFFF4F5F8);
  static const textDim = Color(0xFFA7ABBA);
  static const textFaint = Color(0xFF6E7385);
  static const coral = Color(0xFFFF7A59);
  static const red = Color(0xFFFF3D5A);
  static const good = Color(0xFF3DDC97);
  static const warn = Color(0xFFFFB547);
  static const bad = Color(0xFFFF5C6C);
  static const violet = Color(0xFF7C5CFF);
  static const sky = Color(0xFF4FC3F7);

  static const accent = LinearGradient(
    colors: [coral, red],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient tint(Color c) => LinearGradient(
        colors: [Color.lerp(c, Colors.white, 0.15)!, c],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static const radius = 22.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.red,
    brightness: Brightness.dark,
  ).copyWith(
    primary: Brand.red,
    secondary: Brand.coral,
    surface: Brand.surface,
    surfaceContainer: Brand.surface,
    surfaceContainerHigh: Brand.surfaceHigh,
    surfaceContainerHighest: Brand.surfaceHigh,
    onSurface: Brand.text,
    primaryContainer: const Color(0xFF3A1C24),
    onPrimaryContainer: const Color(0xFFFFD9DE),
    error: Brand.bad,
  );
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme, fontFamily: 'Poppins');
  final text = base.textTheme.apply(bodyColor: Brand.text, displayColor: Brand.text);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: text.bodyMedium?.copyWith(color: Brand.text, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(color: Brand.textDim, height: 1.4),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: 'Poppins', fontSize: 20, fontWeight: FontWeight.w700, color: Brand.text),
    ),
    cardTheme: CardThemeData(
      color: Brand.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        side: const BorderSide(color: Brand.line),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Brand.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 20, fontWeight: FontWeight.w700, color: Brand.text),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Brand.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Brand.surfaceHigh,
      contentTextStyle: const TextStyle(fontFamily: 'Poppins', color: Brand.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        side: const BorderSide(color: Brand.line),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Brand.coral,
        textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Brand.surfaceHigh,
      selectedColor: const Color(0xFF3A1C24),
      side: const BorderSide(color: Brand.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      labelStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 13, color: Brand.text),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape),
        side: const WidgetStatePropertyAll(BorderSide(color: Brand.line)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: Brand.red,
      thumbColor: Colors.white,
      inactiveTrackColor: Brand.line,
      overlayColor: Brand.red.withValues(alpha: 0.15),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Brand.red : Brand.surfaceHigh),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Brand.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Brand.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Brand.coral)),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Brand.textDim),
    dividerTheme: const DividerThemeData(color: Brand.line, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
