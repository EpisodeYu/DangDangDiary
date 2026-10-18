import 'package:dangdang_diary/models/health.dart';
import 'package:dangdang_diary/services/health_service.dart';
import 'package:dangdang_diary/services/health_reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

const off = RoutineStatusItem(reminderEnabled: false);

class QuietReminders extends Fake implements HealthReminderScheduler {
  int refreshes = 0;
  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

/// An in-memory service used only for UI behavior; API tests exercise persistence.
class CustomRoutineFixture extends HealthService {
  final items = <RoutineItem>[
    const RoutineItem(type: RoutineTypeE.bath, status: off),
    const RoutineItem(type: RoutineTypeE.nailTrim, status: off),
  ];
  final history = <RoutineRecord>[];
  List<Map<String, dynamic>>? savedSettings;
  int _next = 1;

  @override
  Future<RoutineStatus> getRoutineStatus(int petId) async => RoutineStatus(
    bath: off,
    nailTrim: off,
    grooming: off,
    entries: List.of(items),
  );

  @override
  Future<RoutineListResult> getRoutines(
    int petId, {
    int page = 1,
    int pageSize = 50,
  }) async => RoutineListResult(
    routines: List.of(history),
    total: history.length,
    page: 1,
    pageSize: 50,
    totalPages: 1,
  );

  @override
  Future<void> createRoutineItem(int petId, String name) async {
    items.add(
      RoutineItem(type: RoutineTypeE('custom_${_next++}', name), status: off),
    );
  }

  @override
  Future<void> updateRoutineItem(
    int petId,
    RoutineTypeE type, {
    String? name,
    bool? reminderEnabled,
  }) async {
    final index = items.indexWhere((i) => i.type == type);
    final old = items[index];
    final updated = RoutineTypeE(type.apiValue, name ?? type.label);
    items[index] = RoutineItem(
      type: updated,
      status: RoutineStatusItem(
        reminderEnabled: reminderEnabled ?? old.status.reminderEnabled,
        cycleDays: old.status.cycleDays,
      ),
    );
    for (var i = 0; i < history.length; i++) {
      if (history[i].routineType == type) {
        history[i] = _record(
          updated,
          history[i].performedAt,
          id: history[i].id,
        );
      }
    }
  }

  @override
  Future<void> deleteRoutineItem(int petId, RoutineTypeE type) async {
    items.removeWhere((i) => i.type == type);
    for (var i = 0; i < history.length; i++) {
      if (history[i].routineType == type) {
        history[i] = _record(
          history[i].routineType,
          history[i].performedAt,
          id: history[i].id,
          deleted: true,
        );
      }
    }
  }

  @override
  Future<void> saveRoutineItems(
    int petId,
    List<Map<String, dynamic>> updates,
  ) async {
    savedSettings = updates;
    for (final update in updates) {
      final index = items.indexWhere(
        (i) => i.type.apiValue == update['routine_type'],
      );
      items[index] = RoutineItem(
        type: items[index].type,
        status: RoutineStatusItem(
          reminderEnabled: update['reminder_enabled'] as bool,
          cycleDays: update['cycle_days'] as int?,
        ),
      );
    }
  }

  RoutineRecord _record(
    RoutineTypeE type,
    String date, {
    int? id,
    bool deleted = false,
  }) => RoutineRecord(
    id: id ?? _next++,
    petId: 7,
    userId: 1,
    routineType: type,
    performedAt: date,
    createdAt: '2026-10-18T00:00:00',
    routineDeleted: deleted,
  );

  @override
  Future<RoutineRecord> createRoutine(
    int petId, {
    required RoutineTypeE routineType,
    required String performedAt,
  }) async {
    final record = _record(routineType, performedAt);
    history.add(record);
    return record;
  }

  @override
  Future<DewormingStatus> getDewormingStatus(int petId) async =>
      const DewormingStatus(
        internal: DewormingStatusItem(reminderEnabled: false),
        external: DewormingStatusItem(reminderEnabled: false),
        combined: DewormingStatusItem(reminderEnabled: false),
      );
}
