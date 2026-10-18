import 'dart:io';

import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/screens/health/deworming_tab.dart';
import 'package:dangdang_diary/screens/health/routine_tab.dart';
import 'package:dangdang_diary/screens/health/vaccination_tab.dart';
import 'package:dangdang_diary/screens/health/weight_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/ui_fixture.dart';
import 'ui_layout_test.dart' show host, capture;

const _font = String.fromEnvironment('UI_FONT');

final _tabs = <String, Widget Function()>{
  'weight': () => WeightTab(pet: uiPet()),
  'routine': () => RoutineTab(pet: uiPet()),
  'deworming': () => DewormingTab(pet: uiPet()),
  'vaccination': () => VaccinationTab(pet: uiPet()),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_font.isEmpty) return;
    for (final family in ['ReviewFont', 'Roboto', 'monospace']) {
      await (FontLoader(
        family,
      )..addFont(File(_font).readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final tab in _tabs.entries) {
    testWidgets('${tab.key} swipe actions keep edit and delete confirmation', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: tab.value()),
          ),
          GoRoute(
            path: '/health/${tab.key}/edit',
            builder: (_, state) => Scaffold(
              body: Text('编辑记录 ${state.uri.queryParameters['petId']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: uiOverrides(),
          child: MaterialApp.router(
            theme: AppTheme.lightTheme,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openActions() async {
        final row = find.byType(Slidable).first;
        await tester.ensureVisible(row);
        await tester.drag(row, const Offset(-300, 0));
        await tester.pumpAndSettle();
      }

      await openActions();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑记录 7'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await openActions();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Slidable), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    for (final width in [390.0, 320.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('${tab.key} swipe captions fit at $width / $scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await host(tester, Scaffold(body: tab.value()), scale: scale);
          final row = find.byType(Slidable).first;
          await tester.ensureVisible(row);
          await tester.drag(row, const Offset(-300, 0));
          await tester.pumpAndSettle();
          await capture(tester, '${tab.key}-swipe-${width.toInt()}-$scale');
          for (final label in ['编辑', '删除']) {
            final text = find.descendant(of: row, matching: find.text(label));
            expect(text, findsOneWidget);
            final paragraph = tester.renderObject<RenderParagraph>(text);
            final natural = TextPainter(
              text: paragraph.text,
              textDirection: paragraph.textDirection,
              textScaler: paragraph.textScaler,
              maxLines: 1,
            )..layout();
            // RenderFlex can silently constrain a label without throwing an
            // overflow exception. Compare the allocated box to the full line.
            expect(
              paragraph.size.height + 0.01,
              greaterThanOrEqualTo(natural.height),
              reason: '$label must show the entire line',
            );
            expect(
              paragraph.size.width + 0.01,
              greaterThanOrEqualTo(natural.width),
              reason: '$label must not ellipsize',
            );
            natural.dispose();
            final button = find
                .ancestor(of: text, matching: find.byType(OutlinedButton))
                .first;
            final buttonRect = tester.getRect(button);
            final textRect = tester.getRect(text);
            expect(buttonRect.contains(textRect.topLeft), isTrue);
            expect(buttonRect.contains(textRect.bottomRight), isTrue);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
