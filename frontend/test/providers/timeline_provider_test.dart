import 'package:dangdang_diary/models/timeline.dart';
import 'package:dangdang_diary/providers/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

TimelinePhoto _photo({
  required int id,
  required int petId,
  required DateTime takenAt,
  DateTime? createdAt,
  String petName = 'A',
  String petType = 'cat',
}) {
  return TimelinePhoto(
    id: id,
    petId: petId,
    petName: petName,
    petType: petType,
    thumbnailUrl: 'http://t/$id.jpg',
    takenAt: takenAt,
    createdAt: createdAt ?? takenAt,
  );
}

TimelineWindowResponse _window({
  required List<TimelinePhoto> photos,
  int total = 0,
  String? prev,
  String? next,
  bool hasMoreNewer = false,
  bool hasMoreOlder = false,
  String? requested,
  String? resolved,
}) {
  // Group by month preserving order (photos are expected newest-first).
  final map = <String, List<TimelinePhoto>>{};
  final order = <String>[];
  for (final p in photos) {
    final k = '${p.takenAt.year.toString().padLeft(4, '0')}-${p.takenAt.month.toString().padLeft(2, '0')}';
    map.putIfAbsent(k, () {
      order.add(k);
      return <TimelinePhoto>[];
    }).add(p);
  }
  final groups = order
      .map((k) => TimelineGroup(
            date: k,
            label: TimelineMerge.monthLabel(k),
            photos: map[k]!,
          ))
      .toList();
  return TimelineWindowResponse(
    groups: groups,
    total: total == 0 ? photos.length : total,
    limit: 40,
    prevCursor: prev,
    nextCursor: next,
    hasMoreNewer: hasMoreNewer,
    hasMoreOlder: hasMoreOlder,
    requestedAnchorMonth: requested,
    resolvedAnchorMonth: resolved,
    dateRange: TimelineDateRange(
      earliest: photos.isEmpty
          ? null
          : photos.reduce((a, b) => a.takenAt.isBefore(b.takenAt) ? a : b).takenAt,
      latest: photos.isEmpty
          ? null
          : photos.reduce((a, b) => a.takenAt.isAfter(b.takenAt) ? a : b).takenAt,
    ),
  );
}

