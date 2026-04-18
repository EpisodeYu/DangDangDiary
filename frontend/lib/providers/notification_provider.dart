import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/health_provider.dart';
import '../providers/pet_provider.dart';
import '../services/health_reminder_scheduler.dart';
import '../services/notification_service.dart';

/// Global singleton notification plugin wrapper.
final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService.instance);

/// Health-reminder scheduler. It is stateless besides an in-flight flag,
/// so a single shared instance per app session is fine.
final healthReminderSchedulerProvider =
    Provider<HealthReminderScheduler>((ref) {
  return HealthReminderScheduler(
    petService: ref.read(petServiceProvider),
    healthService: ref.read(healthServiceProvider),
    notificationService: ref.read(notificationServiceProvider),
  );
});
