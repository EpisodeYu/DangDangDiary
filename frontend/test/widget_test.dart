import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dangdang_diary/app.dart';
import 'package:dangdang_diary/config/router.dart';
import 'package:dangdang_diary/providers/auth_provider.dart';
import 'package:dangdang_diary/widgets/main_scaffold.dart';

/// Minimal router used in tests to bypass the production auth-guarded
/// redirect. It renders [MainScaffold] with placeholder screens so the test
/// can focus on verifying bottom-navigation wiring only.
GoRouter _buildTestRouter() {
  return GoRouter(
    initialLocation: '/record',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) =>
            MainScaffold(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/record', builder: (_, __) => const Placeholder()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/health', builder: (_, __) => const Placeholder()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/timeline', builder: (_, __) => const Placeholder()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/ai', builder: (_, __) => const Placeholder()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/profile', builder: (_, __) => const Placeholder()),
          ]),
        ],
      ),
    ],
  );
}

void main() {
  setUp(() {
    // Guarantees any incidental SharedPreferences call returns synchronously.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App renders with bottom navigation', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWith((ref) => _buildTestRouter()),
          // Keep auth in AuthStatus.unknown so _AppLifecycleHost never fires
          // the lifecycle side-effects (notification scheduling / cancel)
          // that require a real FlutterLocalNotifications plugin.
          authProvider.overrideWith((ref) => AuthNotifier(autoCheck: false)),
        ],
        child: const DangDangDiaryApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('记录'), findsOneWidget);
    expect(find.text('健康'), findsOneWidget);
    expect(find.text('时间轴'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });
}
