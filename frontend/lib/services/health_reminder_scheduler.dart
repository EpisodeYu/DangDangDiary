import 'dart:async';

import '../models/health.dart';
import '../models/pet.dart';
import 'health_service.dart';
import 'notification_service.dart';
import 'pet_service.dart';

/// One eligible reminder item for a single pet / type on a single rebuild.
///
/// [triggerDaysFromToday] is measured in whole local calendar days:
///   * `>= 3`  — schedule entry arises from the "3 days before due" rule.
///   * `0..2`  — inside the pre-reminder window.
///   * `< 0`   — overdue; normalised to `0` when building the schedule.
class _ReminderItem {
  _ReminderItem({
    required this.label,
    required this.daysRemaining,
  });

  final String label;
  final int daysRemaining;

  /// Days from today (local) until this item should first fire.
  int get triggerDaysFromToday {
    if (daysRemaining >= 3) return daysRemaining - 3;
    return 0;
  }
}

/// Rebuilds the local notification schedule for all known pets based on
/// the current health-status data served by the backend.
///
/// Usage: call [refresh] from every place that can change health state
/// (cold start, returning from background, create/edit/delete of a
/// deworming or routine record, cycle / reminder-switch save).
class HealthReminderScheduler {
  HealthReminderScheduler({
    required PetService petService,
    required HealthService healthService,
    NotificationService? notificationService,
  })  : _petService = petService,
        _healthService = healthService,
        _notificationService = notificationService ?? NotificationService.instance;

  final PetService _petService;
  final HealthService _healthService;
  final NotificationService _notificationService;

  bool _running = false;
  bool _pending = false;

  /// Request a fresh recompute. Concurrent callers are coalesced: if a
  /// refresh is already in-flight, only one follow-up rebuild is
  /// queued regardless of how many times [refresh] is called during it.
  Future<void> refresh() async {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    try {
      await _runOnce();
      while (_pending) {
        _pending = false;
        await _runOnce();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _runOnce() async {
    await _notificationService.cancelAllHealthReminders();

    final List<Pet> pets;
    try {
      final result = await _petService.getPets(page: 1, pageSize: 100);
      pets = result.pets;
    } catch (_) {
      return;
    }
    if (pets.isEmpty) return;

    for (final pet in pets) {
      await _scheduleForPet(pet);
    }
  }

  Future<void> _scheduleForPet(Pet pet) async {
    final items = <_ReminderItem>[];

    try {
      final deworm = await _healthService.getDewormingStatus(pet.id);
      _collectDeworm(deworm, items);
    } catch (_) {
      // Skip this category on transient failure but keep the other one.
    }
    try {
      final routine = await _healthService.getRoutineStatus(pet.id);
      _collectRoutine(routine, items);
    } catch (_) {}

    if (items.isEmpty) return;

    items.sort((a, b) =>
        a.triggerDaysFromToday.compareTo(b.triggerDaysFromToday));
    final soonestDay = items.first.triggerDaysFromToday;
    final sameDay = items
        .where((it) => it.triggerDaysFromToday <= soonestDay)
        .toList();

    final scheduledAt = _computeScheduledTime(soonestDay);
    final body = _composeBody(pet.name, sameDay);

    try {
      await _notificationService.scheduleHealthReminder(
        petId: pet.id,
        scheduledAt: scheduledAt,
        title: '健康提醒',
        body: body,
      );
    } catch (_) {
      // Don't let a single pet failing break the rest of the schedule.
    }
  }

  void _collectDeworm(DewormingStatus status, List<_ReminderItem> out) {
    void add(DewormingStatusItem item, String label) {
      if (!item.reminderEnabled) return;
      if (item.cycleDays == null) return;
      if (item.daysRemaining == null) return;
      out.add(_ReminderItem(label: label, daysRemaining: item.daysRemaining!));
    }

    add(status.internal, DewormingTypeE.internal.label);
    add(status.external, DewormingTypeE.external.label);
    add(status.combined, DewormingTypeE.combined.label);
  }

  void _collectRoutine(RoutineStatus status, List<_ReminderItem> out) {
    void add(RoutineStatusItem item, String label) {
      if (!item.reminderEnabled) return;
      if (item.cycleDays == null) return;
      if (item.daysRemaining == null) return;
      out.add(_ReminderItem(label: label, daysRemaining: item.daysRemaining!));
    }

    add(status.bath, RoutineTypeE.bath.label);
    add(status.nailTrim, RoutineTypeE.nailTrim.label);
    add(status.grooming, RoutineTypeE.grooming.label);
  }

  /// Anchor all aggregated reminders to 09:00 on the trigger date.
  /// If that wall-clock time has already passed (e.g. user opens the app
  /// mid-afternoon on the due day), we push to the next day so the user
  /// is not spammed with an immediate notification — they are already
  /// in-app and the health screen itself surfaces the overdue state.
  DateTime _computeScheduledTime(int daysFromToday) {
    final now = DateTime.now();
    final baseDay = DateTime(now.year, now.month, now.day)
        .add(Duration(days: daysFromToday));
    DateTime scheduled = DateTime(baseDay.year, baseDay.month, baseDay.day, 9);
    while (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  String _composeBody(String petName, List<_ReminderItem> items) {
    final labels = <String>{};
    for (final it in items) {
      labels.add(it.label);
    }
    if (labels.length <= 3) {
      return '$petName 今天需要关注：${labels.join('、')}';
    }
    return '$petName 有 ${labels.length} 项健康提醒待处理，请打开当当日记查看';
  }
}
