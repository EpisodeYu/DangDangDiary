import 'dart:io';

import 'package:dangdang_diary/config/router.dart';
import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/models/health.dart';
import 'package:dangdang_diary/models/timeline.dart';
import 'package:dangdang_diary/providers/health_provider.dart';
import 'package:dangdang_diary/services/health_service.dart';
import 'package:dangdang_diary/services/original_photo_cache.dart';
import 'package:dangdang_diary/widgets/photo_grid_tile.dart';
import 'package:dangdang_diary/widgets/immersive_photo_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/ui_fixture.dart';

class _Health extends HealthService {
  double? savedWeight;
  @override
  Future<WeightRecord> createWeight(
    int petId, {
    required double weightKg,
    required String recordedAt,
  }) async {
    savedWeight = weightKg;
    return WeightRecord(
      id: 1,
      petId: petId,
      userId: 1,
      weightKg: weightKg,
      recordedAt: recordedAt,
      createdAt: '2026-10-18T00:00:00',
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real navigation, keyboard, photos and dialogs retain behavior', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final bytes = (await rootBundle.load(
      'assets/brand/logo_512.png',
    )).buffer.asUint8List();
    // Only synthetic data and app brand artwork are used for device review.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(bytes);
      await request.response.close();
    });
    final source = File(
      '${(await getTemporaryDirectory()).path}/ui-review-fixture.png',
    );
    await source.writeAsBytes(bytes);
    final cache = OriginalPhotoCache.instance;
    final photos = <TimelinePhoto>[];
    for (var i = 0; i < 6; i++) {
      await cache.bindPendingToPhoto(
        await cache.cacheUploadSource(source),
        1100 + i,
      );
      photos.add(
        TimelinePhoto(
          id: 1100 + i,
          petId: 7,
          petName: '当当',
          petType: 'cat',
          uploaderId: 1,
          thumbnailUrl: 'http://127.0.0.1:${server.port}/$i.png',
          takenAt: DateTime(2026, 10, 18),
          createdAt: DateTime(2026, 10, 18),
        ),
      );
    }
    final health = _Health();
    final container = ProviderContainer(
      overrides: [
        ...uiOverrides(photos: UiPhotos(photos)),
        healthServiceProvider.overrideWithValue(health),
      ],
    );
    final router = container.read(routerProvider);
    router.go('/record');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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

    try {
      await shot('01-record');
      await tester.tap(find.text('点击添加照片'));
      await tester.pumpAndSettle();
      await shot('02-photo-options');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('健康').last);
      await tester.pumpAndSettle();
      await shot('03-health');
      for (final tab in ['日常', '驱虫', '疫苗', '体重']) {
        await tester.tap(find.text(tab).first);
        await tester.pumpAndSettle();
        expect(find.text('$tab记录'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('添加记录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '4.60');
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await tester.pump(const Duration(seconds: 1));
      expect(
        binding.platformDispatcher.views.first.viewInsets.bottom,
        greaterThan(0),
      );
      await shot('04-weight-keyboard');
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认记录'));
      await tester.tap(find.text('确认记录'));
      await tester.pumpAndSettle();
      expect(health.savedWeight, 4.6);
      expect(find.text('最新体重'), findsOneWidget);

      await tester.tap(find.text('时间轴').last);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoGridTile), findsNWidgets(6));
      final loadedPhotos = find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null,
      );
      for (var i = 0; i < 50 && loadedPhotos.evaluate().length < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(loadedPhotos, findsAtLeastNWidgets(6));
      await shot('05-timeline-grid');
      await tester.tap(find.byType(PhotoGridTile).first);
      await tester.pumpAndSettle();
      await shot('06-photo-viewer');
      router.pop();
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(PhotoGridTile).first);
      await tester.pumpAndSettle();
      expect(find.text('详细信息'), findsOneWidget);
      expect(find.text('保存到相册'), findsOneWidget);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1/9'), findsOneWidget);
      await shot('07-photo-selection');
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('沉浸模式'));
      await tester.pumpAndSettle();
      expect(find.byType(ImmersivePhotoTile), findsWidgets);
      await shot('08-timeline-immersive');

      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await shot('09-profile');
      await tester.tap(find.text('宠物档案管理'));
      await tester.pumpAndSettle();
      await shot('10-pets');
      await tester.tap(find.text('当当'));
      await tester.pumpAndSettle();
      await shot('11-pet-edit');
      await tester.scrollUntilVisible(
        find.text('下载此档案全部数据'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('下载此档案全部数据'));
      await tester.pumpAndSettle();
      await shot('12-export-dialog');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('宠物档案分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当当'));
      await tester.pumpAndSettle();
      await shot('13-share-detail');
      await tester.ensureVisible(find.text('分享给好友 (QR 码)'));
      await tester.tap(find.text('分享给好友 (QR 码)'));
      await tester.pumpAndSettle();
      await shot('14-share-qr');
    } finally {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      container.dispose();
      await server.close(force: true);
      await source.delete();
    }
  });
}
