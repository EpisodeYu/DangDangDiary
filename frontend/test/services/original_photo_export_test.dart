// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dangdang_diary/services/original_photo_cache.dart';
import 'package:dangdang_diary/services/photo_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Photos extends PhotoService {
  int requests = 0;
  @override
  Future<String> getOriginalUrl(int photoId) async {
    requests++;
    return 'https://test.invalid/original/$photoId';
  }
}

class _Download implements HttpClientAdapter {
  int requests = 0;
  Completer<void>? gate;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (gate != null) await gate!.future;
    return ResponseBody.fromBytes(
      List.generate(1024, (i) => i % 256),
      200,
      headers: {
        Headers.contentLengthHeader: ['1024'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late OriginalPhotoCache cache;
  late _Photos photos;
  late _Download download;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('export_original_');
    PathProviderPlatform.instance = _Paths(root.path);
    photos = _Photos();
    download = _Download();
    cache = OriginalPhotoCache.forTest(
      photoService: photos,
      downloadDio: Dio()..httpClientAdapter = download,
    );
  });
  tearDown(() async {
    await cache.resetForTest();
    await root.delete(recursive: true);
  });

  test(
    'local upload original is reused without URL request or download',
    () async {
      final source = await File(
        '${root.path}/source.jpg',
      ).writeAsBytes([1, 2, 3]);
      await cache.bindPendingToPhoto(await cache.cacheUploadSource(source), 1);
      final dest = '${root.path}/export.jpg';
      await cache.copyOriginalTo(1, dest, cancelToken: CancelToken());
      expect(await File(dest).readAsBytes(), [1, 2, 3]);
      expect(photos.requests, 0);
      expect(download.requests, 0);
    },
  );

  test(
    'missing original downloads once, stays usable even above cache quota',
    () async {
      cache.setMaxBytesForTest(512);
      final dest = '${root.path}/export.jpg';
      await cache.copyOriginalTo(2, dest, cancelToken: CancelToken());
      expect(
        await File(dest).readAsBytes(),
        List.generate(1024, (i) => i % 256),
      );
      expect(photos.requests, 1);
      expect(download.requests, 1);
      expect(cache.totalBytes, lessThanOrEqualTo(512));
    },
  );

  test('downloaded original is cached for repeat export', () async {
    await cache.copyOriginalTo(
      2,
      '${root.path}/first.jpg',
      cancelToken: CancelToken(),
    );
    await cache.copyOriginalTo(
      2,
      '${root.path}/second.jpg',
      cancelToken: CancelToken(),
    );
    expect(photos.requests, 1);
    expect(download.requests, 1);
  });

  test(
    'cancel returns promptly without aborting shared viewer download',
    () async {
      download.gate = Completer<void>();
      final viewer = cache.fetchOriginal(3);
      final token = CancelToken();
      final copy = cache.copyOriginalTo(
        3,
        '${root.path}/cancelled.jpg',
        cancelToken: token,
      );
      token.cancel();
      await expectLater(copy, throwsA(isA<DioException>()));
      download.gate!.complete();
      expect(await (await viewer).length(), 1024);
      expect(await File('${root.path}/cancelled.jpg').exists(), isFalse);
      expect(download.requests, 1);
    },
  );
}
