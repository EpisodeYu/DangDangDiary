// ignore_for_file: depend_on_referenced_packages
import 'package:dangdang_diary/models/user.dart';
import 'package:dangdang_diary/providers/auth_provider.dart';
import 'package:dangdang_diary/screens/splash/splash_screen.dart';
import 'package:dangdang_diary/services/api_client.dart';
import 'package:dangdang_diary/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal fake [AuthService]: Splash only reads the provider state, so none
/// of these are invoked — they only exist because [AuthNotifier] instantiates
/// one as a private field.
class _FakeAuthService extends AuthService {
  _FakeAuthService();
  @override
  Future<User> getMe() async =>
      const User(id: 1, phone: '13800000000');
  @override
  Future<String> refreshToken() async => 'refresh';
}

/// Forces a specific [AuthStatus] without running the disk / network probe.
class _StubAuthNotifier extends AuthNotifier {
  _StubAuthNotifier(AuthStatus status)
      : super(
          authService: _FakeAuthService(),
          apiClient: ApiClient(),
          clearPhotoCache: () async {},
          autoCheck: false,
        ) {
    state = AuthState(status: status);
  }
}

Widget _harness({
  required _StubAuthNotifier auth,
  required GlobalKey<NavigatorState> navKey,
  required ValueChanged<String> onRoute,
}) {
  final router = GoRouter(
    navigatorKey: navKey,
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (_, s) => const SplashScreen()),
      GoRoute(
        path: '/record',
        builder: (_, s) {
          onRoute('/record');
          return const Scaffold(body: Text('RECORD'));
        },
      ),
      GoRoute(
        path: '/login',
        builder: (_, s) {
          onRoute('/login');
          return const Scaffold(body: Text('LOGIN'));
        },
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      authProvider.overrideWith((ref) => auth),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient().resetForTest();
  });

  tearDown(() {
    ApiClient().resetForTest();
  });

  testWidgets('Splash intro: logo fades in, title hidden before t=400ms',
      (tester) async {
    final auth = _StubAuthNotifier(AuthStatus.unknown);
    await tester.pumpWidget(_harness(
      auth: auth,
      navKey: GlobalKey<NavigatorState>(),
      onRoute: (_) {},
    ));

    // Let the first build commit but stop before the title interval starts.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final opacities =
        tester.widgetList<Opacity>(find.byType(Opacity)).toList();
    expect(opacities.length, greaterThanOrEqualTo(3));
    final logoOpacity = opacities[0].opacity;
    final titleOpacity = opacities[1].opacity;
    expect(logoOpacity, greaterThan(0.0));
    expect(logoOpacity, lessThanOrEqualTo(1.0));
    // Title interval is [0.44, 1.0] of _intro (900ms); at 200ms it's still 0.
    expect(titleOpacity, 0);

    // Let the rest of the animation / idle loop settle so no timers leak.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 2400));
  });

  testWidgets('Splash intro: after 1000ms logo and title are fully visible',
      (tester) async {
    final auth = _StubAuthNotifier(AuthStatus.unknown);
    await tester.pumpWidget(_harness(
      auth: auth,
      navKey: GlobalKey<NavigatorState>(),
      onRoute: (_) {},
    ));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    final opacities =
        tester.widgetList<Opacity>(find.byType(Opacity)).toList();
    expect(opacities[0].opacity, closeTo(1.0, 0.001));
    expect(opacities[1].opacity, closeTo(1.0, 0.001));

    await tester.pump(const Duration(milliseconds: 2400));
  });

  testWidgets('Auth=authenticated → navigates to /record after splash',
      (tester) async {
    final auth = _StubAuthNotifier(AuthStatus.authenticated);
    final routed = <String>[];
    await tester.pumpWidget(_harness(
      auth: auth,
      navKey: GlobalKey<NavigatorState>(),
      onRoute: routed.add,
    ));

    // Walk through intro (900ms) + min show (600ms) + one idle cycle (2400ms).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pumpAndSettle();

    expect(routed, contains('/record'));
  });

  testWidgets('Auth=unauthenticated → navigates to /login after splash',
      (tester) async {
    final auth = _StubAuthNotifier(AuthStatus.unauthenticated);
    final routed = <String>[];
    await tester.pumpWidget(_harness(
      auth: auth,
      navKey: GlobalKey<NavigatorState>(),
      onRoute: routed.add,
    ));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pumpAndSettle();

    expect(routed, contains('/login'));
  });

  testWidgets('Auth=unknown → stays on splash, never routes', (tester) async {
    final auth = _StubAuthNotifier(AuthStatus.unknown);
    final routed = <String>[];
    await tester.pumpWidget(_harness(
      auth: auth,
      navKey: GlobalKey<NavigatorState>(),
      onRoute: routed.add,
    ));

    // Walk through ~5 seconds of animation time without auth ever resolving.
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(routed, isEmpty);
    expect(find.byType(SplashScreen), findsOneWidget);
  });
}
