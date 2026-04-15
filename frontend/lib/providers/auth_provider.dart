import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

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
  AuthNotifier() : super(const AuthState()) {
    ApiClient().onForceLogout = _onForceLogout;
    _checkAuthStatus();
  }

  final _authService = AuthService();

  void _onForceLogout() {
    if (state.status != AuthStatus.unauthenticated) {
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

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
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _authService.sendCode(phone);
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _extractError(e));
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

  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    try {
      await _authService.logout();
    } catch (_) {}
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
