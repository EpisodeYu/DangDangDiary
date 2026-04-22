import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

/// Per-file classify outcome. `petId == null` covers every soft-fail
/// case (no candidate pool, low confidence, upstream outage) — the UI
/// treats all of them identically.
class ClassifyResult {
  final int fileIndex;
  final int? petId;
  final double? confidence;

  const ClassifyResult({
    required this.fileIndex,
    this.petId,
    this.confidence,
  });

  factory ClassifyResult.fromJson(Map<String, dynamic> j) => ClassifyResult(
        fileIndex: j['file_index'] as int,
        petId: j['pet_id'] as int?,
        confidence: (j['confidence'] as num?)?.toDouble(),
      );
}

/// Wrapper for ``POST /api/v1/photos/classify``.
///
/// **Why this service does NOT share [ApiClient.dio]:**
/// Observed 2026-04-22 on a phone over China Unicom 4G — after the app
/// was paused while the image picker opened, the next classify POST
/// timed out at 60s even though the body uploaded fine and every other
/// concurrent GET on the same host returned in <20ms. Nginx never saw
/// the request: the phone had picked a keep-alive connection out of
/// dart:io's shared [HttpClient] pool whose NAT mapping had silently
/// expired during the pause, so every packet went into a black hole
/// with no RST from the carrier.
///
/// Fix: classify gets its own [Dio] + [IOHttpClientAdapter] whose
/// [HttpClient] is configured to **never reuse a socket** (effectively
/// zero idle timeout + every request sent with `Connection: close`).
/// Each classify call therefore opens a brand-new TCP connection, which
/// always triggers a fresh NAT mapping. We also retry once on timeout /
/// connection error since the endpoint is idempotent (read-only, no
/// server-side state change) and the retry will always be on an even
/// newer connection.
class ClassifyService {
  ClassifyService() : _dio = _buildDio();

  final Dio _dio;

  static Dio _buildDio() {
    final d = Dio(BaseOptions(
      baseUrl: '${AppConstants.baseUrl}${AppConstants.apiPrefix}',
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 45),
      // Server p95 is <1s end-to-end (see backend embed_ms/centroid_ms
      // logs). 20s is generous headroom for cold DashScope + weak
      // uplink while still failing fast enough that the "识别中" chip
      // doesn't hang visibly forever on a dead NAT path.
      receiveTimeout: const Duration(seconds: 20),
    ));

