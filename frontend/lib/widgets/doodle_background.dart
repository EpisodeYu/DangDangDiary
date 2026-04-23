import 'package:flutter/material.dart';
import 'dart:math' as math;

class DoodleBackground extends StatelessWidget {
  final Widget child;

  const DoodleBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _DoodlePainter(),
          ),
        ),
        child,
      ],
    );
  }
}

class _DoodlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final random = math.Random(42); // Fixed seed for consistent doodles

    // Draw some random doodles (paw prints, bones, lines)
    for (int i = 0; i < 15; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final type = random.nextInt(3);
      final angle = random.nextDouble() * math.pi * 2;
      final scale = 0.5 + random.nextDouble() * 0.5;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.scale(scale);

      if (type == 0) {
        _drawPawPrint(canvas, paint);
      } else if (type == 1) {
        _drawBone(canvas, paint);
      } else {
        _drawSquiggle(canvas, paint, random);
      }

      canvas.restore();
    }
  }

  void _drawPawPrint(Canvas canvas, Paint paint) {
    // Main pad
    canvas.drawPath(
      Path()
        ..moveTo(0, 5)
        ..quadraticBezierTo(10, 0, 15, 10)
        ..quadraticBezierTo(20, 20, 10, 25)
        ..quadraticBezierTo(0, 30, -5, 20)
        ..quadraticBezierTo(-10, 10, 0, 5),
      paint,
    );
    // Toes
    canvas.drawCircle(const Offset(-10, -5), 4, paint);
    canvas.drawCircle(const Offset(0, -12), 4, paint);
    canvas.drawCircle(const Offset(12, -10), 4, paint);
    canvas.drawCircle(const Offset(20, 2), 4, paint);
  }

  void _drawBone(Canvas canvas, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(-15, -5)
        ..lineTo(15, -5)
        ..arcToPoint(const Offset(20, -10), radius: const Radius.circular(5))
        ..arcToPoint(const Offset(20, 0), radius: const Radius.circular(5))
        ..arcToPoint(const Offset(15, 5), radius: const Radius.circular(5))
        ..lineTo(-15, 5)
        ..arcToPoint(const Offset(-20, 10), radius: const Radius.circular(5))
        ..arcToPoint(const Offset(-20, 0), radius: const Radius.circular(5))
        ..arcToPoint(const Offset(-15, -5), radius: const Radius.circular(5)),
      paint,
    );
  }

  void _drawSquiggle(Canvas canvas, Paint paint, math.Random random) {
    final path = Path()..moveTo(0, 0);
    double cx = 0;
    double cy = 0;
    for (int i = 0; i < 3; i++) {
      final nx = cx + (random.nextDouble() * 20 - 10);
      final ny = cy + (random.nextDouble() * 20 - 10);
      path.quadraticBezierTo(
        cx + (random.nextDouble() * 10 - 5),
        cy + (random.nextDouble() * 10 - 5),
        nx,
        ny,
      );
      cx = nx;
      cy = ny;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
