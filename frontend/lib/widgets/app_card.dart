import 'package:flutter/material.dart';

import '../config/theme.dart';

/// Shared soft-shadow recipe used across the polished card / surface
/// widgets in the app. Two layers:
///   * a close, sharp shadow for crispness (small offset, tight blur)
///   * a far, brand-tinted shadow for warmth (long offset, wide blur)
///
/// Keep both layers' alpha low — what feels like depth on a real device
/// is the *sum* of two diffuse layers, not a single dark one.
final List<BoxShadow> kAppSoftShadow = [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.04),
    blurRadius: 12,
    offset: const Offset(0, 2),
  ),
  BoxShadow(
    color: AppTheme.primaryColor.withValues(alpha: 0.05),
    blurRadius: 28,
    offset: const Offset(0, 10),
  ),
];

/// Slightly stronger variant for cards that need to read as the screen's
/// hero block (e.g., the profile header, photo preview card).
final List<BoxShadow> kAppLiftedShadow = [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.06),
    blurRadius: 16,
    offset: const Offset(0, 4),
  ),
  BoxShadow(
    color: AppTheme.primaryColor.withValues(alpha: 0.07),
    blurRadius: 40,
    offset: const Offset(0, 16),
  ),
];

/// A rounded, soft-shadowed surface used as the base of all "card-like"
/// blocks. Replaces ad-hoc `Container(decoration: BoxDecoration(...))`
/// blocks scattered across screens, so the radius / shadow / background
/// can evolve in one place.
///
/// Use [AppCard] when the content needs a default 16px radius + the
/// shared soft shadow. Pass [lifted] = true for "hero" surfaces.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final double radius;
  final bool lifted;
  final Border? border;
  final VoidCallback? onTap;
  final BorderRadius? borderRadiusOverride;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.color,
    this.radius = 16,
    this.lifted = false,
    this.border,
    this.onTap,
    this.borderRadiusOverride,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadiusOverride ?? BorderRadius.circular(radius);
    final bg = color ?? AppTheme.surfaceColor;
    final decoration = BoxDecoration(
      color: bg,
      borderRadius: br,
      boxShadow: lifted ? kAppLiftedShadow : kAppSoftShadow,
      border: border,
    );

    Widget body = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: child,
    );

    if (onTap != null) {
      body = Material(
        color: Colors.transparent,
        borderRadius: br,
        child: InkWell(
          borderRadius: br,
          onTap: onTap,
          child: body,
        ),
      );
    }

    return Container(
      margin: margin,
      decoration: decoration,
      child: ClipRRect(borderRadius: br, child: body),
    );
  }
}
