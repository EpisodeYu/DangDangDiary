import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../config/theme.dart';

/// Bottom navigation host for the four top-level tabs.
///
/// UI polish notes:
///   * Material icons replaced with Phosphor (regular for inactive, fill
///     for active) — gives a noticeably warmer, less generic feel.
///   * Selected item gets a soft brand-tinted pill behind the icon and a
///     subtle scale bump so the tap registers physically.
///   * Light haptic on every tab change (matches iOS-class polish).
class MainScaffold extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const MainScaffold({super.key, required this.navigationShell});

  static List<_TabSpec> get _tabs => [
        _TabSpec(
          label: '记录',
          regular: Icons.camera_alt_rounded,
          fill: Icons.camera_alt_rounded,
        ),
        _TabSpec(
          label: '健康',
          regular: Icons.pets_rounded,
          fill: Icons.pets,
        ),
        _TabSpec(
          label: '时间轴',
          regular: Icons.menu_book_rounded,
          fill: Icons.menu_book_rounded,
        ),
        _TabSpec(
          label: '我的',
          regular: Icons.account_circle_outlined,
          fill: Icons.account_circle_rounded,
        ),
      ];

  void _onTap(int index) {
    HapticFeedback.selectionClick();
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = navigationShell.currentIndex;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 16,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          minimum: EdgeInsets.only(bottom: bottomInset > 0 ? 0.0 : 6.0),
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                for (int i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: _NavItem(
                      spec: _tabs[i],
                      selected: i == current,
                      onTap: () => _onTap(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData regular;
  final IconData fill;

  const _TabSpec({
    required this.label,
    required this.regular,
    required this.fill,
  });
}

class _NavItem extends StatelessWidget {
  final _TabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primaryColor : AppTheme.textSecondary;
    return InkResponse(
      onTap: onTap,
      radius: 36,
      highlightShape: BoxShape.circle,
      splashColor: AppTheme.primaryColor.withValues(alpha: 0.10),
      highlightColor: AppTheme.primaryColor.withValues(alpha: 0.06),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.primaryColor.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: AnimatedScale(
              scale: selected ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Icon(
                selected ? spec.fill : spec.regular,
                size: 22,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            spec.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

