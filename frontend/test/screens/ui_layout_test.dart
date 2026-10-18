import 'dart:io';
import 'dart:ui' as ui;

import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/models/voice_intake.dart';
import 'package:dangdang_diary/services/voice_service.dart';
import 'package:dangdang_diary/widgets/voice_intake_sheet.dart';
import 'package:dangdang_diary/providers/health_provider.dart';
import 'package:dangdang_diary/providers/pet_provider.dart';
import 'package:dangdang_diary/screens/auth/login_screen.dart';
import 'package:dangdang_diary/screens/record/record_screen.dart';
import 'package:dangdang_diary/screens/health/health_screen.dart';
import 'package:dangdang_diary/screens/health/weight_tab.dart';
import 'package:dangdang_diary/screens/health/routine_tab.dart';
import 'package:dangdang_diary/screens/health/deworming_tab.dart';
import 'package:dangdang_diary/screens/health/vaccination_tab.dart';
import 'package:dangdang_diary/screens/health/weight_record_screen.dart';
import 'package:dangdang_diary/screens/health/routine_record_screen.dart';
import 'package:dangdang_diary/screens/health/deworming_record_screen.dart';
import 'package:dangdang_diary/screens/health/vaccination_record_screen.dart';
import 'package:dangdang_diary/screens/health/routine_cycle_screen.dart';
import 'package:dangdang_diary/screens/health/deworming_cycle_screen.dart';
import 'package:dangdang_diary/screens/profile/profile_screen.dart';
import 'package:dangdang_diary/screens/profile/pet_manage_screen.dart';
import 'package:dangdang_diary/screens/profile/pet_edit_screen.dart';
import 'package:dangdang_diary/screens/profile/share/pet_share_list_screen.dart';
import 'package:dangdang_diary/screens/profile/share/pet_share_detail_screen.dart';
import 'package:dangdang_diary/screens/profile/share/share_qr_preview_screen.dart';
import 'package:dangdang_diary/screens/timeline/timeline_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_fixture.dart';

const _capture = String.fromEnvironment('UI_CAPTURE');
const _font = String.fromEnvironment('UI_FONT');
final _boundary = GlobalKey();

VoiceIntakeResponse voiceDraft(VoiceIntent intent) => VoiceIntakeResponse(
  requestId: 'ui-review',
  status: VoiceIntakeStatus.draftPending,
  transcript: '今天给当当记录健康情况，请确认宠物、日期和记录内容。',
  intent: intent,
  confidence: 95,
  needsConfirm: true,
  missingFields: [],
  draft: const VoiceIntakeDraft(
    petId: 7,
    dewormingType: 'internal',
    dewormedAt: '2026-10-18',
    vaccineName: '猫三联',
    vaccinatedAt: '2026-10-18',
    weightKg: 4.25,
    weighedAt: '2026-10-18',
    routineType: 'bath',
    routineAt: '2026-10-18',
  ),
);

class UiVoice extends VoiceService {
  String? cancelled;
  @override
  Future<void> cancel(String requestId) async {
    cancelled = requestId;
  }
}

// Cycle pages are entered after the pet list has loaded in the real app.
Widget loadedPet(Widget child) => Consumer(
  builder: (context, ref, _) =>
      ref.watch(petListProvider).hasValue ? child : const SizedBox(),
);

