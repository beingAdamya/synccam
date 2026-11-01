import 'package:flutter/material.dart';

import 'theme.dart';

/// Full-screen backdrop: deep gradient with two soft color glows.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Brand.bg2, Brand.bg],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(children: [
        const Positioned(top: -140, left: -120, child: _Glow(color: Brand.red, size: 380, alpha: 0.18)),
        const Positioned(bottom: -160, right: -140, child: _Glow(color: Brand.violet, size: 420, alpha: 0.14)),
        Positioned.fill(child: child),
      ]),
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
            gradient: RadialGradient(colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)]),
          ),
        ),
      );
}

/// The 3D logo.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/icon/logo3d.png', width: size, height: size, filterQuality: FilterQuality.medium);
}

/// A rounded, softly bordered card; tappable when [onTap] is set.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(18), this.highlight});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  /// Optional accent color for a glowing border (e.g. the primary action).
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(Brand.radius);
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: LinearGradient(
          colors: [Brand.surfaceHigh.withValues(alpha: 0.92), Brand.surface.withValues(alpha: 0.92)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: highlight?.withValues(alpha: 0.55) ?? Brand.line),
        boxShadow: [
          BoxShadow(color: (highlight ?? Colors.black).withValues(alpha: highlight == null ? 0.25 : 0.18), blurRadius: 28, spreadRadius: -6, offset: const Offset(0, 6)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: r, onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Rounded square with a gradient and an icon.
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color = Brand.red, this.size = 48});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.32),
          gradient: color == Brand.red ? Brand.accent : Brand.tint(color),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 18, spreadRadius: -4, offset: const Offset(0, 4))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      );
}

/// The main call-to-action: a gradient pill with a soft glow.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.icon, required this.onPressed, this.expand = true});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 10)],
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        ),
      ],
    );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: Brand.accent,
          borderRadius: BorderRadius.circular(18),
          boxShadow: enabled
              ? [BoxShadow(color: Brand.red.withValues(alpha: 0.4), blurRadius: 22, spreadRadius: -6, offset: const Offset(0, 6))]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onPressed,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16), child: child),
          ),
        ),
      ),
    );
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
    this.color = Brand.red,
    this.highlight = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color color;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      highlight: highlight ? color : null,
      child: Row(children: [
        IconBadge(icon, color: color),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: Brand.textFaint),
      ]),
    );
  }
}

/// Numbered how-to steps.
class Steps extends StatelessWidget {
  const Steps(this.steps, {super.key});
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: const BoxDecoration(shape: BoxShape.circle, gradient: Brand.accent),
              child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 13)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(steps[i], style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// Small colored status pill.
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.color = Brand.good, this.icon});
  final String text;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 6)],
          Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: Brand.textFaint, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      );
}
