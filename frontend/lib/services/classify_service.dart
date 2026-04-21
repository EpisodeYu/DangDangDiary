import 'dart:io';

import 'package:dio/dio.dart';

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
  /// Timeouts are higher than the default Dio sendTimeout because we
  /// serialise all files at once; the backend p99 sits below 1s but a
  /// congested mobile uplink + a cold DashScope container can stretch
  /// that a bit.
  Future<List<ClassifyResult>> classify(List<File> files) async {
    if (files.isEmpty) return const <ClassifyResult>[];

    final fd = FormData();
    for (final f in files) {
      final filename = f.path.split('/').last;
      fd.files.add(MapEntry(
        'files',
        MultipartFile.fromFileSync(f.path, filename: filename),
      ));
    }

    final resp = await _dio.post(
      '/photos/classify',
      data: fd,
      options: Options(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    final list = (resp.data['results'] as List).cast<Map<String, dynamic>>();
    return list.map(ClassifyResult.fromJson).toList();
  }
}
