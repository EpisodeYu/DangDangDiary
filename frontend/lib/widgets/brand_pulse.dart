import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'brand_mark.dart';

class BrandPulse extends StatefulWidget {
  final double size;
  const BrandPulse({super.key, this.size = 32});

  @override
  State<BrandPulse> createState() => _BrandPulseState();
}

class _BrandPulseState extends State<BrandPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _rotation;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    
    _rotation = Tween<double>(begin: 0, end: math.pi).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _rotation,
      builder: (context, _) {
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001) // perspective
            ..rotateY(_rotation.value),
          child: BrandMark(size: widget.size),
        );
      },
    );
  }
}
