import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dangdang_diary/services/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal in-process Dio adapter: dispatches every request to a caller
/// supplied closure and records the ordered list of [RequestOptions] for
/// assertions.
class _ProgrammableAdapter implements HttpClientAdapter {
  _ProgrammableAdapter(this.handle);
  Future<ResponseBody> Function(RequestOptions) handle;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handle(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ProgrammableAdapter mainAdapter;
  late _ProgrammableAdapter refreshAdapter;
  late HttpClientAdapter originalMain;
  late HttpClientAdapter originalRefresh;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'old_access',
      'refresh_token': 'refresh_abc',
    });
    final api = ApiClient();
    api.resetForTest();
    originalMain = api.dio.httpClientAdapter;
    originalRefresh = api.refreshDio.httpClientAdapter;
    mainAdapter = _ProgrammableAdapter((_) async => _json(404, {}));
    refreshAdapter = _ProgrammableAdapter((_) async => _json(404, {}));
    api.dio.httpClientAdapter = mainAdapter;
    api.refreshDio.httpClientAdapter = refreshAdapter;
  });

  tearDown(() {
    final api = ApiClient();
    api.dio.httpClientAdapter = originalMain;
    api.refreshDio.httpClientAdapter = originalRefresh;
    api.resetForTest();
  });

  test('3 concurrent 401 requests trigger refresh only once', () async {
    final refreshStarted = Completer<void>();
    final refreshGate = Completer<void>();
    var refreshCalls = 0;
    var targetCalls = 0;

    refreshAdapter.handle = (options) async {
      if (!options.path.endsWith('/auth/refresh')) return _json(404, {});
      refreshCalls++;
      if (!refreshStarted.isCompleted) refreshStarted.complete();
      // Hold the refresh open so all three in-flight 401s definitely queue up
      // against the same completer before a new access token is persisted.
      await refreshGate.future;
      return _json(200, {'access_token': 'new_access'});
    };

    mainAdapter.handle = (options) async {
      if (!options.path.endsWith('/pets')) return _json(404, {});
      targetCalls++;
      final auth = options.headers['Authorization'] as String?;
      if (auth == 'Bearer new_access') {
        return _json(200, {'ok': true, 'hit': targetCalls});
      }
      return _json(401, {'message': 'expired'});
    };

    final api = ApiClient();
    final futures = <Future<Response<dynamic>>>[
      api.dio.get<dynamic>('/pets'),
      api.dio.get<dynamic>('/pets'),
      api.dio.get<dynamic>('/pets'),
    ];

    // Wait until the refresh has been dispatched exactly once, then hold a
    // moment to verify no second refresh sneaks in.
    await refreshStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(refreshCalls, 1,
        reason: 'Only one refresh should be in flight across 3 concurrent 401s');

    refreshGate.complete();
    final results = await Future.wait(futures);

    expect(refreshCalls, 1);
    for (final r in results) {
      expect(r.statusCode, 200);
      expect(r.data, isA<Map>());
    }
    // 3 initial 401s + 3 retried 200s = 6 main-adapter hits.
    expect(targetCalls, 6);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('access_token'), 'new_access');
  });

  test('single-flight slot is released between refresh cycles', () async {
    var refreshCalls = 0;
    var currentToken = 'first';

    refreshAdapter.handle = (options) async {
      if (!options.path.endsWith('/auth/refresh')) return _json(404, {});
      refreshCalls++;
      currentToken = 'refreshed_$refreshCalls';
      return _json(200, {'access_token': currentToken});
    };

    mainAdapter.handle = (options) async {
      if (!options.path.endsWith('/pets')) return _json(404, {});
      final auth = options.headers['Authorization'] as String?;
      if (auth == 'Bearer $currentToken') {
        return _json(200, {'ok': true});
      }
      return _json(401, {'message': 'expired'});
    };

    final api = ApiClient();
    // Kick an initial 401 → refresh #1
    final r1 = await api.dio.get<dynamic>('/pets');
    expect(r1.statusCode, 200);
    expect(refreshCalls, 1);

    // Invalidate the token so the next call also triggers a refresh.
    currentToken = 'stale';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', 'stale_client');

    final r2 = await api.dio.get<dynamic>('/pets');
    expect(r2.statusCode, 200);
    expect(refreshCalls, 2,
        reason: 'A second independent 401 must be allowed to refresh again');
  });

  test('refresh failure triggers onForceLogout', () async {
    refreshAdapter.handle = (options) async {
      if (!options.path.endsWith('/auth/refresh')) return _json(404, {});
      return _json(401, {'message': 'refresh expired'});
    };

    mainAdapter.handle = (options) async {
      if (!options.path.endsWith('/pets')) return _json(404, {});
      return _json(401, {'message': 'expired'});
    };

    var forceLogoutCalls = 0;
    final api = ApiClient();
    api.onForceLogout = () async {
      forceLogoutCalls++;
    };

    await expectLater(api.dio.get<dynamic>('/pets'), throwsA(isA<DioException>()));
    expect(forceLogoutCalls, 1);
  });

  test('missing refresh token bypasses refresh and calls onForceLogout', () async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'some_access',
      // intentionally no refresh_token
    });

    var refreshCalls = 0;
    refreshAdapter.handle = (options) async {
      refreshCalls++;
      return _json(200, {'access_token': 'should_not_be_used'});
    };
    mainAdapter.handle = (options) async {
      if (!options.path.endsWith('/pets')) return _json(404, {});
      return _json(401, {'message': 'expired'});
    };

    var forceLogoutCalls = 0;
    final api = ApiClient();
    api.onForceLogout = () async {
      forceLogoutCalls++;
    };

    await expectLater(api.dio.get<dynamic>('/pets'), throwsA(isA<DioException>()));
    expect(refreshCalls, 0,
        reason: 'No refresh should be attempted without a refresh_token');
    expect(forceLogoutCalls, 1);
  });
}
