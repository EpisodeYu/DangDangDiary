import 'package:flutter/material.dart';

import 'app_card.dart';
import 'app_page_intro.dart';

/// Scrollable fields and action, also when the keyboard is open.
class AppFormBody extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;
  final Widget action;
  const AppFormBody({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
    required this.action,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        AppPageIntro(title: title, subtitle: subtitle, icon: icon),
        AppCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
        const SizedBox(height: 24),
        action,
      ],
    ),
  );
}
