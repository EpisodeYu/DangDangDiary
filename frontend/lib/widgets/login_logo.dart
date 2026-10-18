import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A gentle, one-time entrance. Respects the system's reduced-motion setting.
class LoginLogo extends StatelessWidget {
  final double size;
  const LoginLogo({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    final logo = SvgPicture.asset(
      'assets/brand/logo.svg',
      width: size,
      height: size,
    );
    if (MediaQuery.disableAnimationsOf(context)) return logo;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      child: logo,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(scale: .94 + .06 * value, child: child),
      ),
    );
  }
}
