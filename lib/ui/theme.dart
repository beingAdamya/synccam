import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// The three looks. Studio is the default and is always used over live video;
/// Daylight is for the gallery and setup; High contrast is for bright
/// outdoor shoots.
enum ThemeChoice { studio, daylight, highContrast }

extension ThemeChoiceLabel on ThemeChoice {
  String get label => switch (this) {
    ThemeChoice.studio => 'Studio (dark)',
    ThemeChoice.daylight => 'Daylight (light)',
    ThemeChoice.highContrast => 'High contrast',
  };
}

/// Every colour, font and shape SyncCam uses comes from one of these.
@immutable
class SyncTheme extends ThemeExtension<SyncTheme> {
  const SyncTheme({
    required this.choice,
    required this.accent,
    required this.onAccent,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.text,
    required this.muted,
    required this.line,
    required this.glassFill,
    required this.statusBorder,
    required this.glow,
  });

  final ThemeChoice choice;
  final Color accent;
  final Color onAccent;
  final Color secondary;
  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color text;
  final Color muted;
  final Color line;

  /// Fill for panels and cards away from live video.
  final Color glassFill;

  /// Width of status outlines on camera tiles (thicker in high contrast).
  final double statusBorder;

  /// Strength of the soft backdrop glow (0 = none).
  final double glow;

  bool get dark => choice != ThemeChoice.daylight;

  // Shape
  static const double radius = 16;
  static const double tileRadius = 12;
  static const double chipRadius = 22;

  static const studio = SyncTheme(
    choice: ThemeChoice.studio,
    accent: Color(0xFF5EEAD4),
    onAccent: Color(0xFF04231F),
    secondary: Color(0xFF8B9CFF),
    background: Color(0xFF050507),
    surface: Color(0xFF111116),
    surfaceHigh: Color(0xFF1C1C24),
    text: Color(0xEBFFFFFF),
    muted: Color(0x99FFFFFF),
    line: Color(0x1AFFFFFF),
    glassFill: Color(0x0FFFFFFF),
    statusBorder: 2,
    glow: 0.15,
  );

  static const daylight = SyncTheme(
    choice: ThemeChoice.daylight,
    accent: Color(0xFF0E8F80),
    onAccent: Colors.white,
    secondary: Color(0xFF5566D6),
    background: Color(0xFFF3F4F7),
    surface: Colors.white,
    surfaceHigh: Color(0xFFE9EBF0),
    text: Color(0xEB0A0B10),
    muted: Color(0x990A0B10),
    line: Color(0x1A0A0B10),
    glassFill: Color(0xB3FFFFFF),
    statusBorder: 2,
    glow: 0.10,
  );

  static const highContrast = SyncTheme(
    choice: ThemeChoice.highContrast,
    accent: Color(0xFF5EEAD4),
    onAccent: Colors.black,
    secondary: Color(0xFF8B9CFF),
    background: Colors.black,
    surface: Colors.black,
    surfaceHigh: Color(0xFF1A1A1A),
    text: Colors.white,
    muted: Color(0xD9FFFFFF),
    line: Color(0x66FFFFFF),
    glassFill: Colors.black,
    statusBorder: 3,
    glow: 0,
  );

  static SyncTheme of(ThemeChoice c) => switch (c) {
    ThemeChoice.studio => studio,
    ThemeChoice.daylight => daylight,
    ThemeChoice.highContrast => highContrast,
  };

  @override
  SyncTheme copyWith() => this;

  @override
  SyncTheme lerp(ThemeExtension<SyncTheme>? other, double t) =>
      t < 0.5 || other is! SyncTheme ? this : other;
}

extension SyncThemeX on BuildContext {
  SyncTheme get sync =>
      Theme.of(this).extension<SyncTheme>() ?? SyncTheme.studio;
}

/// Status colours: the same in every theme, and always shown together with
/// an icon and a word.
class Status {
  static const ready = Color(0xFF39D98A);
  static const recording = Color(0xFFFF3B4E);
  static const syncing = Color(0xFFFFC53D);
  static const warning = Color(0xFFFF9F43);
  static const lost = Color(0xFFFF4D6A);
  static const sound = Color(0xFF8B9CFF);
}

/// Each camera keeps one number and one of these colours everywhere: its
/// tile, its badge, its clips in the gallery and its own screen.
class CameraColors {
  static const all = [
    Color(0xFF5EEAD4), // mint
    Color(0xFF8B9CFF), // periwinkle
    Color(0xFFFFC53D), // amber
    Color(0xFFFF7AB6), // pink
    Color(0xFF4FC3F7), // sky
    Color(0xFFB5E853), // lime
    Color(0xFFFF8A65), // coral
    Color(0xFFB388FF), // violet
  ];

