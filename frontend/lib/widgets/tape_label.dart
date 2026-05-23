import 'package:flutter/material.dart';

import '../config/theme.dart';

/// A small "washi-tape"-flavored label used as the section header for
/// each day group on the timeline. Visually:
///
///   * a slightly translucent brand-tinted rectangle
///   * thin angled white "tear" stripes on each end to suggest tape
///   * a hair of rotation for hand-stuck feel
///
/// All drawing is done in CustomPaint, so no extra assets are needed.
class TapeLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  final Color? color;
  final double rotationDegrees;
  final EdgeInsetsGeometry padding;

  const TapeLabel({
    super.key,
    required this.text,
    this.trailing,
    this.color,
    this.rotationDegrees = -1.2,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.primaryColor;
    return Transform.rotate(
      angle: rotationDegrees * 3.1415926 / 180,
      child: CustomPaint(
        painter: _TapePainter(color: c),
        child: Padding(
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _onTape(c),
                  letterSpacing: 0.5,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                Text(
                  trailing!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _onTape(c).withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Choose a text color that reads well on the tinted tape. The tape
  /// color is always a low-alpha tint of `primary`, so a dark-warm
  /// brown reads correctly without needing a real contrast check.
  static Color _onTape(Color tape) => const Color(0xFF5A3A2E);
}

class _TapePainter extends CustomPainter {
  final Color color;

  _TapePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final body = Paint()..color = color.withValues(alpha: 0.22);
    final stripe = Paint()..color = Colors.white.withValues(alpha: 0.55);

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(2),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRRect(rrect, body);

    // Diagonal "tear" stripes near each end suggest cellotape edges.
    final stripeWidth = 6.0;
    for (final x in [size.width * 0.04, size.width * 0.10]) {
      final path = Path()
        ..moveTo(x - stripeWidth / 2, -2)
        ..lineTo(x + stripeWidth / 2, -2)
        ..lineTo(x + stripeWidth / 2 + 6, size.height + 2)
        ..lineTo(x - stripeWidth / 2 + 6, size.height + 2)
        ..close();
      canvas.drawPath(path, stripe);
    }
    for (final x in [size.width * 0.90, size.width * 0.96]) {
      final path = Path()
        ..moveTo(x - stripeWidth / 2, -2)
        ..lineTo(x + stripeWidth / 2, -2)
        ..lineTo(x + stripeWidth / 2 + 6, size.height + 2)
        ..lineTo(x - stripeWidth / 2 + 6, size.height + 2)
        ..close();
      canvas.drawPath(path, stripe);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TapePainter old) => old.color != color;
}
