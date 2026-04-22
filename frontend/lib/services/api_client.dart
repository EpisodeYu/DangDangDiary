import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

/// Signature for the force-logout hook invoked by [ApiClient] when token
/// refresh is impossible (missing refresh token, refresh endpoint rejection,
/// etc.). The handler is responsible for clearing the photo cache, wiping
/// persisted tokens, and flipping the UI to the login screen, in that order.
typedef ForceLogoutHandler = Future<void> Function();

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  late final Dio dio;

  /// Dedicated Dio for the refresh endpoint so it does not re-enter the main
  /// Dio's 401 interceptor on failure. Exposed for tests so they can install
  /// a mock adapter.
  late Dio _refreshDio;

  /// Shared in-flight refresh. When multiple requests see 401 concurrently,
  /// they all await the same [Completer] instead of firing N parallel refresh
  /// calls against `/auth/refresh`.
  Completer<String>? _refreshInflight;

  ForceLogoutHandler? onForceLogout;

  ApiClient._internal() {
    dio = Dio(BaseOptions(
      baseUrl: '${AppConstants.baseUrl}${AppConstants.apiPrefix}',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
      headers: {'Content-Type': 'application/json'},
    ));
    _refreshDio = _buildRefreshDio();

    dio.interceptors.add(_RetryInterceptor(dio));

    if (kDebugMode) {
      dio.interceptors.add(LogInterceptor(
        requestHeader: false,
        responseHeader: false,
        requestBody: true,
        responseBody: true,
        logPrint: (o) => debugPrint('[API] $o'),
      ));
    }

    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('access_token');
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        // [DEBUG-2026-04-22] dump the fully-merged request descriptor for
        // classify so we can verify Content-Type / Content-Length / timeouts
        // actually reach the wire the way we expect. Remove once root cause
        // is confirmed.
        if (options.path.contains('/photos/classify')) {
          final hdrDump = options.headers.entries
              .map((e) => '${e.key}=${e.value}')
              .join(' | ');
          debugPrint(
            '[ClassifyDbg] onRequest path=${options.path}'
            ' connectT=${options.connectTimeout}'
            ' sendT=${options.sendTimeout}'
            ' receiveT=${options.receiveTimeout}'
            ' persistent=${options.persistentConnection}'
            ' contentType=${options.contentType}'
            ' dataType=${options.data.runtimeType}'
            '\n  headers: $hdrDump',
          );
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode != 401) {
          handler.next(error);
          return;
        }

        final path = error.requestOptions.path;
        if (path.contains('/auth/refresh') || path.contains('/auth/login')) {
          handler.next(error);
          return;
        }

        if (error.requestOptions.extra['_retried'] == true) {
          handler.next(error);
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        final refreshToken = prefs.getString('refresh_token');
        if (refreshToken == null) {
          await _triggerForceLogout();
          handler.next(error);
          return;
        }

        final Future<String> refreshFuture;
        final existing = _refreshInflight;
        if (existing != null) {
          refreshFuture = existing.future;
        } else {
          final completer = Completer<String>();
          _refreshInflight = completer;
          refreshFuture = completer.future;
          _performRefresh(refreshToken).then((token) {
            if (!completer.isCompleted) completer.complete(token);
          }).catchError((Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          }).whenComplete(() {
            if (identical(_refreshInflight, completer)) {
              _refreshInflight = null;
            }
          });
        }

        String newToken;
        try {
          newToken = await refreshFuture;
        } catch (_) {
          await _triggerForceLogout();
          handler.next(error);
          return;
        }

        try {
          final opts = error.requestOptions;
          opts.headers['Authorization'] = 'Bearer $newToken';
          opts.extra['_retried'] = true;
          final retryResp = await dio.fetch(opts);
          handler.resolve(retryResp);
        } catch (e) {
          handler.next(e is DioException ? e : error);
        }
      },
    ));
  }

  Dio _buildRefreshDio() {
    return Dio(BaseOptions(
      baseUrl: '${AppConstants.baseUrl}${AppConstants.apiPrefix}',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));
  }

  Future<String> _performRefresh(String refreshToken) async {
    final resp = await _refreshDio.post(
      '/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    final newToken = resp.data['access_token'] as String;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', newToken);
    return newToken;
  }

  Future<void> _triggerForceLogout() async {
    final handler = onForceLogout;
    if (handler == null) return;
    try {
      await handler();
    } catch (e, st) {
      debugPrint('[API] onForceLogout handler threw: $e\n$st');
    }
  }

  /// Drop any TCP connections currently pooled inside the main [dio]'s
  /// [IOHttpClientAdapter] so the next request opens a brand-new
  /// socket.
  ///
  /// Observed 2026-04-22: after the app is paused (e.g. the image
  /// picker takes the foreground) and resumed, the carrier's NAT has
  /// silently dropped the 4-tuple for every keep-alive connection
  /// parked in dart:io's pool, but dart:io still hands them out on the
  /// next `openUrl`. The first request using that stale socket writes
  /// into a black hole and eventually surfaces as a `receiveTimeout`
  /// after the full [BaseOptions.receiveTimeout]. This method is the
  /// lifecycle-level hedge: call it from `didChangeAppLifecycleState`
  /// on resumed so every endpoint — not just `/photos/classify` —
  /// gets a clean pool.
  void resetConnectionPool() {
    final old = dio.httpClientAdapter;
    dio.httpClientAdapter = IOHttpClientAdapter();
    try {
      old.close(force: true);
    } catch (_) {}
  }

  /// For tests only. Resets mutable state that leaks across tests when the
  /// singleton is reused (in-flight refresh future + hook). Does not touch
  /// installed adapters; callers that swap [dio.httpClientAdapter] or
  /// [refreshDio.httpClientAdapter] are responsible for restoring them.
  @visibleForTesting
  void resetForTest() {
    _refreshInflight = null;
    onForceLogout = null;
  }

  /// For tests only. Exposes the refresh-dedicated Dio so tests can install a
  /// mock adapter against the `/auth/refresh` endpoint without reaching the
  /// network.
  @visibleForTesting
  Dio get refreshDio => _refreshDio;

  @visibleForTesting
  set refreshDio(Dio value) {
    _refreshDio = value;
  }
}

class _RetryInterceptor extends Interceptor {
  final Dio _dio;
  static const _maxRetries = 2;
  static const _extraKey = '_retryCount';

  _RetryInterceptor(this._dio);

  bool _shouldRetry(DioException err) {
    if (err.requestOptions.extra['_retried'] == true) return false;

    // FormData bodies are one-shot streams — replaying opts.data throws
    // "FormData has already been finalized". Upload endpoints (e.g.
    // POST /pets/{id}/photos) are also non-idempotent, so a blind retry
    // risks duplicates if the first attempt actually reached the server.
    // The caller handles user-facing retry instead.
    if (err.requestOptions.data is FormData) return false;

    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      default:
        return false;
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final retryCount = (err.requestOptions.extra[_extraKey] as int?) ?? 0;

    if (!_shouldRetry(err) || retryCount >= _maxRetries) {
      handler.next(err);
      return;
    }

    final delay = Duration(milliseconds: 500 * pow(2, retryCount).toInt());
    await Future.delayed(delay);

    final opts = err.requestOptions;
    opts.extra[_extraKey] = retryCount + 1;

    try {
      debugPrint('[API] Retry ${retryCount + 1}/$_maxRetries: ${opts.method} ${opts.path}');
      final resp = await _dio.fetch(opts);
      handler.resolve(resp);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