  static Color forSlot(int slot) => all[slot.abs() % all.length];

  /// Black or white, whichever reads better on [c].
  static Color on(Color c) =>
      c.computeLuminance() > 0.4 ? Colors.black : Colors.white;
}

/// Tabular mono text for timecodes, latency, sizes and other numbers.
TextStyle mono({
  double size = 13,
  Color? color,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: 'JetBrainsMono',
  fontSize: size,
  color: color,
  fontWeight: weight,
  fontFeatures: const [FontFeature.tabularFigures()],
  letterSpacing: 0,
);

/// Older screens refer to these names; they map onto the Studio palette.
class Brand {
  static const bg = Color(0xFF050507);
  static const surface = Color(0xFF111116);
  static const surfaceHigh = Color(0xFF1C1C24);
  static const line = Color(0x1AFFFFFF);
  static const text = Color(0xEBFFFFFF);
  static const textDim = Color(0x99FFFFFF);
  static const textFaint = Color(0x66FFFFFF);
  static const accent = Color(0xFF5EEAD4);
  static const secondary = Color(0xFF8B9CFF);
  static const good = Status.ready;
  static const warn = Status.warning;
  static const bad = Status.lost;
  static const red = Status.recording;
  static const coral = accent;
  static const sky = Color(0xFF4FC3F7);
  static const violet = Color(0xFFB388FF);
  static const radius = SyncTheme.radius;
}

ThemeData buildTheme([ThemeChoice choice = ThemeChoice.studio]) {
  final t = SyncTheme.of(choice);
  final brightness = t.dark ? Brightness.dark : Brightness.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.accent,
        brightness: brightness,
      ).copyWith(
        primary: t.accent,
        onPrimary: t.onAccent,
        secondary: t.secondary,
        surface: t.surface,
        onSurface: t.text,
        onSurfaceVariant: t.muted,
        surfaceContainerLowest: t.background,
        surfaceContainerLow: t.surface,
        surfaceContainer: t.surface,
        surfaceContainerHigh: t.surfaceHigh,
        surfaceContainerHighest: t.surfaceHigh,
        primaryContainer: t.accent.withValues(alpha: 0.18),
        onPrimaryContainer: t.dark ? t.accent : const Color(0xFF064A42),
        secondaryContainer: t.accent.withValues(alpha: 0.18),
        onSecondaryContainer: t.dark ? t.accent : const Color(0xFF064A42),
        outline: t.line,
        outlineVariant: t.line,
        error: Status.lost,
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Inter',
  );
  final text = base.textTheme.apply(bodyColor: t.text, displayColor: t.text);
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(SyncTheme.radius),
  );
  final border = BorderSide(
    color: t.line,
    width: choice == ThemeChoice.highContrast ? 1.5 : 1,
  );
  return base.copyWith(
    extensions: [t],
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: text.bodyMedium?.copyWith(color: t.text, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(color: t.muted, height: 1.4),
      labelSmall: text.labelSmall?.copyWith(color: t.muted, letterSpacing: 0.6),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: t.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: t.text,
      ),
    ),
    cardTheme: CardThemeData(
      color: t.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SyncTheme.radius),
        side: border,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: border,
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: t.text,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: t.muted,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: t.surfaceHigh,
      actionTextColor: t.accent,
      contentTextStyle: TextStyle(fontFamily: 'Inter', color: t.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SyncTheme.radius),
        side: border,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        minimumSize: const Size(48, 48),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.text,
        minimumSize: const Size(48, 48),
        shape: shape,
        side: border,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.accent,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: t.surfaceHigh,
      selectedColor: t.accent.withValues(alpha: 0.2),
      side: border,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
      ),
      labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 13, color: t.text),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape),
        side: WidgetStatePropertyAll(border),
        minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? t.accent.withValues(alpha: 0.2)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? (t.dark ? t.accent : const Color(0xFF064A42))
              : t.text,
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: t.accent,
      thumbColor: t.dark ? Colors.white : t.accent,
      inactiveTrackColor: t.line,
      overlayColor: t.accent.withValues(alpha: 0.15),
      valueIndicatorTextStyle: mono(color: t.onAccent),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : t.surfaceHigh,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? t.onAccent
            : (t.dark ? Colors.white70 : Colors.white),
      ),
      trackOutlineColor: WidgetStatePropertyAll(t.line),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SyncTheme.radius),
        borderSide: border,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SyncTheme.radius),
        borderSide: border,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SyncTheme.radius),
        borderSide: BorderSide(color: t.accent),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.muted,
      textColor: t.text,
      minVerticalPadding: 10,
    ),
    dividerTheme: DividerThemeData(color: t.line, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.accent,
      linearTrackColor: t.line,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(t.onAccent),
      side: BorderSide(color: t.muted, width: 1.5),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
