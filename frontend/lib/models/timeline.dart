import 'package:flutter/foundation.dart';

@immutable
class TimelinePhoto {
  final int id;
  final int petId;
  final String petName;
  final String petType;
  final String thumbnailUrl;
  final DateTime takenAt;
  final DateTime createdAt;

  const TimelinePhoto({
    required this.id,
    required this.petId,
    required this.petName,
    required this.petType,
    required this.thumbnailUrl,
    required this.takenAt,
    required this.createdAt,
  });

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
      thumbnailUrl: json['thumbnail_url'] as String,
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