Future<void> host(
  WidgetTester tester,
  Widget screen, {
  double scale = 1,
  bool empty = false,
  bool longName = false,
  String role = 'owner',
  List<Override> extra = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  var theme = AppTheme.lightTheme;
  if (_font.isNotEmpty) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'ReviewFont'),
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: 'ReviewFont',
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: theme.elevatedButtonTheme.style?.copyWith(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: 'ReviewFont',
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: 'ReviewFont',
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      dialogTheme: theme.dialogTheme.copyWith(
        titleTextStyle: theme.dialogTheme.titleTextStyle?.copyWith(
          fontFamily: 'ReviewFont',
        ),
        contentTextStyle: theme.dialogTheme.contentTextStyle?.copyWith(
          fontFamily: 'ReviewFont',
        ),
      ),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        ...uiOverrides(empty: empty, longName: longName, role: role),
        ...extra,
      ],
      child: MaterialApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: _boundary, child: child!),
        ),
        home: screen,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> capture(WidgetTester tester, String name) async {
  if (_capture.isEmpty) return;
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(_capture).create(recursive: true);
    await File('$_capture/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_font.isNotEmpty) {
      for (final family in ['ReviewFont', 'Roboto', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(File(_font).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
  });

  final pages = <String, Widget Function()>{
    'login': () => const LoginScreen(),
    'record': () => const RecordScreen(),
    'health': () => const HealthScreen(),
    'weight': () => Scaffold(body: WeightTab(pet: uiPet())),
    'routine': () => Scaffold(body: RoutineTab(pet: uiPet())),
    'deworming': () => Scaffold(body: DewormingTab(pet: uiPet())),
    'vaccination': () => Scaffold(body: VaccinationTab(pet: uiPet())),
    'weight-form': () => const WeightRecordScreen(petId: 7),
    'routine-form': () => const RoutineRecordScreen(petId: 7),
    'deworming-form': () => const DewormingRecordScreen(petId: 7),
    'vaccination-form': () => const VaccinationRecordScreen(petId: 7),
    'routine-cycle': () => loadedPet(const RoutineCycleScreen(petId: 7)),
    'deworming-cycle': () => loadedPet(const DewormingCycleScreen(petId: 7)),
    'profile': () => const ProfileScreen(),
    'pets': () => const PetManageScreen(),
    'pet-new': () => const PetEditScreen(),
    'pet-edit': () => const PetEditScreen(petId: 7),
    'shares': () => const PetShareListScreen(),
    'share-detail': () => const PetShareDetailScreen(petId: 7),
    'share-qr': () => ShareQrPreviewScreen(
      code: 'ABCD1234',
      petName: '当当',
      expiresAt: DateTime(2026, 10, 19),
    ),
    'timeline': () => const TimelineScreen(),
    for (final intent in [
      VoiceIntent.weight,
      VoiceIntent.routine,
      VoiceIntent.deworming,
      VoiceIntent.vaccination,
    ])
      'voice-${intent.name}': () => Scaffold(
        body: VoiceIntakeSheet(
          response: voiceDraft(intent),
          pets: [uiPet(longName: true)],
          service: UiVoice(),
        ),
      ),
  };
  for (final size in [const Size(390, 844), const Size(320, 640)]) {
    for (final page in pages.entries) {
      testWidgets('${page.key} fits $size with long content', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scale = size.width == 320 ? 1.5 : 1.0;
        await host(
          tester,
          page.value(),
          scale: scale,
          longName: size.width == 320,
        );
        expect(tester.takeException(), isNull, reason: page.key);
        if (page.key.endsWith('-cycle')) {
          final fields = tester.widgetList<TextField>(find.byType(TextField));
          expect(fields, hasLength(3));
          expect(
            fields.every((field) => field.controller!.text.isNotEmpty),
            isTrue,
          );
        }
        await capture(tester, '${page.key}-${size.width.toInt()}');
        // Review the lower content too, including fields and action buttons.
        final scroll = find.byType(Scrollable);
        if (scroll.evaluate().isNotEmpty) {
          await tester.drag(scroll.first, const Offset(0, -900));
          await tester.pump(const Duration(seconds: 1));
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.key} after scrolling',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }

  for (final page in [
    'record',
    'health',
    'weight',
    'routine',
    'deworming',
    'vaccination',
    'pets',
    'shares',
  ]) {
    testWidgets('$page empty state fits small screen', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await host(tester, pages[page]!(), empty: true, scale: 1.5);
      expect(tester.takeException(), isNull);
      await capture(tester, '$page-empty');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('health tabs and pet selector keep their actions', (
    tester,
  ) async {
    await host(tester, const HealthScreen());
    expect(find.text('最新体重'), findsOneWidget);
    for (final label in ['日常', '驱虫', '疫苗', '体重']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(find.text('$label记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('当当'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsOneWidget);
  });

  testWidgets(
    'form input, presets, date picker and validation remain available',
    (tester) async {
      await host(tester, const WeightRecordScreen(petId: 7));
      await tester.ensureVisible(find.text('确认记录'));
      await tester.tap(find.text('确认记录'));
      await tester.pump();
      expect(find.text('请输入正确的体重 (0-200 kg)'), findsOneWidget);
      await host(tester, const VaccinationRecordScreen(petId: 7));
      await tester.tap(find.text('猫三联'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '猫三联',
      );
      await tester.ensureVisible(find.byIcon(Icons.calendar_today_rounded));
      await tester.tap(find.byIcon(Icons.calendar_today_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final role in ['owner', 'editor', 'viewer']) {
    testWidgets('$role preserves profile controls and export selection', (
      tester,
    ) async {
      await host(tester, const PetEditScreen(petId: 7), role: role);
      await tester.scrollUntilVisible(
        find.text('下载此档案全部数据'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('下载此档案全部数据'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      await capture(tester, 'export-$role');
      await tester.tap(find.text('照片'));
      await tester.tap(find.text('记录'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '下载'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final controls = tester.widgetList<TextField>(find.byType(TextField));
      if (role == 'viewer') {
        expect(
          controls
              .where((field) => field.decoration?.labelText != '生日')
              .every((field) => field.readOnly),
          isTrue,
        );
        expect(find.widgetWithText(ElevatedButton, '保存'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'voice review stays scrollable with keyboard and cancels its draft',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final voice = UiVoice();
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVoiceIntakeSheet(
                context,
                response: voiceDraft(VoiceIntent.weight),
                pets: [uiPet(longName: true)],
                service: voice,
              ),
              child: const Text('打开语音确认'),
            ),
          ),
        ),
        scale: 1.5,
      );
      await tester.tap(find.text('打开语音确认'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '4.60');
      await tester.ensureVisible(find.text('确认记录'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'voice-keyboard');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(voice.cancelled, 'ui-review');
      expect(find.byType(VoiceIntakeSheet), findsNothing);
    },
  );

  testWidgets('error retry retains its provider action', (tester) async {
    var attempts = 0;
    await host(
      tester,
      Scaffold(body: WeightTab(pet: uiPet())),
      extra: [
        weightListProvider(7).overrideWith((_) async {
          attempts++;
          throw Exception('offline');
        }),
      ],
    );
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
