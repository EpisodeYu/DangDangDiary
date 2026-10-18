import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dangdang_diary/services/pet_export_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pet_export_fixture.dart';

void main() {
  late Directory root;
  late Dio dio;
  late Map<String, dynamic> manifest;
  late List<int> copied;
  late List<Archive> saved;
  late Map<String, dynamic> query;
  late CancelToken token;
  late PetExportService service;
  int? failPhoto;
  bool cancelSave = false;
  bool failSave = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('export_test_');
    manifest = exportFixture();
    copied = [];
    saved = [];
    token = CancelToken();
    failPhoto = null;
    cancelSave = false;
    failSave = false;
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/pets/7/export');
            query = options.queryParameters;
            handler.resolve(Response(requestOptions: options, data: manifest));
          },
        ),
      );
    service = PetExportService(
      dio: dio,
      temporaryDirectory: () async => root,
      copyPhoto: (id, path, {required cancelToken}) async {
        copied.add(id);
        if (id == failPhoto) throw const SocketException('download failed');
        await File(path).writeAsBytes([255, id, 0, 127]);
      },
      saveArchive: (file, name) async {
        expect(name, '当当');
        expect(file.uri.pathSegments.last, '当当.zip');
        if (failSave) throw const FileSystemException('disk full');
        if (cancelSave) return null;
        saved.add(
          ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true),
        );
        return '/chosen/当当.zip';
      },
    );
  });

  tearDown(() async {
    expect(
      await root.list().toList(),
      isEmpty,
      reason: 'temporary export files must be removed',
    );
    await root.delete();
    dio.close();
  });

  Future<bool> run({
    bool photos = true,
    bool records = true,
    void Function(PetExportProgress)? progress,
  }) => service.export(
    petId: 7,
    photos: photos,
    records: records,
    cancelToken: token,
    onProgress: progress ?? (_) {},
  );

  test(
    'both selections preserve original bytes and complete structured records',
    () async {
      expect(await run(), isTrue);
      expect(query, {'photos': true, 'records': true});
      expect(copied, [1, 2]);
      final zip = saved.single;
      expect(zip.findFile('photos/1.jpg')!.content, [255, 1, 0, 127]);
      expect(zip.findFile('photos/2.png')!.content, [255, 2, 0, 127]);
      final json = jsonDecode(utf8.decode(zip.findFile('当当.json')!.content));
      expect(json['pet'], manifest['pet']);
      expect(json['records'], manifest['records']);
      expect(json['exported_at'], manifest['exported_at']);
      expect(json['photos'][0]['file'], 'photos/1.jpg');
    },
  );

  test('records only creates ZIP containing only named JSON', () async {
    manifest['photos'] = null;
    expect(await run(photos: false), isTrue);
    expect(copied, isEmpty);
    expect(saved.single.files.map((f) => f.name), ['当当.json']);
  });

  test('photos only does not include JSON or request health records', () async {
    manifest['records'] = null;
    expect(await run(records: false), isTrue);
    expect(query['records'], isFalse);
    expect(saved.single.files.where((f) => f.name.endsWith('.json')), isEmpty);
  });

  test(
    'all photos including those beyond list page sizes are packed',
    () async {
      manifest = exportFixture(count: 121);
      expect(await run(), isTrue);
      expect(copied.length, 121);
      expect(saved.single.files.where((f) => f.isFile).length, 122);
    },
  );

  test('empty archive selection fails before network and picker', () async {
    await expectLater(run(photos: false, records: false), throwsArgumentError);
    expect(saved, isEmpty);
  });

  test('no photos exports a valid empty photos directory', () async {
    manifest = exportFixture(count: 0);
    expect(await run(records: false), isTrue);
    expect(saved.single.findFile('photos/'), isNotNull);
  });

  test('one missing original aborts entire export; retry succeeds', () async {
    failPhoto = 2;
    await expectLater(run(), throwsA(isA<SocketException>()));
    expect(saved, isEmpty);
    expect(await root.list().toList(), isEmpty);
    failPhoto = null;
    expect(await run(), isTrue);
  });

  test(
    'duplicate or foreign photos cannot produce a misleading archive',
    () async {
      manifest['photos'][1]['id'] = 1;
      await expectLater(run(), throwsFormatException);
      expect(copied, isEmpty);
      manifest['photos'][1]['id'] = 2;
      manifest['photos'][1]['pet_id'] = 8;
      await expectLater(run(), throwsFormatException);
      expect(saved, isEmpty);
    },
  );

  test('cancel during photos or packing never opens picker', () async {
    for (final stage in [PetExportStage.photos, PetExportStage.packing]) {
      token = CancelToken();
      await expectLater(
        run(
          progress: (p) {
            if (p.stage == stage) token.cancel();
          },
        ),
        throwsA(isA<DioException>()),
      );
      expect(saved, isEmpty);
      expect(await root.list().toList(), isEmpty);
    }
  });

  test('picker cancellation and save failure clean up staging files', () async {
    cancelSave = true;
    expect(await run(), isFalse);
    expect(saved, isEmpty);
    cancelSave = false;
    failSave = true;
    await expectLater(run(), throwsA(isA<FileSystemException>()));
  });

  test(
    'portable names retain Chinese while removing traversal and reserved names',
    () {
      expect(exportFileName('当当'), '当当');
      expect(exportFileName('../当当\\:*?'), '.._当当____');
      expect(exportFileName('... '), '宠物档案');
      expect(exportFileName('CON'), '_CON');
    },
  );
}