void main() {
  group('TimelineMerge.mergeWindow', () {
    test('initial merge builds ordered ids and grouped months', () {
      final state = TimelineState.initial(const TimelineFilter(petIds: []));
      final resp = _window(
        photos: [
          _photo(id: 3, petId: 1, takenAt: DateTime(2024, 2, 10)),
          _photo(id: 2, petId: 1, takenAt: DateTime(2024, 1, 20)),
          _photo(id: 1, petId: 1, takenAt: DateTime(2024, 1, 5)),
        ],
        next: 'c_older',
        hasMoreOlder: true,
      );
      final next = TimelineMerge.mergeWindow(
        state, resp,
        fromNewer: false, fromOlder: false, fromAnchor: false,
      );
      expect(next.orderedPhotoIds, [3, 2, 1]);
      expect(next.groups.map((g) => g.date).toList(), ['2024-02', '2024-01']);
      expect(next.groups[0].photos.length, 1);
      expect(next.groups[1].photos.length, 2);
      expect(next.monthFirstPhotoIndex, {'2024-02': 0, '2024-01': 1});
      expect(next.tailCursor, 'c_older');
      expect(next.hasMoreOlder, true);
    });

    test('older merge dedupes and preserves global order', () {
      final state = TimelineState.initial(const TimelineFilter(petIds: []));
      final first = TimelineMerge.mergeWindow(
        state,
        _window(
          photos: [
            _photo(id: 10, petId: 1, takenAt: DateTime(2024, 5, 1)),
            _photo(id: 9, petId: 1, takenAt: DateTime(2024, 4, 15)),
          ],
          next: 'c1',
          hasMoreOlder: true,
        ),
        fromNewer: false, fromOlder: false, fromAnchor: false,
      );

      // Server could accidentally repeat id=9 in next page.
      final second = TimelineMerge.mergeWindow(
        first,
        _window(
          photos: [
            _photo(id: 9, petId: 1, takenAt: DateTime(2024, 4, 15)),
            _photo(id: 8, petId: 1, takenAt: DateTime(2024, 4, 10)),
            _photo(id: 7, petId: 1, takenAt: DateTime(2024, 3, 1)),
          ],
          next: 'c2',
          hasMoreOlder: false,
        ),
        fromNewer: false, fromOlder: true, fromAnchor: false,
      );

      expect(second.orderedPhotoIds, [10, 9, 8, 7]);
      expect(second.tailCursor, 'c2');
      expect(second.hasMoreOlder, false);
      expect(second.groups.map((g) => g.date).toList(),
          ['2024-05', '2024-04', '2024-03']);
    });

    test('stable sort with equal taken_at uses created_at then id DESC', () {
      final state = TimelineState.initial(const TimelineFilter(petIds: []));
      final d = DateTime(2024, 4, 1);
      final resp = _window(photos: [
        _photo(id: 5, petId: 1, takenAt: d, createdAt: DateTime(2024, 4, 1, 10)),
        _photo(id: 6, petId: 1, takenAt: d, createdAt: DateTime(2024, 4, 1, 9)),
        _photo(id: 7, petId: 1, takenAt: d, createdAt: DateTime(2024, 4, 1, 10)),
      ]);
      final next = TimelineMerge.mergeWindow(
        state, resp,
        fromNewer: false, fromOlder: false, fromAnchor: false,
      );
      // createdAt DESC: 10 > 9. Tie at 10 → id DESC: 7 > 5.
      expect(next.orderedPhotoIds, [7, 5, 6]);
    });

    test('anchor merge inserts a new window into existing data', () {
      final state = TimelineState.initial(const TimelineFilter(petIds: []));
      final top = TimelineMerge.mergeWindow(
        state,
        _window(
          photos: [
            _photo(id: 100, petId: 1, takenAt: DateTime(2024, 6, 1)),
            _photo(id: 99, petId: 1, takenAt: DateTime(2024, 5, 20)),
          ],
          next: 'top_tail',
          hasMoreOlder: true,
        ),
        fromNewer: false, fromOlder: false, fromAnchor: false,
      );

      // Jump to Feb 2024 (not yet loaded): server returns a middle window.
      final anchor = TimelineMerge.mergeWindow(
        top,
        _window(
          photos: [
            _photo(id: 50, petId: 1, takenAt: DateTime(2024, 2, 15)),
            _photo(id: 49, petId: 1, takenAt: DateTime(2024, 2, 10)),
            _photo(id: 48, petId: 1, takenAt: DateTime(2024, 1, 30)),
          ],
          prev: 'mid_head',
          next: 'mid_tail',
          hasMoreNewer: true,
          hasMoreOlder: true,
          requested: '2024-02',
          resolved: '2024-02',
        ),
        fromNewer: false, fromOlder: false, fromAnchor: true,
      );

      expect(anchor.orderedPhotoIds, [100, 99, 50, 49, 48]);
      expect(anchor.groups.map((g) => g.date).toList(),
          ['2024-06', '2024-05', '2024-02', '2024-01']);
      expect(anchor.monthFirstPhotoIndex['2024-02'], 2);
    });

    test('newer merge keeps tail cursor, updates head cursor', () {
      final state = TimelineState.initial(const TimelineFilter(petIds: []));
      // First: the server pretends we loaded a middle window.
      final middle = TimelineMerge.mergeWindow(
        state,
        _window(
          photos: [
            _photo(id: 50, petId: 1, takenAt: DateTime(2024, 2, 15)),
          ],
          prev: 'h1',
          next: 't1',
          hasMoreNewer: true,
          hasMoreOlder: true,
        ),
        fromNewer: false, fromOlder: false, fromAnchor: false,
      );

      final newer = TimelineMerge.mergeWindow(
        middle,
        _window(
          photos: [
            _photo(id: 60, petId: 1, takenAt: DateTime(2024, 3, 1)),
            _photo(id: 55, petId: 1, takenAt: DateTime(2024, 2, 20)),
          ],
          prev: 'h2',
          next: 'should_be_ignored',
          hasMoreNewer: false,
          hasMoreOlder: true,
        ),
        fromNewer: true, fromOlder: false, fromAnchor: false,
      );

      expect(newer.orderedPhotoIds, [60, 55, 50]);
      expect(newer.headCursor, 'h2');
      // tail cursor preserved
      expect(newer.tailCursor, 't1');
      expect(newer.hasMoreOlder, true);
      expect(newer.hasMoreNewer, false);
    });
  });

  group('TimelineFilter equality', () {
    test('same ids → equal', () {
      const a = TimelineFilter(petIds: [1, 2]);
      const b = TimelineFilter(petIds: [1, 2]);
      expect(a, equals(b));
    });
    test('different ids → not equal', () {
      const a = TimelineFilter(petIds: [1, 2]);
      const b = TimelineFilter(petIds: [1, 3]);
      expect(a == b, isFalse);
    });
  });
}
