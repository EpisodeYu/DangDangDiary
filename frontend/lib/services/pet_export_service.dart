import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:file_saver/file_saver.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'original_photo_cache.dart';

enum PetExportStage { loading, photos, packing, saving }

class PetExportProgress {
  const PetExportProgress(this.stage, {this.completed = 0, this.total = 0});
  final PetExportStage stage;
  final int completed;
  final int total;
}

typedef CopyExportPhoto =
    Future<void> Function(
      int photoId,
      String destination, {
      required CancelToken cancelToken,
    });
typedef SaveExportArchive = Future<String?> Function(File file, String name);

/// Metadata comes from one server snapshot; all original files and the ZIP
/// are prepared on the device. Only a complete archive reaches the save picker.
class PetExportService {
  PetExportService({
    Dio? dio,
    CopyExportPhoto? copyPhoto,
    SaveExportArchive? saveArchive,
    Future<Directory> Function()? temporaryDirectory,
  }) : _dio = dio ?? ApiClient().dio,
       _copyPhoto = copyPhoto ?? OriginalPhotoCache.instance.copyOriginalTo,
       _saveArchive = saveArchive ?? _saveWithPicker,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final Dio _dio;
  final CopyExportPhoto _copyPhoto;
  final SaveExportArchive _saveArchive;
  final Future<Directory> Function() _temporaryDirectory;

  Future<bool> export({
    required int petId,
    required bool photos,
    required bool records,
    required CancelToken cancelToken,
    required void Function(PetExportProgress) onProgress,
  }) async {
    if (!photos && !records) throw ArgumentError('请至少选择照片或记录');
    Directory? work;
    void checkCancelled() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    }

    try {
      checkCancelled();
      onProgress(const PetExportProgress(PetExportStage.loading));
      final response = await _dio.get<Map<String, dynamic>>(
        '/pets/$petId/export',
        queryParameters: {'photos': photos, 'records': records},
        cancelToken: cancelToken,
        options: Options(receiveTimeout: const Duration(minutes: 2)),
      );
      checkCancelled();
      final data = response.data!;
      final pet = data['pet'] as Map<String, dynamic>;
      if (data['schema_version'] != 1 || pet['id'] != petId) {
        throw const FormatException('档案数据不匹配，请重试');
      }
      final name = exportFileName(pet['name'] as String);
      final photoList = photos ? data['photos'] as List<dynamic> : const [];
      final ids = <int>{};
      for (final photo in photoList) {
        if (photo['pet_id'] != petId || !ids.add(photo['id'] as int)) {
          throw const FormatException('照片清单不完整，请重试');
        }
      }
      if (records) {
        final health = data['records'] as Map<String, dynamic>;
        for (final key in [
          'weights',
          'dewormings',
          'vaccinations',
          'routines',
        ]) {
          final rows = health[key] as List<dynamic>;
          if (rows.any((row) => row['pet_id'] != petId)) {
            throw const FormatException('健康记录不匹配，请重试');
          }
        }
      }

      work = await (await _temporaryDirectory()).createTemp('pet_export_');
      final contents = await Directory('${work.path}/contents').create();
      final cancelFile = File('${work.path}/cancelled');
      // The worker checks this marker between files. It always closes its file
      // handles before the main isolate removes temporary data (also on Windows).
      var finished = false;
      cancelToken.whenCancel.then((_) {
        if (!finished) {
          try {
            cancelFile.writeAsStringSync('cancelled');
          } on FileSystemException {
            // If storage is full, the caller still checks cancellation before
            // saving. Never turn a cancellation into an unhandled IO error.
          }
        }
      });
      try {
        final photoMetadata = <Map<String, dynamic>>[];
        if (photos) {
          final dir = await Directory('${contents.path}/photos').create();
          for (var i = 0; i < photoList.length; i++) {
            checkCancelled();
            onProgress(
              PetExportProgress(
                PetExportStage.photos,
                completed: i,
                total: photoList.length,
              ),
            );
            final photo = Map<String, dynamic>.from(photoList[i] as Map);
            final key = photo['storage_key'] as String;
            final extension = key.split('.').last.toLowerCase();
            if (!['jpg', 'jpeg', 'png', 'webp'].contains(extension)) {
              throw const FormatException('照片格式无法识别，请重试');
            }
            final filename = '${photo['id']}.$extension';
            await _copyPhoto(
              photo['id'] as int,
              '${dir.path}/$filename',
              cancelToken: cancelToken,
            );
            checkCancelled();
            if (await File('${dir.path}/$filename').length() == 0) {
              throw const FileSystemException('原图文件为空，请重试');
            }
            photo.remove('storage_key');
            photo['file'] = 'photos/$filename';
            photoMetadata.add(photo);
            onProgress(
              PetExportProgress(
                PetExportStage.photos,
                completed: i + 1,
                total: photoList.length,
              ),
            );
          }
        }
        if (records) {
          await File('${contents.path}/$name.json').writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'schema_version': data['schema_version'],
              'exported_at': data['exported_at'],
              'timestamp_timezone': 'UTC',
              'pet': pet,
              'records': data['records'],
              if (photos) 'photos': photoMetadata,
            }),
            encoding: utf8,
          );
        }
        checkCancelled();
        onProgress(const PetExportProgress(PetExportStage.packing));
        final zipPath = '${work.path}/$name.zip';
        await _pack(contents.path, zipPath, cancelFile.path);
        checkCancelled();
        onProgress(const PetExportProgress(PetExportStage.saving));
        return await _saveArchive(File(zipPath), name) != null;
      } finally {
        finished = true;
      }
    } finally {
      if (work != null && await work.exists()) {
        await work.delete(recursive: true);
      }
    }
  }

  static Future<String?> _saveWithPicker(File file, String name) =>
      FileSaver.instance.saveAs(
        name: name,
        filePath: file.path,
        fileExtension: 'zip',
        mimeType: MimeType.zip,
      );

  static Future<void> _pack(String source, String destination, String marker) =>
      Isolate.run(() => _packFiles(source, destination, marker));
}

// Run away from Flutter's UI isolate; stream files from disk, never load the
// whole archive into memory. JPEG/PNG/WebP are already compressed, so ZIP store
// avoids wasting CPU and preserves every byte of the server original.
Future<void> _packFiles(
  String source,
  String destination,
  String marker,
) async {
  final encoder = ZipFileEncoder()..create(destination);
  try {
    final directory = Directory(source);
    await for (final entry in directory.list(recursive: true)) {
      if (File(marker).existsSync()) return;
      final relative = entry.path
          .substring(source.length + 1)
          .replaceAll('\\', '/');
      if (entry is File) {
        await encoder.addFile(
          entry,
          relative,
          relative.endsWith('.json') ? 6 : 0,
        );
      } else if (entry is Directory) {
        encoder.addArchiveFile(ArchiveFile.directory('$relative/'));
      }
    }
  } finally {
    await encoder.close();
  }
}

String exportFileName(String name) {
  var safe = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) safe = '宠物档案';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(safe)) {
    safe = '_$safe';
  }
  return safe;
}
