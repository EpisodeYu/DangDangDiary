import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/providers/health_provider.dart';
import 'package:dangdang_diary/providers/notification_provider.dart';
import 'package:dangdang_diary/providers/pet_provider.dart';
import 'package:dangdang_diary/screens/health/routine_tab.dart';
import 'package:dangdang_diary/screens/health/routine_cycle_screen.dart';
import 'package:dangdang_diary/screens/health/routine_record_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/custom_routine_fixture.dart';
import '../test/support/ui_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android custom daily item lifecycle', (tester) async {
    final service = CustomRoutineFixture();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('当当 · 日常')),
            body: RoutineTab(pet: uiPet()),
            floatingActionButton: FloatingActionButton(
              onPressed: () => context.push('/health/routine/record'),
              child: const Icon(Icons.add),
            ),
          ),
        ),
        GoRoute(
          path: '/health/routine/cycle',
          builder: (_, _) => const RoutineCycleScreen(petId: 7),
        ),
        GoRoute(
          path: '/health/routine/record',
          builder: (_, _) => const RoutineRecordScreen(petId: 7),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthServiceProvider.overrideWithValue(service),
          petListProvider.overrideWith(() => UiPetList([uiPet()])),
          healthReminderSchedulerProvider.overrideWithValue(QuietReminders()),
        ],
        child: MaterialApp.router(
          theme: AppTheme.lightTheme,
          routerConfig: router,
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();
    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await binding.takeScreenshot(name);
    }

    await tester.tap(find.text('新增日常事项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '刷牙');
    await shot('01-name-dialog');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.items.last.status.reminderEnabled, isFalse);
    expect(service.items.last.status.cycleDays, isNull);
    await shot('02-created');
    await tester.tap(find.text('设置周期'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '7');
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).last);
    await shot('03-cycle');
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(service.savedSettings!.last['cycle_days'], 7);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '刷牙'));
    await shot('04-record');
    await tester.ensureVisible(find.text('确认记录'));
    await tester.tap(find.text('确认记录'));
    await tester.pumpAndSettle();
    expect(service.history.single.routineType.apiValue, 'custom_1');
    await tester.tap(find.byTooltip('管理刷牙'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '清洁牙齿');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('管理清洁牙齿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除事项'));
    await shot('05-delete-confirmation');
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(service.items.length, 2);
    expect(find.text('清洁牙齿（已删除）'), findsOneWidget);
    await shot('06-retained-history');
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
