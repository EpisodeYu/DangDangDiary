import 'dart:convert';
import 'dart:io';

// ignore_for_file: depend_on_referenced_packages
import 'package:dangdang_diary/services/original_photo_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
  @override
  Future<String?> getTemporaryPath() async => root.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('orig_cache_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot);
    await OriginalPhotoCache.instance.resetForTest();
  });

  tearDown(() async {
    await OriginalPhotoCache.instance.resetForTest();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<File> makeFile(String name, int size) async {
    final f = File('${tempRoot.path}/$name');
    await f.writeAsBytes(List<int>.filled(size, 42));
    return f;
  }

  test('cacheUploadSource copies bytes and bindPendingToPhoto promotes entry',
      () async {
    final src = await makeFile('src.jpg', 1024);
    final token = await OriginalPhotoCache.instance.cacheUploadSource(src);
    expect(token, isNotEmpty);

    // Original file untouched; a copy lives in the cache dir.
    expect(await src.exists(), isTrue);

    // Before binding, photo-id lookup misses.
    expect(await OriginalPhotoCache.instance.getCachedOriginalFile(42), isNull);

    await OriginalPhotoCache.instance.bindPendingToPhoto(token, 42);

    final file = await OriginalPhotoCache.instance.getCachedOriginalFile(42);
    expect(file, isNotNull);
    expect(await file!.length(), 1024);

    // The pending entry must be gone after binding.
    final cacheDir = Directory('${tempRoot.path}/original_photo_cache');
    final remaining = await cacheDir
        .list()
        .where((e) => e is File && e.path.contains('/pending_'))
        .toList();
    expect(remaining, isEmpty);
  });

  test('releasePending deletes the cached copy', () async {
    final src = await makeFile('src.jpg', 256);
    final token = await OriginalPhotoCache.instance.cacheUploadSource(src);
    await OriginalPhotoCache.instance.releasePending(token);

    final cacheDir = Directory('${tempRoot.path}/original_photo_cache');
    final files = await cacheDir
        .list()
        .where((e) =>
            e is File &&
            !e.path.endsWith('index.json') &&
            !e.path.endsWith('.tmp'))
        .toList();
    expect(files, isEmpty);
  });

  test('removePhoto evicts photo-id bound entry', () async {
    final src = await makeFile('src.jpg', 512);
    final token = await OriginalPhotoCache.instance.cacheUploadSource(src);
    await OriginalPhotoCache.instance.bindPendingToPhoto(token, 7);
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(7),
      isNotNull,
    );
    await OriginalPhotoCache.instance.removePhoto(7);
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(7),
      isNull,
    );
  });

  test('LRU evicts oldest entries when quota exceeded', () async {
    // With three 1 KiB entries (3072B total) and a 2500B quota, evicting one
    // entry drops usage to 2048B which is below the 90% low-water mark
    // (2250B) so eviction stops there. This isolates the LRU behaviour to
    // exactly one victim.
    OriginalPhotoCache.instance.setMaxBytesForTest(2500);

    final f1 = await makeFile('a.bin', 1024);
    final t1 = await OriginalPhotoCache.instance.cacheUploadSource(f1);
    await OriginalPhotoCache.instance.bindPendingToPhoto(t1, 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final f2 = await makeFile('b.bin', 1024);
    final t2 = await OriginalPhotoCache.instance.cacheUploadSource(f2);
    await OriginalPhotoCache.instance.bindPendingToPhoto(t2, 2);

    // Touch photo 1 so photo 2 becomes the LRU victim.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await OriginalPhotoCache.instance.getCachedOriginalFile(1);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final f3 = await makeFile('c.bin', 1024);
    final t3 = await OriginalPhotoCache.instance.cacheUploadSource(f3);
    await OriginalPhotoCache.instance.bindPendingToPhoto(t3, 3);

    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(1),
      isNotNull,
      reason: 'recently touched photo should survive',
    );
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(3),
      isNotNull,
      reason: 'newest photo should be present',
    );
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(2),
      isNull,
      reason: 'oldest-accessed photo should have been evicted',
    );
  });

  test('clearAllForLogout wipes every photo_/pending_ file and the index',
      () async {
    // Seed: one photo-bound entry and one pending entry.
    final f1 = await makeFile('a.bin', 512);
    final t1 = await OriginalPhotoCache.instance.cacheUploadSource(f1);
    await OriginalPhotoCache.instance.bindPendingToPhoto(t1, 11);

    final f2 = await makeFile('b.bin', 256);
    // leave as a pending entry
    await OriginalPhotoCache.instance.cacheUploadSource(f2);

    // Sanity: cache has data and the index file exists on disk.
    expect(await OriginalPhotoCache.instance.getCachedOriginalFile(11),
        isNotNull);
    await OriginalPhotoCache.instance.flushForTest();

    final cacheDir = Directory('${tempRoot.path}/original_photo_cache');
    final indexFile = File('${cacheDir.path}/index.json');
    expect(await indexFile.exists(), isTrue);

    final beforeFiles = await cacheDir
        .list()
        .where((e) =>
            e is File &&
            (e.path.contains('/photo_') || e.path.contains('/pending_')))
        .length;
    expect(beforeFiles, greaterThanOrEqualTo(2));

    await OriginalPhotoCache.instance.clearAllForLogout();

    // No photo_*/pending_* files left on disk.
    final remaining = await cacheDir
        .list()
        .where((e) =>
            e is File &&
            (e.path.contains('/photo_') || e.path.contains('/pending_')))
        .toList();
    expect(remaining, isEmpty);

    // index.json is gone.
    expect(await indexFile.exists(), isFalse);

    // In-memory lookups miss everywhere.
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(11),
      isNull,
    );

    // A subsequent cold restart reconstructs an empty cache (no stale keys).
    await OriginalPhotoCache.instance.resetForTest();
    expect(
      await OriginalPhotoCache.instance.getCachedOriginalFile(11),
      isNull,
    );
  });

  test('persists across cold restart (re-init) by reading index.json',
      () async {
    final src = await makeFile('restart.bin', 128);
    final token = await OriginalPhotoCache.instance.cacheUploadSource(src);
    await OriginalPhotoCache.instance.bindPendingToPhoto(token, 99);

    // Give the microtask-deferred save a chance to flush.
    await OriginalPhotoCache.instance.flushForTest();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Sanity-check the on-disk index has our entry.
    final indexFile =
        File('${tempRoot.path}/original_photo_cache/index.json');
    expect(await indexFile.exists(), isTrue);
    final payload =
        json.decode(await indexFile.readAsString()) as Map<String, dynamic>;
    final keys = (payload['entries'] as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>)['key'])
        .toSet();
    expect(keys.contains('photo_99'), isTrue);

    // Simulate a cold restart.
    await OriginalPhotoCache.instance.resetForTest();

    final file = await OriginalPhotoCache.instance.getCachedOriginalFile(99);
    expect(file, isNotNull);
    expect(await file!.length(), 128);
  });
}
