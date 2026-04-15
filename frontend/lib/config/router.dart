import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/auth/login_screen.dart';
import '../screens/record/record_screen.dart';
import '../screens/health/health_screen.dart';
import '../screens/timeline/timeline_screen.dart';
import '../screens/ai/ai_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../widgets/main_scaffold.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Listenable that triggers GoRouter redirect re-evaluation
/// whenever the auth state changes.
class _AuthRedirectNotifier extends ChangeNotifier {
  _AuthRedirectNotifier(Ref ref) {
    ref.listen<AuthState>(authProvider, (prev, next) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _AuthRedirectNotifier(ref);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/record',
    refreshListenable: notifier,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final isLoggedIn = auth.status == AuthStatus.authenticated;
      final isLoading = auth.status == AuthStatus.unknown;
      final onLogin = state.matchedLocation == '/login';

      if (isLoading) return null;
      if (!isLoggedIn && !onLogin) return '/login';
      if (isLoggedIn && onLogin) return '/record';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainScaffold(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/record',
              builder: (context, state) => const RecordScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/health',
              builder: (context, state) => const HealthScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/timeline',
              builder: (context, state) => const TimelineScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/ai',
              builder: (context, state) => const AiScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ]),
        ],
      ),
    ],
  );
});
