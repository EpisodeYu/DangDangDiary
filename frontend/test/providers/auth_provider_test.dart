import 'dart:async';

import 'package:dangdang_diary/models/user.dart';
import 'package:dangdang_diary/providers/auth_provider.dart';
import 'package:dangdang_diary/services/api_client.dart';
import 'package:dangdang_diary/services/auth_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake [AuthService] that avoids any real HTTP by overriding every public
/// method. Because [AuthService.new] only reaches [ApiClient()] as a side
/// effect of field init, the singleton is never actually exercised.
class _FakeAuthService extends AuthService {
  _FakeAuthService();

  User userToReturn = const User(id: 1, phone: '13800000000', nickname: 'zoe');

  /// Number of times getMe() should fail before succeeding.
  int getMeFailCount = 0;
  bool failRefresh = false;
  bool failLogin = false;
  String? loginErrorMessage;
  bool failLogout = false;
  bool persistTokensOnLogin = true;

  int sendCodeCalls = 0;
  int loginCalls = 0;
  int getMeCalls = 0;
  int refreshCalls = 0;
  int logoutCalls = 0;
  int updateMeCalls = 0;

  @override
  Future<void> sendCode(String phone) async {
    sendCodeCalls++;
  }

  @override
  Future<({String accessToken, String refreshToken, User user})> login(
    String phone,
    String code,
  ) async {
    loginCalls++;
    if (failLogin) {
      final req = RequestOptions(path: '/auth/login');
      throw DioException(
        requestOptions: req,
        response: Response<dynamic>(
          requestOptions: req,
          statusCode: 400,
          data: {'message': loginErrorMessage ?? 'bad code'},
        ),
      );
    }
    if (persistTokensOnLogin) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('access_token', 'fake_access');
      await prefs.setString('refresh_token', 'fake_refresh');
    }
    return (
      accessToken: 'fake_access',
      refreshToken: 'fake_refresh',
      user: userToReturn,
    );
  }

  @override
  Future<User> getMe() async {
    getMeCalls++;
    if (getMeCalls <= getMeFailCount) throw Exception('getMe failed');
    return userToReturn;
  }

  @override
  Future<String> refreshToken() async {
    refreshCalls++;
    if (failRefresh) throw Exception('refresh failed');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', 'refreshed_access');
    return 'refreshed_access';
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    if (failLogout) throw Exception('logout failed');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
  }

  @override
  Future<User> updateMe({required String nickname}) async {
    updateMeCalls++;
    userToReturn = User(
      id: userToReturn.id,
      phone: userToReturn.phone,
      nickname: nickname,
      avatarUrl: userToReturn.avatarUrl,
    );
    return userToReturn;
  }
}

