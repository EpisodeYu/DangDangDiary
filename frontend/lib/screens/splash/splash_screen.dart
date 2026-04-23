import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/doodle_background.dart';

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
  late final Animation<double> _highlightWidth;
  late final Animation<double> _idleWobble;

  bool _routed = false;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    // Logo stamps in
    _logoScale = Tween<double>(begin: 1.5, end: 1.0).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0, 0.4, curve: Curves.elasticOut)),
    );
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0, 0.2, curve: Curves.easeIn)),
    );

    // Title slides up
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0.4, 0.7, curve: Curves.easeOutCubic)),
    );
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0.4, 0.7, curve: Curves.easeIn)),
    );

    // Highlight expands from left to right
    _highlightWidth = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0.6, 1.0, curve: Curves.easeOutQuart)),
    );

    // Idle wobble (like a bookmark swinging)
    _idleWobble = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.05).chain(CurveTween(curve: Curves.easeInOut)), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.05, end: -0.05).chain(CurveTween(curve: Curves.easeInOut)), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -0.05, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 1),
    ]).animate(_idle);

    _startFlow();
  }

  // Minimum total time the splash stays on screen from cold start. Auth
  // resolution (`_checkAuthStatus` in [AuthNotifier]) happens concurrently
  // while the user watches the animation, so this also acts as a "don't
  // route until the home screen is ready to paint stably" window. Fixes
  // the flash where /record would mount and then immediately redirect to
  // /login because auth finished resolving a few hundred ms too late.
  static const Duration _minimumVisible = Duration(milliseconds: 3000);

  Future<void> _startFlow() async {
    final splashStartedAt = DateTime.now();
    await _intro.forward();
    _idle.repeat();

    // Wait until BOTH conditions are satisfied before routing:
    //   1. The minimum 3-second splash window has elapsed.
    //   2. Auth status is no longer `unknown` (i.e. _checkAuthStatus has
    //      either confirmed the session or decided we need /login).
    while (mounted && !_routed) {
      final elapsed = DateTime.now().difference(splashStartedAt);
      final remaining = _minimumVisible - elapsed;
      final auth = ref.read(authProvider);
      final authReady = auth.status != AuthStatus.unknown;

      if (authReady && remaining <= Duration.zero) {
        _routed = true;
        if (!mounted) return;
        final isLoggedIn = auth.status == AuthStatus.authenticated;
        context.go(isLoggedIn ? '/record' : '/login');
        return;
      }

      // Sleep just long enough to reach whichever gate is still closed,
      // clamped to 100ms so we keep polling auth in case it resolves
      // slightly after the minimum window.
      final wait = remaining > Duration.zero
          ? (remaining < const Duration(milliseconds: 100)
              ? remaining
              : const Duration(milliseconds: 100))
          : const Duration(milliseconds: 100);
      await Future.delayed(wait);
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
      body: DoodleBackground(
        child: Center(
          child: AnimatedBuilder(
            animation: Listenable.merge([_intro, _idle]),
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: _idleWobble.value,
                    child: Opacity(
                      opacity: _logoOpacity.value,
                      child: Transform.scale(
                        scale: _logoScale.value,
                        child: SvgPicture.asset(
                          'assets/brand/logo.svg',
                          width: 140,
                          height: 140,
                          colorFilter: const ColorFilter.mode(AppTheme.primaryColor, BlendMode.srcIn),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SlideTransition(
                    position: _titleSlide,
                    child: Opacity(
                      opacity: _titleOpacity.value,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Highlight marker
                          Positioned(
                            bottom: 2,
                            left: -4,
                            right: -4,
                            height: 12,
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: _highlightWidth.value,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppTheme.accentYellow,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                            ),
                          ),
                          // Title text
                          const Text(
                            '当当日记',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.textPrimary,
                              letterSpacing: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: _titleOpacity.value,
                    child: const Text(
                      '记录每一次陪伴',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
