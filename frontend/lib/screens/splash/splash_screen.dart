import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/auth_provider.dart';

/// Splash route used as the app's `initialLocation`.
///
/// Responsibilities:
///   - Play a short brand intro (logo scale/fade + title slide) to replace
///     the Flutter-engine startup white flash.
///   - Cover auth initialisation: while `authProvider.status` is
///     [AuthStatus.unknown] we keep breathing the logo instead of dumping
///     the user on `/login` prematurely.
///   - Guarantee a minimum display window so the intro animation isn't
///     clipped when auth is cached and resolves in <100ms.
///   - Navigate to `/record` or `/login` once auth is decided.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _idle;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _pulse;

  bool _routed = false;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    _logoScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(
        parent: _intro,
        curve: const Interval(0, 0.44, curve: Curves.easeOutBack),
      ),
    );
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _intro,
        curve: const Interval(0, 0.44, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.44, 1.0, curve: Curves.easeOut),
      ),
    );
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.44, 1.0, curve: Curves.easeOut),
      ),
    );

    // Pulse: scale 1.0 -> 1.06 -> 1.0 across one _idle cycle.
    _pulse = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.06),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.06, end: 1.0),
        weight: 1,
      ),
    ]).animate(CurvedAnimation(parent: _idle, curve: Curves.easeInOut));

    _startFlow();
  }

  Future<void> _startFlow() async {
    await _intro.forward();
    if (!mounted) return;

    // Kick off first breath, but also enforce a minimum total splash window
    // so the animation doesn't feel clipped when auth is already cached.
    unawaited(_idle.forward());
    await Future.delayed(const Duration(milliseconds: 600));

    while (mounted && !_routed) {
      final auth = ref.read(authProvider);
      if (auth.status != AuthStatus.unknown) {
        _routed = true;
        if (_idle.isAnimating) {
          await _idle.forward();
        }
        if (!mounted) return;
        final isLoggedIn = auth.status == AuthStatus.authenticated;
        context.go(isLoggedIn ? '/record' : '/login');
        return;
      }
      await _idle.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_intro, _idle]),
          builder: (context, _) {
            final scale = _logoScale.value * _pulse.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: _logoOpacity.value,
                  child: Transform.scale(
                    scale: scale,
                    child: SvgPicture.asset(
                      'assets/brand/logo.svg',
                      width: 140,
                      height: 140,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SlideTransition(
                  position: _titleSlide,
                  child: Opacity(
                    opacity: _titleOpacity.value,
                    child: const Text(
                      '当当日记',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Opacity(
                  opacity: _titleOpacity.value,
                  child: const Text(
                    '记录每一次陪伴',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
