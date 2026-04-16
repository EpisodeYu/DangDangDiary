import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  late final Dio dio;

  VoidCallback? onForceLogout;

  ApiClient._internal() {
    dio = Dio(BaseOptions(
      baseUrl: '${AppConstants.baseUrl}${AppConstants.apiPrefix}',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
      headers: {'Content-Type': 'application/json'},
    ));

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
          onForceLogout?.call();
          handler.next(error);
          return;
        }

        try {
          final refreshDio = Dio(BaseOptions(
            baseUrl: '${AppConstants.baseUrl}${AppConstants.apiPrefix}',
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ));
          final resp = await refreshDio.post(
            '/auth/refresh',
            data: {'refresh_token': refreshToken},
          );
          final newToken = resp.data['access_token'] as String;
          await prefs.setString('access_token', newToken);

          final opts = error.requestOptions;
          opts.headers['Authorization'] = 'Bearer $newToken';
          opts.extra['_retried'] = true;

          final retryResp = await dio.fetch(opts);
          handler.resolve(retryResp);
        } catch (_) {
          await prefs.remove('access_token');
          await prefs.remove('refresh_token');
          onForceLogout?.call();
          handler.next(error);
        }
      },
    ));
  }
}

class _RetryInterceptor extends Interceptor {
  final Dio _dio;
  static const _maxRetries = 2;
  static const _extraKey = '_retryCount';

  _RetryInterceptor(this._dio);

  bool _shouldRetry(DioException err) {
    if (err.requestOptions.extra['_retried'] == true) return false;

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