    d.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      // idleTimeout=0 makes dart:io close the socket the instant the
      // response completes, so it never goes back into the pool and
      // the next classify call is guaranteed to handshake afresh.
      return HttpClient()..idleTimeout = Duration.zero;
    });

    d.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('access_token');
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));

    return d;
  }

  /// Classify up to [AppConstants] max files in one shot.
  ///
  /// Files are downsampled to a small thumbnail before upload. The
  /// backend's embedding service resizes every image to 512 px
  /// server-side anyway, so sending the full 1920×1080 q90 JPEG over
  /// a mobile uplink just made nginx hit `client_body_timeout` before
  /// the request ever reached FastAPI. A 512 px q75 thumbnail lands
  /// at ~30–80 KB.
  Future<List<ClassifyResult>> classify(List<File> files) async {
    if (files.isEmpty) return const <ClassifyResult>[];

    // [DEBUG-2026-04-22] remove once the new fresh-connection path is
    // confirmed stable in the wild.
    final overallSw = Stopwatch()..start();
    debugPrint('[ClassifyDbg] classify START files=${files.length}');

    // Pre-compress all thumbnails once; the retry reuses the same
    // bytes to avoid re-running flutter_image_compress on retry.
    final parts = <_Part>[];
    int totalBytes = 0;
    int fallbackCount = 0;
    for (int i = 0; i < files.length; i++) {
      final src = files[i];
      final filename = src.path.split('/').last;
      final origLen = await src.length().catchError((_) => -1);
      final thumb = await _compressForClassify(src, i);
      if (thumb != null) {
        totalBytes += thumb.length;
        debugPrint(
          '[ClassifyDbg] file[$i] orig=${origLen}B thumb=${thumb.length}B'
          ' ratio=${(origLen > 0 ? thumb.length / origLen : -1).toStringAsFixed(3)}',
        );
        parts.add(_Part.bytes(thumb, filename));
      } else {
        fallbackCount++;
        totalBytes += origLen >= 0 ? origLen : 0;
        debugPrint(
          '[ClassifyDbg] file[$i] COMPRESS FAILED falling back to orig=${origLen}B',
        );
        parts.add(_Part.file(src.path, filename));
      }
    }
    debugPrint(
      '[ClassifyDbg] body built totalBytes=$totalBytes fallback=$fallbackCount'
      ' prepMs=${overallSw.elapsedMilliseconds}',
    );

    try {
      return await _postOnce(parts, attempt: 1);
    } on DioException catch (e) {
      if (!_isRetryable(e)) rethrow;
      debugPrint(
        '[ClassifyDbg] retry-after-${e.type} — opening fresh connection',
      );
      return await _postOnce(parts, attempt: 2);
    }
  }

  Future<List<ClassifyResult>> _postOnce(
    List<_Part> parts, {
    required int attempt,
  }) async {
    final fd = FormData();
    for (final p in parts) {
      fd.files.add(MapEntry('files', p.build()));
    }

    final postSw = Stopwatch()..start();
    try {
      final resp = await _dio.post(
        '/photos/classify',
        data: fd,
        options: Options(
          // `Connection: close` tells dart:io to tear the socket down
          // after the response finishes. Belt-and-suspenders with the
          // zero idleTimeout on the dedicated HttpClient above.
          persistentConnection: false,
        ),
      );
      debugPrint(
        '[ClassifyDbg] POST ok attempt=$attempt postMs=${postSw.elapsedMilliseconds}'
        ' status=${resp.statusCode}',
      );
      final list = (resp.data['results'] as List).cast<Map<String, dynamic>>();
      return list.map(ClassifyResult.fromJson).toList();
    } on DioException catch (e, st) {
      debugPrint(
        '[ClassifyDbg] POST FAIL attempt=$attempt postMs=${postSw.elapsedMilliseconds}'
        ' type=${e.type} msg=${e.message}'
        ' respCode=${e.response?.statusCode}'
        ' innerErr=${e.error?.runtimeType}:${e.error}'
        '\n$st',
      );
      rethrow;
    }
  }

  bool _isRetryable(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      default:
        return false;
    }
  }

  Future<Uint8List?> _compressForClassify(File src, int index) async {
    final sw = Stopwatch()..start();
    try {
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/classify_${DateTime.now().millisecondsSinceEpoch}_$index.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        src.path,
        outPath,
        minWidth: 512,
        minHeight: 512,
        format: CompressFormat.jpeg,
        quality: 75,
      );
      if (result == null) {
        debugPrint(
          '[ClassifyDbg] compress[$index] returned null ms=${sw.elapsedMilliseconds}',
        );
        return null;
      }
      final bytes = await File(result.path).readAsBytes();
      debugPrint(
        '[ClassifyDbg] compress[$index] ok ms=${sw.elapsedMilliseconds}'
        ' out=${bytes.length}B',
      );
      try {
        await File(result.path).delete();
      } catch (_) {}
      return bytes;
    } catch (e, st) {
      debugPrint(
        '[ClassifyDbg] compress[$index] THREW ms=${sw.elapsedMilliseconds}'
        ' err=${e.runtimeType}:$e\n$st',
      );
      return null;
    }
  }
}

/// Serialisable multipart part — either in-memory bytes (the happy
/// path, after compression) or a file path fallback. We keep the
/// source material so a retry can rebuild a fresh [FormData] without
/// re-running image compression. A [FormData] itself is single-shot
/// (its internal stream can't be re-read) so we always build a new
/// one per attempt.
class _Part {
  _Part._(this._bytes, this._path, this.filename);

  factory _Part.bytes(Uint8List bytes, String filename) =>
      _Part._(bytes, null, filename);
  factory _Part.file(String path, String filename) =>
      _Part._(null, path, filename);

  final Uint8List? _bytes;
  final String? _path;
  final String filename;

  MultipartFile build() {
    final bytes = _bytes;
    if (bytes != null) {
      return MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: DioMediaType('image', 'jpeg'),
      );
    }
    return MultipartFile.fromFileSync(_path!, filename: filename);
  }
}
