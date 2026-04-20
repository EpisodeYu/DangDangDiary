import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/original_photo_cache.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

@immutable
class AuthState {
  final AuthStatus status;
  final User? user;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    bool? isLoading,
    String? error,
    bool clearUser = false,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: clearUser ? null : (user ?? this.user),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  /// @param authService   Injectable auth service (tests pass a fake).
  /// @param apiClient     Injectable api client so `onForceLogout` can be
  ///                      wired to a non-singleton in tests.
  /// @param clearPhotoCache  Hook invoked before the persisted tokens get
  ///                      wiped. Defaults to `OriginalPhotoCache.clearAllForLogout`.
  /// @param autoCheck     If `true` (production default), the notifier kicks
  ///                      off `_checkAuthStatus()` on construction. Tests
  ///                      pass `false` so they can drive the flow manually.
  AuthNotifier({
    AuthService? authService,
    ApiClient? apiClient,
    Future<void> Function()? clearPhotoCache,
    bool autoCheck = true,
  })  : _authService = authService ?? AuthService(),
        _clearPhotoCache = clearPhotoCache ??
            (() => OriginalPhotoCache.instance.clearAllForLogout()),
        super(const AuthState()) {
    (apiClient ?? ApiClient()).onForceLogout = handleForceLogout;
    if (autoCheck) _checkAuthStatus();
  }

  final AuthService _authService;
  final Future<void> Function() _clearPhotoCache;

  /// Exposed for the ApiClient hook and for tests to invoke directly.
  /// Ordering (matches §1.1 第 12 条):
  ///   1. clear on-disk original photo cache (privacy),
  ///   2. wipe persisted tokens,
  ///   3. flip state → unauthenticated (triggers UI → login screen).
  @visibleForTesting
  Future<void> handleForceLogout() async {
    if (state.status == AuthStatus.unauthenticated) return;
    await _clearPhotoCache();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  @visibleForTesting
  Future<void> checkAuthStatusForTest() => _checkAuthStatus();

  Future<void> _checkAuthStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString('access_token');
    final refreshToken = prefs.getString('refresh_token');

    if (accessToken == null || refreshToken == null) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }

    try {
      final user = await _authService.getMe();
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } catch (_) {
      try {
        await _authService.refreshToken();
        final user = await _authService.getMe();
        state = AuthState(status: AuthStatus.authenticated, user: user);
      } catch (_) {
        await prefs.remove('access_token');
        await prefs.remove('refresh_token');
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    }
  }

  Future<void> sendCode(String phone) async {
    state = state.copyWith(clearError: true);
    try {
      await _authService.sendCode(phone);
    } catch (e) {
      state = state.copyWith(error: _extractError(e));
    }
  }

  Future<bool> login(String phone, String code) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final result = await _authService.login(phone, code);
      state = AuthState(status: AuthStatus.authenticated, user: result.user);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _extractError(e));
      return false;
    }
  }

  Future<bool> updateNickname(String nickname) async {
    try {
      final user = await _authService.updateMe(nickname: nickname);
      state = state.copyWith(user: user);
      return true;
    } catch (e) {
      state = state.copyWith(error: _extractError(e));
      return false;
    }
  }

  Future<bool> uploadAvatar(
    Uint8List bytes,
    String filename, {
    ProgressCallback? onSendProgress,
  }) async {
    try {
      final user = await _authService.uploadAvatar(
        bytes,
        filename,
        onSendProgress: onSendProgress,
      );
      state = state.copyWith(user: user);
      return true;
    } catch (e) {
      state = state.copyWith(error: _extractError(e));
      return false;
    }
  }

  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    try {
      await _authService.logout();
    } catch (_) {}
    // Same ordering contract as handleForceLogout: clear cache first, then
    // tokens (AuthService.logout already removes them, but we remove defensively
    // in case a future refactor changes that), then flip state.
    await _clearPhotoCache();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  String _extractError(dynamic e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        return (data['message'] as String?) ?? '请求失败';
      }
    }
    return '网络错误，请稍后重试';
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
