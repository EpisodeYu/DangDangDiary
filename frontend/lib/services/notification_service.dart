import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Local notification service for DangDang Diary.
///
/// Step 7 only uses it for health reminders. The service owns a small
/// notification-ID space (starting at [healthIdBase]) so that future
/// local-notification features can reuse the same plugin without
/// colliding with health reminders.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  /// Reserved ID range [healthIdBase, healthIdBase + _healthIdSpan)
  /// for aggregated per-pet health reminders.
  static const int healthIdBase = 10000;
  static const int _healthIdSpan = 100000;

  static const String healthChannelId = 'health_reminder_channel';
  static const String healthChannelName = '健康提醒';
  static const String healthChannelDesc = '驱虫与日常护理到期提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Notifies listeners whenever a health-reminder notification is tapped.
  /// The value carries the `pet_id` encoded in the payload. Consumers (the
  /// app-level router host) watch this notifier to navigate to the
  /// corresponding pet's health page.
  final ValueNotifier<int?> pendingHealthPetId = ValueNotifier<int?>(null);

  bool _initialized = false;

  /// Initialises plugin, timezone database and notification channel.
  /// Safe to call multiple times.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    tz.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {
      // Fallback: leave as UTC; scheduled notifications will still fire,
      // just not aligned to a specific local time.
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          healthChannelId,
          healthChannelName,
          description: healthChannelDesc,
          importance: Importance.high,
        ),
      );
    }

    await _consumeLaunchNotification();
  }

  /// Request POST_NOTIFICATIONS permission (Android 13+). Silently no-ops
  /// on older versions.
  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission();
    return granted ?? true;
  }

  /// Cancels every pending notification in the health-reminder ID range.
  Future<void> cancelAllHealthReminders() async {
    final pending = await _plugin.pendingNotificationRequests();
    for (final req in pending) {
      if (req.id >= healthIdBase && req.id < healthIdBase + _healthIdSpan) {
        await _plugin.cancel(req.id);
      }
    }
  }

  /// Schedule a single aggregated health reminder for [petId] at the
  /// given local [scheduledAt] wall-clock time.
  Future<void> scheduleHealthReminder({
    required int petId,
    required DateTime scheduledAt,
    required String title,
    required String body,
  }) async {
    final id = _healthIdForPet(petId);
    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);

    final payload = jsonEncode(<String, dynamic>{
      'type': 'health_reminder',
      'pet_id': petId,
    });

    const androidDetails = AndroidNotificationDetails(
      healthChannelId,
      healthChannelName,
      channelDescription: healthChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzTime,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  /// Deterministic notification ID for a given [petId] inside the
  /// reserved health range. Two different pets will never collide.
  int _healthIdForPet(int petId) {
    final offset = petId.abs() % _healthIdSpan;
    return healthIdBase + offset;
  }

  void _onNotificationResponse(NotificationResponse response) {
    _handlePayload(response.payload);
  }

  Future<void> _consumeLaunchNotification() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) {
      _handlePayload(details?.notificationResponse?.payload);
    }
  }

  void _handlePayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic> &&
          decoded['type'] == 'health_reminder') {
        final petId = decoded['pet_id'];
        if (petId is int) {
          pendingHealthPetId.value = petId;
        } else if (petId is String) {
          pendingHealthPetId.value = int.tryParse(petId);
        }
      }
    } catch (_) {
      // Ignore malformed payloads.
    }
  }
}
