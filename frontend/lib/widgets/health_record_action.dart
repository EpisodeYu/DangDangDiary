import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// A compact swipe action that keeps its icon and caption at their full height.
class HealthRecordAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color backgroundColor;
  final SlidableActionCallback onPressed;

  const HealthRecordAction({
    super.key,
    required this.label,
    required this.icon,
    required this.backgroundColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => CustomSlidableAction(
    onPressed: onPressed,
    backgroundColor: backgroundColor,
    foregroundColor: Colors.white,
    borderRadius: BorderRadius.circular(16),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    // SlidableAction gives the icon, spacer and caption equal Flexible slots.
    // Short record rows can therefore clip text without reporting overflow.
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 24),
        const SizedBox(height: 4),
        Text(label, maxLines: 1),
      ],
    ),
  );
}
