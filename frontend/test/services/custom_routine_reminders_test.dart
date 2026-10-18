import 'package:dangdang_diary/models/health.dart';
import 'package:dangdang_diary/models/pet.dart';
import 'package:dangdang_diary/services/health_reminder_scheduler.dart';
import 'package:dangdang_diary/services/notification_service.dart';
import 'package:dangdang_diary/services/pet_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/custom_routine_fixture.dart';
import '../support/ui_fixture.dart';

class _Pets extends PetService {
  @override
  Future<PetListResult> getPets({int page = 1, int pageSize = 20}) async =>
      PetListResult(page: 1, pageSize: 100, total: 1, pets: [uiPet()]);
}

class _Notifications extends Fake implements NotificationService {
  final pending = <int, String>{};
  int cancellations = 0;
  @override
  Future<void> cancelAllHealthReminders() async {
    cancellations++;
    pending.clear();
  }

  @override
  Future<void> scheduleHealthReminder({
    required int petId,
    required DateTime scheduledAt,
    required String title,
    required String body,
  }) async {
    pending[petId] = body;
  }
}

void main() {
  test(
    'custom reminders use current name and deletion cancels pending notification',
    () async {
      final health = CustomRoutineFixture();
      const type = RoutineTypeE('custom_1', '清洁牙齿');
      health.items.add(
        const RoutineItem(
          type: type,
          status: RoutineStatusItem(
            reminderEnabled: true,
            cycleDays: 7,
            daysRemaining: 1,
          ),
        ),
      );
      final notifications = _Notifications();
      final scheduler = HealthReminderScheduler(
        petService: _Pets(),
        healthService: health,
        notificationService: notifications,
      );
      await scheduler.refresh();
      expect(notifications.pending[7], contains('清洁牙齿'));
      await health.deleteRoutineItem(7, type);
      await scheduler.refresh();
      expect(notifications.pending, isEmpty);
      expect(notifications.cancellations, 2);
    },
  );
}
