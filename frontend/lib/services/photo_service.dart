import 'dart:io';

import 'package:dio/dio.dart';

import '../models/photo.dart';
import '../models/timeline.dart';
import 'api_client.dart';

class PhotoService {
  final Dio _dio = ApiClient().dio;

  Future<PhotoUploadResponse> uploadPhotos({
    required int petId,
    required List<File> files,
    required List<String> takenAtDates,
    ProgressCallback? onSendProgress,
  }) async {
    final formData = FormData();
    for (final date in takenAtDates) {
      formData.fields.add(MapEntry('taken_at', date));
    }
    for (final f in files) {
      final filename = f.path.split('/').last;
      formData.files.add(MapEntry(
        'files',
        MultipartFile.fromFileSync(f.path, filename: filename),
      ));
    }

    final resp = await _dio.post(
      '/pets/$petId/photos',
      data: formData,
      options: Options(
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 300),
      ),
      onSendProgress: onSendProgress,
    );

    return PhotoUploadResponse.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<PhotoListResult> getPhotos(int petId, {int page = 1, int pageSize = 20}) async {
    final resp = await _dio.get(
      '/pets/$petId/photos',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return PhotoListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deletePhoto(int photoId) async {
    await _dio.delete('/photos/$photoId');
  }

  Future<String> getOriginalUrl(int photoId) async {
    final resp = await _dio.get('/photos/$photoId/url');
    return resp.data['url'] as String;
  }

  Future<TimelineWindowResponse> getTimeline({
    List<int> petIds = const [],
    int limit = 40,
    String? cursor,
    String direction = 'older',
    String? anchorMonth,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (petIds.isNotEmpty) {
      params['pet_ids'] = petIds.join(',');
    }
    if (cursor != null) {
      params['cursor'] = cursor;
      params['direction'] = direction;
    }
    if (anchorMonth != null) {
      params['anchor_month'] = anchorMonth;
    }
    final resp = await _dio.get('/photos/timeline', queryParameters: params);
    return TimelineWindowResponse.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<TimelineDatesResponse> getTimelineDates({
    List<int> petIds = const [],
  }) async {
    final params = <String, dynamic>{};
    if (petIds.isNotEmpty) {
      params['pet_ids'] = petIds.join(',');
    }
    final resp = await _dio.get(
      '/photos/timeline/dates',
      queryParameters: params,
    );
    return TimelineDatesResponse.fromJson(resp.data as Map<String, dynamic>);
  }
}