AuthNotifier _makeNotifier({
  required _FakeAuthService service,
  Future<void> Function()? clearPhotoCache,
}) {
  return AuthNotifier(
    authService: service,
    apiClient: ApiClient(),
    clearPhotoCache: clearPhotoCache ?? (() async {}),
    autoCheck: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Every test gets an isolated SharedPreferences view; individual tests
    // may call `setMockInitialValues` again to preload tokens.
    SharedPreferences.setMockInitialValues({});
    ApiClient().resetForTest();
  });

  tearDown(() {
    ApiClient().resetForTest();
  });

  group('_checkAuthStatus', () {
    test('no tokens → unauthenticated, getMe not called', () async {
      final svc = _FakeAuthService();
      final notifier = _makeNotifier(service: svc);
      await notifier.checkAuthStatusForTest();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      expect(svc.getMeCalls, 0);
      expect(svc.refreshCalls, 0);
    });

    test('has tokens + getMe success → authenticated', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'a',
        'refresh_token': 'r',
      });
      final svc = _FakeAuthService()
        ..userToReturn = const User(id: 42, phone: '13800000042');
      final notifier = _makeNotifier(service: svc);
      await notifier.checkAuthStatusForTest();
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 42);
      expect(svc.getMeCalls, 1);
      expect(svc.refreshCalls, 0);
    });

    test('getMe fails + refresh success → authenticated (re-tries getMe)',
        () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'a',
        'refresh_token': 'r',
      });
      final svc = _FakeAuthService()..getMeFailCount = 1;
      final notifier = _makeNotifier(service: svc);
      await notifier.checkAuthStatusForTest();
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(svc.getMeCalls, 2);
      expect(svc.refreshCalls, 1);
    });

    test('getMe fails + refresh fails → unauthenticated and prefs cleared',
        () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'a',
        'refresh_token': 'r',
      });
      final svc = _FakeAuthService()
        ..getMeFailCount = 99
        ..failRefresh = true;
      final notifier = _makeNotifier(service: svc);
      await notifier.checkAuthStatusForTest();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });
  });

  group('login', () {
    test('success → authenticated + state.user set + no error', () async {
      final svc = _FakeAuthService()
        ..userToReturn = const User(id: 7, phone: '13812345678');
      final notifier = _makeNotifier(service: svc);
      final ok = await notifier.login('13812345678', '1234');
      expect(ok, isTrue);
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 7);
      expect(notifier.state.error, isNull);
      expect(notifier.state.isLoading, isFalse);
    });

    test('failure → state.error set from DioException body', () async {
      final svc = _FakeAuthService()
        ..failLogin = true
        ..loginErrorMessage = '验证码错误';
      final notifier = _makeNotifier(service: svc);
      final ok = await notifier.login('13812345678', 'bad');
      expect(ok, isFalse);
      expect(notifier.state.status, isNot(AuthStatus.authenticated));
      expect(notifier.state.error, '验证码错误');
      expect(notifier.state.isLoading, isFalse);
    });
  });

  group('handleForceLogout', () {
    test('clears photo cache BEFORE wiping tokens and flipping state',
        () async {
      SharedPreferences.setMockInitialValues({});
      final order = <String>[];
      final gate = Completer<void>();

      final svc = _FakeAuthService();
      final notifier = _makeNotifier(
        service: svc,
        clearPhotoCache: () async {
          order.add('clear_cache_start');
          await gate.future;
          order.add('clear_cache_done');
        },
      );

      // Put the notifier into an authenticated state so the handler actually
      // runs (the `state.status == unauthenticated` early-out would otherwise
      // skip everything).
      final ok = await notifier.login('13812345678', '1234');
      expect(ok, isTrue);
      expect(notifier.state.status, AuthStatus.authenticated);

      final prefsBefore = await SharedPreferences.getInstance();
      expect(prefsBefore.getString('access_token'), 'fake_access');

      notifier.addListener(
        (s) {
          if (s.status == AuthStatus.unauthenticated) {
            order.add('state_unauthenticated');
          }
        },
        fireImmediately: false,
      );

      final future = notifier.handleForceLogout();
      // Yield so clear_cache_start fires, but the gate blocks completion.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(order, ['clear_cache_start']);
      expect(notifier.state.status, AuthStatus.authenticated,
          reason: 'state must not flip before cache is cleared');
      expect(prefsBefore.getString('access_token'), 'fake_access',
          reason: 'tokens must not be wiped before cache is cleared');

      gate.complete();
      await future;

      expect(order, ['clear_cache_start', 'clear_cache_done', 'state_unauthenticated']);
      final prefsAfter = await SharedPreferences.getInstance();
      expect(prefsAfter.getString('access_token'), isNull);
      expect(prefsAfter.getString('refresh_token'), isNull);
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });

    test('is a no-op when already unauthenticated', () async {
      var clearCalls = 0;
      final svc = _FakeAuthService();
      final notifier = _makeNotifier(
        service: svc,
        clearPhotoCache: () async {
          clearCalls++;
        },
      );
      // Default initial state is `unknown`; explicitly drive to unauthenticated.
      await notifier.checkAuthStatusForTest();
      expect(notifier.state.status, AuthStatus.unauthenticated);

      await notifier.handleForceLogout();
      expect(clearCalls, 0,
          reason: 'No cache clear when we are already unauthenticated');
    });

    test('wires itself into ApiClient.onForceLogout on construction',
        () async {
      final svc = _FakeAuthService();
      final notifier = _makeNotifier(service: svc);
      // Authenticate so the handler does real work.
      await notifier.login('13812345678', '1234');
      expect(ApiClient().onForceLogout, isNotNull);
      await ApiClient().onForceLogout!();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });
  });

  group('logout', () {
    test('clears photo cache and flips state to unauthenticated', () async {
      var clearCalls = 0;
      final svc = _FakeAuthService();
      final notifier = _makeNotifier(
        service: svc,
        clearPhotoCache: () async {
          clearCalls++;
        },
      );
      await notifier.login('13812345678', '1234');
      expect(notifier.state.status, AuthStatus.authenticated);

      await notifier.logout();

      expect(svc.logoutCalls, 1);
      expect(clearCalls, 1);
      expect(notifier.state.status, AuthStatus.unauthenticated);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('swallows AuthService.logout() errors but still clears state',
        () async {
      var clearCalls = 0;
      final svc = _FakeAuthService()..failLogout = true;
      final notifier = _makeNotifier(
        service: svc,
        clearPhotoCache: () async {
          clearCalls++;
        },
      );
      await notifier.login('13812345678', '1234');
      await notifier.logout();
      expect(clearCalls, 1);
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });
  });
}
