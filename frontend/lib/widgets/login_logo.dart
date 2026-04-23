import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Animated brand logo used on the login screen.
///
/// Plays a short elastic "wobble" on first frame, then repeats every 4
/// seconds. Range is ±6° so it catches the eye without being distracting.
class LoginLogo extends StatefulWidget {
  final double size;
  const LoginLogo({super.key, this.size = 88});

  @override
  State<LoginLogo> createState() => _LoginLogoState();
}

class _LoginLogoState extends State<LoginLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _wobble;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) _c.forward(from: 0);
          });
        }
      });
    _wobble = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _c, curve: Curves.elasticOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _wobble,
      builder: (context, _) {
        final angle = (_wobble.value - 0.5) * 0.21;
        return Transform.rotate(
          angle: angle,
          child: SvgPicture.asset(
            'assets/brand/logo.svg',
            width: widget.size,
            height: widget.size,
          ),
        );
      },
    );
  }
}
