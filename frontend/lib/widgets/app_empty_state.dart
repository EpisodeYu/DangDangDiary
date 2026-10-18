import 'package:flutter/material.dart';

import '../config/theme.dart';
import 'app_page_intro.dart';

/// Suitable for lists and full pages, including larger system text.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIconBadge(icon: icon, size: 80),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 10),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              height: 1.7,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 24), action!],
      ],
    ),
  );
}
