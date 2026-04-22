import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

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
/// The server accepts up to 5 files in a single multipart request and
/// runs the embedding+decision pipeline in parallel on its side, so
/// the right thing to do from the client is batch everything freshly
/// picked into one call.
class ClassifyService {
  final Dio _dio = ApiClient().dio;

  /// Classify up to [AppConstants] max files in one shot.
  ///
  /// Files are downsampled to a small thumbnail before upload. The
  /// backend's embedding service resizes every image to 512 px
  /// server-side anyway, so sending the full 1920×1080 q90 JPEG over
  /// a mobile uplink just made nginx hit `client_body_timeout` before
  /// the request ever reached FastAPI (observed 2026-04-22: a 394 KB
  /// body from a phone produced a bare 408 from nginx). A 512 px q75
  /// thumbnail lands at ~30–60 KB.
  Future<List<ClassifyResult>> classify(List<File> files) async {
    if (files.isEmpty) return const <ClassifyResult>[];

    final fd = FormData();
    for (int i = 0; i < files.length; i++) {
      final src = files[i];
      final filename = src.path.split('/').last;
      final thumb = await _compressForClassify(src, i);
      if (thumb != null) {
        fd.files.add(MapEntry(
          'files',
          MultipartFile.fromBytes(
            thumb,
            filename: filename,
            contentType: DioMediaType('image', 'jpeg'),
          ),
        ));
      } else {
        fd.files.add(MapEntry(
          'files',
          MultipartFile.fromFileSync(src.path, filename: filename),
        ));
      }
    }

    final resp = await _dio.post(
      '/photos/classify',
      data: fd,
      options: Options(
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    final list = (resp.data['results'] as List).cast<Map<String, dynamic>>();
    return list.map(ClassifyResult.fromJson).toList();
  }

  Future<Uint8List?> _compressForClassify(File src, int index) async {
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
      if (result == null) return null;
      final bytes = await File(result.path).readAsBytes();
      try {
        await File(result.path).delete();
      } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
