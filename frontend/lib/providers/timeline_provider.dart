import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/timeline.dart';
import '../services/photo_service.dart';
import 'pet_provider.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

@immutable
class TimelineFilter {
  final List<int> petIds;
  const TimelineFilter({required this.petIds});

  @override
  bool operator ==(Object other) {
    if (other is! TimelineFilter) return false;
    if (other.petIds.length != petIds.length) return false;
    for (var i = 0; i < petIds.length; i++) {
      if (other.petIds[i] != petIds[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(petIds);
}

/// Stable key used for global ordering: newest → oldest
@immutable
class _OrderKey implements Comparable<_OrderKey> {
  final DateTime takenAt;
  final DateTime createdAt;
  final int id;

  const _OrderKey(this.takenAt, this.createdAt, this.id);

  factory _OrderKey.fromPhoto(TimelinePhoto p) =>
      _OrderKey(p.takenAt, p.createdAt, p.id);

  @override
  int compareTo(_OrderKey other) {
    // Sort newest first
    final t = other.takenAt.compareTo(takenAt);
    if (t != 0) return t;
    final c = other.createdAt.compareTo(createdAt);
    if (c != 0) return c;
    return other.id - id;
  }
}

@immutable
class TimelineState {
  final TimelineFilter filter;
  final Map<int, TimelinePhoto> photoMap;
  final List<int> orderedPhotoIds; // newest → oldest
  final List<TimelineGroup> groups;
  final Map<String, int> monthFirstPhotoIndex; // month -> index in orderedPhotoIds
  final List<DateDistribution> monthDistribution;
  final TimelineDateRange dateRange;
  final int total;
  final String? headCursor;
  final String? tailCursor;
  final bool hasMoreNewer;
  final bool hasMoreOlder;
  final bool isInitialLoading;
  final bool isLoadingOlder;
  final bool isLoadingNewer;
  final Set<String> loadingAnchorMonths;
  final String? error;
  final int version; // bumped on reset; used to invalidate stale requests

  const TimelineState({
    required this.filter,
    required this.photoMap,
    required this.orderedPhotoIds,
    required this.groups,
    required this.monthFirstPhotoIndex,
    required this.monthDistribution,
    required this.dateRange,
    required this.total,
    required this.headCursor,
    required this.tailCursor,
    required this.hasMoreNewer,
    required this.hasMoreOlder,
    required this.isInitialLoading,
    required this.isLoadingOlder,
    required this.isLoadingNewer,
    required this.loadingAnchorMonths,
    required this.error,
    required this.version,
  });

  factory TimelineState.initial(TimelineFilter filter) {
    return TimelineState(
      filter: filter,
      photoMap: const {},
      orderedPhotoIds: const [],
      groups: const [],
      monthFirstPhotoIndex: const {},
      monthDistribution: const [],
      dateRange: TimelineDateRange.empty,
      total: 0,
      headCursor: null,
      tailCursor: null,
      hasMoreNewer: false,
      hasMoreOlder: false,
      isInitialLoading: true,
      isLoadingOlder: false,
      isLoadingNewer: false,
      loadingAnchorMonths: const {},
      error: null,
      version: 0,
    );
  }

  bool get isEmpty =>
      !isInitialLoading && orderedPhotoIds.isEmpty && error == null;

  TimelineState copyWith({
    TimelineFilter? filter,
    Map<int, TimelinePhoto>? photoMap,
    List<int>? orderedPhotoIds,
    List<TimelineGroup>? groups,
    Map<String, int>? monthFirstPhotoIndex,
    List<DateDistribution>? monthDistribution,
    TimelineDateRange? dateRange,
    int? total,
    String? headCursor,
    String? tailCursor,
    bool? hasMoreNewer,
    bool? hasMoreOlder,
    bool? isInitialLoading,
    bool? isLoadingOlder,
    bool? isLoadingNewer,
    Set<String>? loadingAnchorMonths,
    Object? error = _unset,
    int? version,
    bool clearHeadCursor = false,
    bool clearTailCursor = false,
  }) {
    return TimelineState(
      filter: filter ?? this.filter,
      photoMap: photoMap ?? this.photoMap,
      orderedPhotoIds: orderedPhotoIds ?? this.orderedPhotoIds,
      groups: groups ?? this.groups,
      monthFirstPhotoIndex: monthFirstPhotoIndex ?? this.monthFirstPhotoIndex,
      monthDistribution: monthDistribution ?? this.monthDistribution,
      dateRange: dateRange ?? this.dateRange,
      total: total ?? this.total,
      headCursor: clearHeadCursor ? null : (headCursor ?? this.headCursor),
      tailCursor: clearTailCursor ? null : (tailCursor ?? this.tailCursor),
      hasMoreNewer: hasMoreNewer ?? this.hasMoreNewer,
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      isLoadingNewer: isLoadingNewer ?? this.isLoadingNewer,
      loadingAnchorMonths: loadingAnchorMonths ?? this.loadingAnchorMonths,
      error: identical(error, _unset) ? this.error : error as String?,
      version: version ?? this.version,
    );
  }

  static const _unset = Object();
}

/// Pure merge helper, exported for testing.
class TimelineMerge {
  static String monthKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  static String monthLabel(String key) {
    final parts = key.split('-');
    return '${int.parse(parts[0])}年${int.parse(parts[1])}月';
  }

  static List<TimelineGroup> regroupByMonth(
    List<int> orderedIds,
    Map<int, TimelinePhoto> photoMap,
  ) {
    final groups = <String, List<TimelinePhoto>>{};
    final order = <String>[];
    for (final id in orderedIds) {
      final p = photoMap[id];
      if (p == null) continue;
      final key = monthKey(p.takenAt);
      final bucket = groups.putIfAbsent(key, () {
        order.add(key);
        return <TimelinePhoto>[];
      });
      bucket.add(p);
    }
    return order
        .map((k) => TimelineGroup(date: k, label: monthLabel(k), photos: groups[k]!))
        .toList(growable: false);
  }

  static Map<String, int> rebuildMonthIndex(List<TimelineGroup> groups) {
    final map = <String, int>{};
    var idx = 0;
    for (final g in groups) {
      map[g.date] = idx;
      idx += g.photos.length;
    }
    return map;
  }

  /// Merge `window` into the existing state. Returns the new state (without
  /// flipping cursor / loading flags — the caller decides).
  static TimelineState mergeWindow(
    TimelineState state,
    TimelineWindowResponse response, {
    required bool fromNewer,
    required bool fromOlder,
    required bool fromAnchor,
  }) {
    final newPhotos = response.flattenedPhotos;

    final photoMap = Map<int, TimelinePhoto>.from(state.photoMap);
    for (final p in newPhotos) {
      photoMap[p.id] = p;
    }

    // Rebuild ordered ids by sorting every known id (deduplicated).
    final ids = photoMap.keys.toList(growable: false);
    ids.sort((a, b) {
      return _OrderKey.fromPhoto(photoMap[a]!)
          .compareTo(_OrderKey.fromPhoto(photoMap[b]!));
    });

    final groups = regroupByMonth(ids, photoMap);
    final monthIndex = rebuildMonthIndex(groups);

    // Decide cursors and has_more_* based on direction.
    String? headCursor = state.headCursor;
    String? tailCursor = state.tailCursor;
    bool hasMoreNewer = state.hasMoreNewer;
    bool hasMoreOlder = state.hasMoreOlder;

    if (state.orderedPhotoIds.isEmpty || fromAnchor) {
      // Treat as fresh/anchor window — take cursors from server response.
      headCursor = response.prevCursor;
      tailCursor = response.nextCursor;
      hasMoreNewer = response.hasMoreNewer;
      hasMoreOlder = response.hasMoreOlder;
    } else if (fromOlder) {
      tailCursor = response.nextCursor;
      hasMoreOlder = response.hasMoreOlder;
    } else if (fromNewer) {
      headCursor = response.prevCursor;
      hasMoreNewer = response.hasMoreNewer;
    } else {
      // Refresh-first-page style — take both cursors.
      headCursor = response.prevCursor;
      tailCursor = response.nextCursor;
      hasMoreNewer = response.hasMoreNewer;
      hasMoreOlder = response.hasMoreOlder;
    }

    return state.copyWith(
      photoMap: photoMap,
      orderedPhotoIds: ids,
      groups: groups,
      monthFirstPhotoIndex: monthIndex,
      dateRange: response.dateRange,
      total: response.total,
      headCursor: headCursor,
      tailCursor: tailCursor,
      hasMoreNewer: hasMoreNewer,
      hasMoreOlder: hasMoreOlder,
    );
  }
}

// -------------- Notifier --------------

final selectedTimelineFilterProvider = Provider<TimelineFilter>((ref) {
  final ids = ref.watch(selectedTimelinePetIdsProvider);
  final sorted = [...ids]..sort();
  return TimelineFilter(petIds: sorted);
});

final timelineProvider = StateNotifierProvider.autoDispose<
    TimelineNotifier, TimelineState>((ref) {
  final filter = ref.watch(selectedTimelineFilterProvider);
  final service = ref.read(_photoServiceProvider);
  return TimelineNotifier(service: service, filter: filter);
});

class TimelineNotifier extends StateNotifier<TimelineState> {
  final PhotoService service;

  TimelineNotifier({required this.service, required TimelineFilter filter})
      : super(TimelineState.initial(filter)) {
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _loadMonthDistribution(),
      _loadInitialWindow(),
    ]);
    if (!mounted) return;
    state = state.copyWith(isInitialLoading: false);
  }

  Future<void> refresh() async {
    final v = state.version + 1;
    state = TimelineState.initial(state.filter).copyWith(version: v);
    await _bootstrap();
  }

  Future<void> _loadMonthDistribution() async {
    final v = state.version;
    try {
      final resp = await service.getTimelineDates(petIds: state.filter.petIds);
      if (!mounted || state.version != v) return;
      state = state.copyWith(
        monthDistribution: resp.months,
        dateRange: resp.dateRange,
      );
    } catch (e) {
      if (!mounted || state.version != v) return;
      state = state.copyWith(error: '加载时间轴失败: $e');
    }
  }

  Future<void> _loadInitialWindow() async {
    final v = state.version;
    try {
      final resp = await service.getTimeline(petIds: state.filter.petIds);
      if (!mounted || state.version != v) return;
      state = TimelineMerge.mergeWindow(
        state,
        resp,
        fromNewer: false,
        fromOlder: false,
        fromAnchor: false,
      );
    } catch (e) {
      if (!mounted || state.version != v) return;
      state = state.copyWith(error: '加载时间轴失败: $e');
    }
  }

  Future<void> loadOlder() async {
    if (state.isLoadingOlder || !state.hasMoreOlder) return;
    final cursor = state.tailCursor;
    if (cursor == null) return;
    final v = state.version;
    state = state.copyWith(isLoadingOlder: true);
    try {
      final resp = await service.getTimeline(
        petIds: state.filter.petIds,
        cursor: cursor,
        direction: 'older',
      );
      if (!mounted || state.version != v) return;
      state = TimelineMerge.mergeWindow(
        state,
        resp,
        fromNewer: false,
        fromOlder: true,
        fromAnchor: false,
      ).copyWith(isLoadingOlder: false);
    } catch (e) {
      if (!mounted || state.version != v) return;
      state = state.copyWith(isLoadingOlder: false, error: '加载更多失败: $e');
    }
  }

  Future<void> loadNewer() async {
    if (state.isLoadingNewer || !state.hasMoreNewer) return;
    final cursor = state.headCursor;
    if (cursor == null) return;
    final v = state.version;
    state = state.copyWith(isLoadingNewer: true);
    try {
      final resp = await service.getTimeline(
        petIds: state.filter.petIds,
        cursor: cursor,
        direction: 'newer',
      );
      if (!mounted || state.version != v) return;
      state = TimelineMerge.mergeWindow(
        state,
        resp,
        fromNewer: true,
        fromOlder: false,
        fromAnchor: false,
      ).copyWith(isLoadingNewer: false);
    } catch (e) {
      if (!mounted || state.version != v) return;
      state = state.copyWith(isLoadingNewer: false, error: '加载更多失败: $e');
    }
  }

  /// Jump to a specific month. If the month is already loaded locally,
  /// returns the resolved month key directly. Otherwise fetches a new window
  /// anchored at the month.
  ///
  /// Returns the month key that should be scrolled to (may differ from the
  /// requested one due to server-side fallback), or null on failure.
  Future<String?> jumpToMonth(String month) async {
    if (state.monthFirstPhotoIndex.containsKey(month)) {
      return month;
    }
    if (state.loadingAnchorMonths.contains(month)) return null;
    final v = state.version;
    state = state.copyWith(
      loadingAnchorMonths: {...state.loadingAnchorMonths, month},
    );
    try {
      final resp = await service.getTimeline(
        petIds: state.filter.petIds,
        anchorMonth: month,
      );
      if (!mounted || state.version != v) return null;
      final resolved = resp.resolvedAnchorMonth;
      final next = TimelineMerge.mergeWindow(
        state,
        resp,
        fromNewer: false,
        fromOlder: false,
        fromAnchor: true,
      );
      state = next.copyWith(
        loadingAnchorMonths:
            next.loadingAnchorMonths.where((m) => m != month).toSet(),
      );
      return resolved;
    } catch (e) {
      if (!mounted || state.version != v) return null;
      state = state.copyWith(
        loadingAnchorMonths:
            state.loadingAnchorMonths.where((m) => m != month).toSet(),
        error: '跳转月份失败: $e',
      );
      return null;
    }
  }

  /// Trigger edge-loading from the photo viewer.
  Future<void> ensureNeighborsLoaded(int currentIndex) async {
    const threshold = 3;
    final length = state.orderedPhotoIds.length;
    if (length == 0) return;
    if (currentIndex <= threshold && state.hasMoreNewer) {
      loadNewer();
    }
    if (length - currentIndex <= threshold && state.hasMoreOlder) {
      loadOlder();
    }
  }
}
