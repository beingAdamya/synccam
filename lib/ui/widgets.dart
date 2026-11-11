import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Backdrop for setup and gallery screens: the theme background with a very
/// faint accent and secondary glow. Never used behind live video.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.glow = true});
  final Widget child;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return ColoredBox(
      color: t.background,
      child: Stack(
        children: [
          if (glow && t.glow > 0) ...[
            Positioned(
              top: -160,
              left: -140,
              child: _Glow(color: t.accent, size: 420, alpha: t.glow),
            ),
            Positioned(
              bottom: -180,
              right: -160,
              child: _Glow(color: t.secondary, size: 460, alpha: t.glow),
            ),
          ],
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size, required this.alpha});
  final Color color;
  final double size;
  final double alpha;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    ),
  );
}

/// The 3D logo.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/icon/logo3d.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
  );
}

/// Frosted glass for controls floating over live video: real blur, the
/// background at 55% and a 1px rim that is brighter at the top-left, so it
/// reads on any picture.
class VideoGlass extends StatelessWidget {
  const VideoGlass({
    super.key,
    required this.child,
    this.radius = SyncTheme.radius,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final hc = context.sync.choice == ThemeChoice.highContrast;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: CustomPaint(
          foregroundPainter: _RimPainter(radius, hc),
          child: Container(
            padding: padding,
            color: hc
                ? Colors.black.withValues(alpha: 0.85)
                : const Color(0xFF050507).withValues(alpha: 0.55),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter(this.radius, this.strong);
  final double radius;
  final bool strong;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strong ? 1.5 : 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: strong
            ? [
                Colors.white.withValues(alpha: 0.6),
                Colors.white.withValues(alpha: 0.35),
              ]
            : [
                Colors.white.withValues(alpha: 0.20),
                Colors.white.withValues(alpha: 0.06),
              ],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.radius != radius || old.strong != strong;
}

/// A panel or card away from live video; tappable when [onTap] is set.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(18),
    this.highlight,
    this.selected = false,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsets padding;

  /// Optional colour for the border (e.g. the primary action).
  final Color? highlight;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    final r = BorderRadius.circular(SyncTheme.radius);
    final edge = selected
        ? t.accent
        : highlight?.withValues(alpha: 0.6) ?? t.line;
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        color: Color.alphaBlend(
          t.glassFill,
          t.surface.withValues(alpha: t.dark ? 0.85 : 1),
        ),
        border: Border.all(
          color: edge,
          width: selected
              ? 2
              : (t.choice == ThemeChoice.highContrast ? 1.5 : 1),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Rounded square with a soft tint and an icon.
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color, this.size = 48});
  final IconData icon;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = color ?? context.sync.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        color: c.withValues(alpha: 0.16),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Icon(icon, color: c, size: size * 0.5),
    );
  }
}

/// The main call to action: a solid accent button.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.expand = true,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final b = FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(56, 56),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20),
            const SizedBox(width: 10),
          ],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: b) : b;
  }
}

/// Big option card: icon, title, one-line explanation, chevron.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color,
    this.highlight = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? color;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.sync.accent;
    return GlassCard(
      onTap: onTap,
      highlight: highlight ? c : null,
      child: Row(
        children: [
          IconBadge(icon, color: c),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: context.sync.muted),
        ],
      ),
    );
  }
}

/// Numbered how-to steps.
class Steps extends StatelessWidget {
  const Steps(this.steps, {super.key});
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final t = context.sync;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t.accent,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: t.onAccent,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      steps[i],
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small pill: icon + word in a status colour. Never colour alone.
class StatusPill extends StatelessWidget {
  const StatusPill(
    this.text, {
    super.key,
    this.color = Status.ready,
    this.icon,
    this.outlined = false,
    this.big = false,
  });
  final String text;
  final Color color;
  final IconData? icon;

  /// Outline only (used for "Lost", so it never looks like recording).
  final bool outlined;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final fs = big ? 15.0 : 12.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: big ? 14 : 9,
        vertical: big ? 8 : 4,
      ),
      decoration: BoxDecoration(
        color: outlined
            ? Colors.black.withValues(alpha: 0.55)
            : color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(SyncTheme.chipRadius),
        border: Border.all(
          color: color.withValues(alpha: outlined ? 1 : 0.45),
          width: outlined ? 1.5 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fs + 2, color: color),
            SizedBox(width: big ? 8 : 5),
          ],
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: fs,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A camera's identity: its number in its colour.
class NumberBadge extends StatelessWidget {
  const NumberBadge(this.slot, {super.key, this.size = 28});
  final int slot;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = CameraColors.forSlot(slot);
    final n = '${slot + 1}';
    return Container(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      height: size,
      padding: EdgeInsets.symmetric(horizontal: n.length > 1 ? size * 0.18 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        n,
        style: TextStyle(
          color: CameraColors.on(c),
          fontWeight: FontWeight.w800,
          fontSize: size * 0.6,
          height: 1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: context.sync.muted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A one-line snackbar with an optional action (e.g. Undo).
void showSnack(
  BuildContext context,
  String text, {
  String? action,
  VoidCallback? onAction,
  Duration? duration,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        duration: duration ?? const Duration(seconds: 4),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
}
