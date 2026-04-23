import 'package:flutter/material.dart';
import '../config/theme.dart';

class FluorescentTag extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;

  const FluorescentTag({
    super.key,
    required this.child,
    this.color = AppTheme.accentYellow,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            offset: const Offset(2, 2),
            blurRadius: 4,
          ),
        ],
      ),
      child: child,
    );
  }
}
