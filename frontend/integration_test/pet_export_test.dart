import 'dart:convert';
import 'dart:io';

import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/models/pet.dart';
import 'package:dangdang_diary/providers/pet_provider.dart';
import 'package:dangdang_diary/screens/profile/pet_edit_screen.dart';
import 'package:dangdang_diary/services/api_client.dart';
import 'package:dangdang_diary/services/original_photo_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/pet_export_fixture.dart';

class _PetList extends PetListNotifier {
  _PetList(this.role);
  final String role;
  @override
  Future<PetListResult> build() async => PetListResult(
    page: 1,
    pageSize: 1,
    total: 1,
    pets: [
      Pet.fromJson({
        ...exportFixture()['pet'] as Map<String, dynamic>,
        'is_owner': role == 'owner',
        'my_role': role,
        'created_at': '2024-01-01T00:00:00',
        'updated_at': '2024-01-01T00:00:00',
      }),
    ],
  );
  @override
  Future<void> silentRefresh() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'all members export originals and records through native save picker',
    (tester) async {
      // Synthetic loopback HTTP server: no production credentials or user data.
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originalBase = ApiClient().dio.options.baseUrl;
      ApiClient().dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
      final counts = <String, int>{};
      var name = '当当取消';
      server.listen((request) async {
        final path = request.uri.path;
        counts[path] = (counts[path] ?? 0) + 1;
        request.response.headers.contentType = ContentType.json;
        if (path == '/pets/7/export') {
          final data = exportFixture();
          data['pet']['name'] = name;
          if (request.uri.queryParameters['photos'] == 'false') {
            data['photos'] = null;
          }
          if (request.uri.queryParameters['records'] == 'false') {
            data['records'] = null;
          }
          request.response.write(jsonEncode(data));
        } else if (path == '/photos/2/url') {
          request.response.write(
            jsonEncode({'url': 'http://127.0.0.1:${server.port}/original/2'}),
          );
        } else if (path == '/original/2') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add([137, 80, 78, 71, 2, 0, 255]);
        } else {
          request.response.statusCode = 500;
          request.response.write('Unexpected request: $path');
        }
        await request.response.close();
      });
      final cache = OriginalPhotoCache.instance;
      await cache.clearAllForLogout();
      final source = File(
        '${(await getTemporaryDirectory()).path}/export_fixture.jpg',
      );
      await source.writeAsBytes([255, 216, 255, 1, 0, 127]);
      await cache.bindPendingToPhoto(await cache.cacheUploadSource(source), 1);
      try {
        for (final role in ['owner', 'editor', 'viewer']) {
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey(role),
              overrides: [petListProvider.overrideWith(() => _PetList(role))],
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                home: const PetEditScreen(petId: 7),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final export = find.text('下载此档案全部数据');
          await tester.scrollUntilVisible(
            export,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(export, findsOneWidget);
          final bottom = find.text(role == 'owner' ? '删除此宠物档案' : '不再查看此宠物档案');
          expect(bottom, findsOneWidget);
          expect(
            tester.getTopLeft(export).dy,
            lessThan(tester.getTopLeft(bottom).dy),
          );
          // First exercise cancellation in the native save picker.
          if (role == 'owner') {
            await tester.tap(export);
            await tester.pumpAndSettle();
            await tester.tap(find.text('下载'));
            await _waitUntilClosed(tester);
            expect(find.text('档案压缩包已保存'), findsNothing);
          }
          name = '当当$role';
          await tester.tap(export);
          await tester.pumpAndSettle();
          await tester.tap(find.text('下载'));
          await _waitUntilClosed(tester);
          expect(find.text('档案压缩包已保存'), findsOneWidget);
        }
        // The local original was never requested, and the missing original was
        // downloaded exactly once across cancellation and three successful saves.
        expect(counts['/photos/1/url'], isNull);
        expect(counts['/photos/2/url'], 1);
        expect(counts['/original/2'], 1);
        final temp = await getTemporaryDirectory();
        expect(
          await temp
              .list()
              .where(
                (f) =>
                    f.uri.pathSegments.any((p) => p.startsWith('pet_export_')),
              )
              .toList(),
          isEmpty,
        );
      } finally {
        ApiClient().dio.options.baseUrl = originalBase;
        await server.close(force: true);
        await source.delete();
        await cache.clearAllForLogout();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _waitUntilClosed(WidgetTester tester) async {
  // scripts/run_export_integration.py operates the Android DocumentsUI picker.
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.byType(AlertDialog).evaluate().isEmpty) return;
    if (find.textContaining('下载失败').evaluate().isNotEmpty) {
      fail('Export failed before native save completed');
    }
  }
  fail('Native save picker did not complete within 90 seconds');
}
