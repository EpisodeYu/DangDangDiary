class Photo {
  final int id;
  final int petId;
  final int userId;
  final String storageKey;
  final String thumbnailKey;
  final String thumbnailUrl;

  /// Optional ~200 px thumbnail URL (Phase 2). Empty for legacy rows; UI
  /// should fall back to [thumbnailUrl].
  final String thumbnailSmUrl;

  final String takenAt;
  final String createdAt;

  const Photo({
    required this.id,
    required this.petId,
    required this.userId,
    required this.storageKey,
    required this.thumbnailKey,
    required this.thumbnailUrl,
    this.thumbnailSmUrl = '',
    required this.takenAt,
    required this.createdAt,
  });

  factory Photo.fromJson(Map<String, dynamic> json) {
    return Photo(
      id: json['id'] as int,
      petId: json['pet_id'] as int,
      userId: json['user_id'] as int,
      storageKey: json['storage_key'] as String,
      thumbnailKey: json['thumbnail_key'] as String,
      thumbnailUrl: json['thumbnail_url'] as String,
      thumbnailSmUrl: (json['thumbnail_sm_url'] as String?) ?? '',
      takenAt: json['taken_at'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}

class PhotoUploadSuccess {
  final int index;
  final String filename;
  final Photo photo;

  const PhotoUploadSuccess({
    required this.index,
    required this.filename,
    required this.photo,
  });

  factory PhotoUploadSuccess.fromJson(Map<String, dynamic> json) {
    return PhotoUploadSuccess(
      index: json['index'] as int,
      filename: json['filename'] as String,
      photo: Photo.fromJson(json['photo'] as Map<String, dynamic>),
    );
  }
}

class PhotoUploadFailure {
  final int index;
  final String filename;
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  const PhotoUploadFailure({
    required this.index,
    required this.filename,
    required this.code,
    required this.message,
    this.details,
  });

  factory PhotoUploadFailure.fromJson(Map<String, dynamic> json) {
    return PhotoUploadFailure(
      index: json['index'] as int,
      filename: json['filename'] as String,
      code: json['code'] as String,
      message: json['message'] as String,
      details: json['details'] as Map<String, dynamic>?,
    );
  }
}

class PhotoUploadResponse {
  final List<PhotoUploadSuccess> successes;
  final List<PhotoUploadFailure> failures;
  final int successCount;
  final int failureCount;
  final int totalCount;

  const PhotoUploadResponse({
    required this.successes,
    required this.failures,
    required this.successCount,
    required this.failureCount,
    required this.totalCount,
  });

  factory PhotoUploadResponse.fromJson(Map<String, dynamic> json) {
    return PhotoUploadResponse(
      successes: (json['successes'] as List<dynamic>)
          .map((e) => PhotoUploadSuccess.fromJson(e as Map<String, dynamic>))
          .toList(),
      failures: (json['failures'] as List<dynamic>)
          .map((e) => PhotoUploadFailure.fromJson(e as Map<String, dynamic>))
          .toList(),
      successCount: json['success_count'] as int,
      failureCount: json['failure_count'] as int,
      totalCount: json['total_count'] as int,
    );
  }
}

class PhotoListResult {
  final List<Photo> photos;
  final int total;
  final int page;
  final int pageSize;
  final int totalPages;

  const PhotoListResult({
    required this.photos,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  factory PhotoListResult.fromJson(Map<String, dynamic> json) {
    return PhotoListResult(
      photos: (json['photos'] as List<dynamic>)
          .map((e) => Photo.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      page: json['page'] as int,
      pageSize: json['page_size'] as int,
      totalPages: json['total_pages'] as int,
    );
  }
}
