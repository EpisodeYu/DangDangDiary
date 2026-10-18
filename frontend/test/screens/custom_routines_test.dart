import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/models/voice_intake.dart';
import 'package:dangdang_diary/providers/health_provider.dart';
import 'package:dangdang_diary/providers/notification_provider.dart';
import 'package:dangdang_diary/providers/pet_provider.dart';
import 'package:dangdang_diary/screens/health/routine_tab.dart';
import 'package:dangdang_diary/screens/health/routine_cycle_screen.dart';
import 'package:dangdang_diary/screens/health/routine_record_screen.dart';
import 'package:dangdang_diary/services/voice_service.dart';
import 'package:dangdang_diary/widgets/voice_intake_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/custom_routine_fixture.dart';
import '../support/ui_fixture.dart';

class _Voice extends VoiceService {
  Map<String, dynamic>? saved;
  @override
  Future<VoiceIntakeConfirmResult> confirm({
    required String requestId,
    required VoiceIntent intent,
    required Map<String, dynamic> payload,
  }) async {
    saved = payload;
    return VoiceIntakeConfirmResult(
      requestId: requestId,
      entityType: 'routine',
      entityId: 1,
      entity: payload,
    );
  }
}

Future<GoRouter> mountCustomRoutines(
  WidgetTester tester,
  CustomRoutineFixture service, {
  Widget? screen,
  String role = 'owner',
  double scale = 1,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold()),
      GoRoute(
        path: '/test',
        builder: (_, _) =>
            screen ??
            Scaffold(
              body: RoutineTab(pet: uiPet(role: role)),
            ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        healthServiceProvider.overrideWithValue(service),
        petListProvider.overrideWith(() => UiPetList([uiPet(role: role)])),
        healthReminderSchedulerProvider.overrideWithValue(QuietReminders()),
      ],
      child: MaterialApp.router(
        theme: AppTheme.lightTheme,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  router.push('/test');
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('name-only add, rename and delete retain visible history', (
    tester,
  ) async {
    final service = CustomRoutineFixture();
    await mountCustomRoutines(tester, service);
    expect(find.text('梳毛'), findsNothing);
    await tester.tap(find.text('新增日常事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入事项名称'), findsOneWidget);
    await tester.enterText(find.byType(TextField), ' 刷牙 ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.items.last.type.label, '刷牙');
    expect(service.items.last.status.cycleDays, isNull);
    expect(service.items.last.status.reminderEnabled, isFalse);
    await service.createRoutine(
      7,
      routineType: service.items.last.type,
      performedAt: '2026-10-01',
    );
    await tester.tap(find.byTooltip('管理刷牙'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '清洁牙齿');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('清洁牙齿'), findsNWidgets(2));
    await tester.tap(find.byTooltip('管理清洁牙齿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除事项'));
    await tester.pumpAndSettle();
    expect(find.text('删除后停止提醒，已有历史记录仍会保留。'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(service.items.length, 2);
    expect(service.history.single.routineDeleted, isTrue);
    expect(find.text('清洁牙齿（已删除）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer cannot manage, change reminders or cycles', (
    tester,
  ) async {
    final service = CustomRoutineFixture();
    await service.createRoutineItem(7, '刷牙');
    await mountCustomRoutines(tester, service, role: 'viewer');
    expect(find.text('新增日常事项'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .every((c) => c.onChanged == null),
      isTrue,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '设置周期'))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'ten long names fit narrow screens with larger text and disable add',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = CustomRoutineFixture();
      for (var i = 0; i < 10; i++) {
        await service.createRoutineItem(7, '每天需要照顾的自定义日常事项名称$i');
      }
      await mountCustomRoutines(tester, service, scale: 1.5);
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, '自定义日常已达 10 项上限'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom cycle can be set while other cycles remain unset', (
    tester,
  ) async {
    final service = CustomRoutineFixture();
    await service.createRoutineItem(7, '刷牙');
    await mountCustomRoutines(
      tester,
      service,
      screen: const RoutineCycleScreen(petId: 7),
      role: 'editor',
    );
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .every((f) => f.controller!.text.isEmpty),
      isTrue,
    );
    await tester.enterText(find.byType(TextField).last, '7');
    await tester.tap(find.byType(Switch).last);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(service.savedSettings!.last, {
      'routine_type': 'custom_1',
      'cycle_days': 7,
      'reminder_enabled': true,
    });
    expect(service.savedSettings!.first['cycle_days'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom routine records the stable key', (tester) async {
    final service = CustomRoutineFixture();
    await service.createRoutineItem(7, '刷牙');
    await mountCustomRoutines(
      tester,
      service,
      screen: const RoutineRecordScreen(petId: 7),
    );
    await tester.tap(find.widgetWithText(ChoiceChip, '刷牙'));
    await tester.tap(find.text('确认记录'));
    await tester.pumpAndSettle();
    expect(service.history.single.routineType.apiValue, 'custom_1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice draft selects and confirms an existing custom item', (
    tester,
  ) async {
    final service = CustomRoutineFixture();
    await service.createRoutineItem(7, '刷牙');
    final voice = _Voice();
    await mountCustomRoutines(
      tester,
      service,
      screen: Scaffold(
        body: VoiceIntakeSheet(
          response: const VoiceIntakeResponse(
            requestId: 'test',
            status: VoiceIntakeStatus.draftPending,
            transcript: '今天给当当刷牙了',
            intent: VoiceIntent.routine,
            confidence: 95,
            needsConfirm: true,
            missingFields: [],
            draft: VoiceIntakeDraft(
              petId: 7,
              routineType: 'custom_1',
              routineAt: '2026-10-18',
            ),
          ),
          pets: [uiPet()],
          service: voice,
        ),
      ),
    );
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '刷牙')).selected,
      isTrue,
    );
    await tester.ensureVisible(find.text('确认记录'));
    await tester.tap(find.text('确认记录'));
    await tester.pumpAndSettle();
    expect(voice.saved!['routine_type'], 'custom_1');
    expect(voice.saved!['pet_id'], 7);
    expect(tester.takeException(), isNull);
  });
}
