import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/health.dart';
import '../providers/auth_provider.dart';
import '../screens/auth/login_screen.dart';
import '../screens/record/record_screen.dart';
import '../screens/health/health_screen.dart';
import '../screens/health/weight_record_screen.dart';
import '../screens/health/deworming_record_screen.dart';
import '../screens/health/deworming_cycle_screen.dart';
import '../screens/health/vaccination_record_screen.dart';
import '../screens/timeline/timeline_screen.dart';
import '../screens/ai/ai_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/profile/pet_manage_screen.dart';
import '../screens/profile/pet_edit_screen.dart';
import '../widgets/main_scaffold.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

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

      if (isLoading) return onLogin ? null : '/login';
      if (!isLoggedIn && !onLogin) return '/login';
      if (isLoggedIn && onLogin) return '/record';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/profile/pets',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const PetManageScreen(),
      ),
      GoRoute(
        path: '/profile/pets/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const PetEditScreen(),
      ),
      GoRoute(
        path: '/profile/pets/:petId/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final petId = int.parse(state.pathParameters['petId']!);
          return PetEditScreen(petId: petId);
        },
      ),

      // ---------------- Health sub-pages ----------------
      GoRoute(
        path: '/health/weight/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final petId = int.parse(state.uri.queryParameters['petId']!);
          return WeightRecordScreen(petId: petId);
        },
      ),
      GoRoute(
        path: '/health/weight/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final qp = state.uri.queryParameters;
          return WeightRecordScreen(
            petId: int.parse(qp['petId']!),
            weightId: int.tryParse(qp['weightId'] ?? ''),
            initialWeight: double.tryParse(qp['weight'] ?? ''),
            initialDate: qp['date'],
          );
        },
      ),
      GoRoute(
        path: '/health/deworming/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final petId = int.parse(state.uri.queryParameters['petId']!);
          return DewormingRecordScreen(petId: petId);
        },
      ),
      GoRoute(
        path: '/health/deworming/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final qp = state.uri.queryParameters;
          DewormingTypeE? type;
          if (qp['type'] != null) {
            try {
              type = DewormingTypeX.fromString(qp['type']!);
            } catch (_) {}
          }
          return DewormingRecordScreen(
            petId: int.parse(qp['petId']!),
            dewormingId: int.tryParse(qp['dewormingId'] ?? ''),
            initialType: type,
            initialDate: qp['date'],
          );
        },
      ),
      GoRoute(
        path: '/health/deworming/cycle',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final petId = int.parse(state.uri.queryParameters['petId']!);
          return DewormingCycleScreen(petId: petId);
        },
      ),
      GoRoute(
        path: '/health/vaccination/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final petId = int.parse(state.uri.queryParameters['petId']!);
          return VaccinationRecordScreen(petId: petId);
        },
      ),
      GoRoute(
        path: '/health/vaccination/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final qp = state.uri.queryParameters;
          return VaccinationRecordScreen(
            petId: int.parse(qp['petId']!),
            vaccinationId: int.tryParse(qp['vaccinationId'] ?? ''),
            initialType: qp['type'],
            initialDate: qp['date'],
          );
        },
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
