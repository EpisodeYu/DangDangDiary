import 'dart:async';

import 'package:dangdang_diary/services/pet_export_service.dart';
import 'package:dangdang_diary/widgets/pet_export_dialog.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeExportService extends PetExportService {
  bool? photos;
  bool? records;
  bool fail = false;
  Completer<bool>? pending;
  CancelToken? token;

  @override
  Future<bool> export({
    required int petId,
    required bool photos,
    required bool records,
    required CancelToken cancelToken,
    required void Function(PetExportProgress) onProgress,
  }) async {
    this.photos = photos;
    this.records = records;
    token = cancelToken;
    if (fail) throw Exception('network');
    onProgress(
      const PetExportProgress(PetExportStage.photos, completed: 1, total: 2),
    );
    return pending == null
        ? true
        : await Future.any([
            pending!.future,
            cancelToken.whenCancel.then<bool>((e) => throw e),
          ]);
  }
}

void main() {
  late FakeExportService service;
  bool? result;

  Future<void> open(WidgetTester tester) async {
    service = FakeExportService();
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => PetExportDialog(petId: 7, service: service),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'defaults both selected, requires at least one, supports records only',
    (tester) async {
      await open(tester);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((w) => w.value!),
        isTrue,
      );
      await tester.tap(find.text('照片'));
      await tester.tap(find.text('记录'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('记录'));
      await tester.pump();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(service.photos, isFalse);
      expect(service.records, isTrue);
      expect(result, isTrue);
    },
  );

  testWidgets('cancel selection does not start export', (tester) async {
    await open(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.photos, isNull);
    expect(result, isFalse);
  });

  testWidgets('failure stays open with retry and does not report success', (
    tester,
  ) async {
    await open(tester);
    service.fail = true;
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('下载失败'), findsOneWidget);
    expect(result, isNull);
    service.fail = false;
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('progress prevents duplicate submission and can cancel', (
    tester,
  ) async {
    await open(tester);
    service.pending = Completer<bool>();
    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('正在准备原图 1/2'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.token!.isCancelled, isTrue);
    expect(result, isFalse);
    service.pending!.complete(false);
  });
}
