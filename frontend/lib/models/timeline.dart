import 'package:flutter/foundation.dart';

@immutable
class TimelinePhoto {
  final int id;
  final int petId;
  final String petName;
  final String petType;
  final int uploaderId;
  final String? uploaderNickname;

  /// ~400 px thumbnail. Used by the immersive list placeholder and as a
  /// fallback when the small-tier URL is missing (legacy photos).
  final String thumbnailUrl;

  /// ~200 px thumbnail. Preferred by the calendar grid because it decodes
  /// to roughly a quarter of the bytes of the large tier and therefore
  /// keeps many more cells warm in the image cache. Empty string for
  /// legacy rows; callers should fall back to [thumbnailUrl].
  final String thumbnailSmUrl;

  final DateTime takenAt;
  final DateTime createdAt;

  const TimelinePhoto({
    required this.id,
    required this.petId,
    required this.petName,
    required this.petType,
    required this.uploaderId,
    this.uploaderNickname,
    required this.thumbnailUrl,
    this.thumbnailSmUrl = '',
    required this.takenAt,
    required this.createdAt,
  });

  /// Preferred URL for the timeline grid: small tier if present, otherwise
  /// fall back to the standard thumbnail URL.
  String get gridThumbnailUrl =>
      thumbnailSmUrl.isNotEmpty ? thumbnailSmUrl : thumbnailUrl;

  String get monthKey {
    final y = takenAt.year.toString().padLeft(4, '0');
    final m = takenAt.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  factory TimelinePhoto.fromJson(Map<String, dynamic> json) {
    return TimelinePhoto(
      id: json['id'] as int,
      petId: json['pet_id'] as int,
      petName: json['pet_name'] as String,
      petType: json['pet_type'] as String,
      uploaderId: json['uploader_id'] as int,
      uploaderNickname: json['uploader_nickname'] as String?,
      thumbnailUrl: json['thumbnail_url'] as String,
      thumbnailSmUrl: (json['thumbnail_sm_url'] as String?) ?? '',
      takenAt: DateTime.parse(json['taken_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

@immutable
class TimelineGroup {
  final String date; // "YYYY-MM"
  final String label;
  final List<TimelinePhoto> photos;

  const TimelineGroup({
    required this.date,
    required this.label,
    required this.photos,
  });

  factory TimelineGroup.fromJson(Map<String, dynamic> json) {
    return TimelineGroup(
      date: json['date'] as String,
      label: json['label'] as String,
      photos: (json['photos'] as List<dynamic>)
          .map((e) => TimelinePhoto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

@immutable
class DateDistribution {
  final String date; // "YYYY-MM"
  final String label;
  final int count;

  const DateDistribution({
    required this.date,
    required this.label,
    required this.count,
  });

  factory DateDistribution.fromJson(Map<String, dynamic> json) {
    return DateDistribution(
      date: json['date'] as String,
      label: json['label'] as String,
      count: json['count'] as int,
    );
  }
}

@immutable
class TimelineDateRange {
  final DateTime? earliest;
  final DateTime? latest;

  const TimelineDateRange({this.earliest, this.latest});

  factory TimelineDateRange.fromJson(Map<String, dynamic> json) {
    DateTime? parse(dynamic v) => v == null ? null : DateTime.parse(v as String);
    return TimelineDateRange(
      earliest: parse(json['earliest']),
      latest: parse(json['latest']),
    );
  }

  static const empty = TimelineDateRange();
}

@immutable
class TimelineDatesResponse {
  final List<DateDistribution> months;
  final TimelineDateRange dateRange;

  const TimelineDatesResponse({required this.months, required this.dateRange});

  factory TimelineDatesResponse.fromJson(Map<String, dynamic> json) {
    return TimelineDatesResponse(
      months: (json['months'] as List<dynamic>)
          .map((e) => DateDistribution.fromJson(e as Map<String, dynamic>))
          .toList(),
      dateRange: TimelineDateRange.fromJson(
        (json['date_range'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}

@immutable
class TimelineWindowResponse {
  final List<TimelineGroup> groups;
  final int total;
  final int limit;
  final String? prevCursor;
  final String? nextCursor;
  final bool hasMoreNewer;
  final bool hasMoreOlder;
  final String? requestedAnchorMonth;
  final String? resolvedAnchorMonth;
  final TimelineDateRange dateRange;

  const TimelineWindowResponse({
    required this.groups,
    required this.total,
    required this.limit,
    this.prevCursor,
    this.nextCursor,
    required this.hasMoreNewer,
    required this.hasMoreOlder,
    this.requestedAnchorMonth,
    this.resolvedAnchorMonth,
    required this.dateRange,
  });

  List<TimelinePhoto> get flattenedPhotos =>
      groups.expand((g) => g.photos).toList(growable: false);

  factory TimelineWindowResponse.fromJson(Map<String, dynamic> json) {
    return TimelineWindowResponse(
      groups: (json['groups'] as List<dynamic>)
          .map((e) => TimelineGroup.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      limit: json['limit'] as int,
      prevCursor: json['prev_cursor'] as String?,
      nextCursor: json['next_cursor'] as String?,
      hasMoreNewer: (json['has_more_newer'] as bool?) ?? false,
      hasMoreOlder: (json['has_more_older'] as bool?) ?? false,
      requestedAnchorMonth: json['requested_anchor_month'] as String?,
      resolvedAnchorMonth: json['resolved_anchor_month'] as String?,
      dateRange: TimelineDateRange.fromJson(
        (json['date_range'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}
