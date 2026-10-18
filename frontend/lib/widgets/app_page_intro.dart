import 'package:flutter/material.dart';

import '../config/theme.dart';

/// Consistent content headings without adding an action or navigation step.
class AppPageIntro extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData? icon;
  const AppPageIntro({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        if (icon != null) ...[
          const SizedBox(width: 16),
          AppIconBadge(icon: icon!),
        ],
      ],
    ),
  );
}

class AppIconBadge extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final Color background;
  const AppIconBadge({
    super.key,
    required this.icon,
    this.size = 48,
    this.color = AppTheme.accentColor,
    this.background = AppTheme.softPeach,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(size * .35),
    ),
    child: Icon(icon, size: size * .48, color: color),
  );
}

class AppSectionTitle extends StatelessWidget {
  final String title;
  const AppSectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppTheme.textPrimary,
      ),
    ),
  );
}
