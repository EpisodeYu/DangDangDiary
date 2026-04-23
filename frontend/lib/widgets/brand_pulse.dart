import 'package:flutter/material.dart';

import 'brand_mark.dart';

/// Branded loading indicator: a mono brand mark breathing in/out.
/// Drop-in replacement for [CircularProgressIndicator] in places where we
/// want the load state to feel on-brand rather than generic Material.
class BrandPulse extends StatefulWidget {
  final double size;
  final Color? color;

  const BrandPulse({super.key, this.size = 32, this.color});

  @override
  State<BrandPulse> createState() => _BrandPulseState();
}

class _BrandPulseState extends State<BrandPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final scale = 0.9 + 0.2 * t;
        final opacity = 0.5 + 0.5 * t;
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: BrandMark(size: widget.size, color: widget.color),
          ),
        );
      },
    );
  }
}
