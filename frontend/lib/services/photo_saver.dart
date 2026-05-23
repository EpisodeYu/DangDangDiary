import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'original_photo_cache.dart';

/// Result returned by [savePhotoToGallery]. Keeps the call-site free of
/// `saver_gallery` types so the UI layer can stay framework-agnostic and
/// the helper can be unit-tested without pulling the platform plugin in.
class PhotoSaveResult {
  final bool success;
  final String? errorMessage;

  const PhotoSaveResult.success()
      : success = true,
        errorMessage = null;
  const PhotoSaveResult.failure(this.errorMessage) : success = false;
}

/// Save the original (full-resolution) bytes of [photoId] into the system
/// gallery. Reuses [OriginalPhotoCache] so already-cached photos save
/// without an extra network round-trip; cache misses transparently
/// download via the existing presigned-URL path.
///
/// Platform notes:
///   - Android 13+ (`SDK 33+`): no runtime permission required — writes
///     via MediaStore. We still issue a `Permission.photos.request()`
///     when `skipIfExists` is true, but here we pass `false` so writes
///     work without prompting.
///   - Android 10-12 (`SDK 29-32`): MediaStore writes are allowed
///     without `WRITE_EXTERNAL_STORAGE` since scoped storage; no prompt.
///   - Android 9- (`SDK <=28`): requests `Permission.storage` once.
///   - iOS: requests `Permission.photosAddOnly` (NSPhotoLibraryAddUsage
///     in Info.plist).
Future<PhotoSaveResult> savePhotoToGallery(
  int photoId, {
  DateTime? takenAt,
}) async {
  try {
    final permission = await _ensureGalleryPermission();
    if (!permission) {
      return const PhotoSaveResult.failure('未授予保存到相册的权限');
    }

    final file = await OriginalPhotoCache.instance.fetchOriginal(photoId);
    if (!await file.exists()) {
      return const PhotoSaveResult.failure('文件已被清理，请稍后重试');
    }

    final bytes = await file.readAsBytes();
    final filename = _buildFilename(photoId, takenAt);

    final result = await SaverGallery.saveImage(
      bytes,
      name: filename,
      androidRelativePath: 'Pictures/DangDangDiary',
      skipIfExists: false,
    );

    if (result.isSuccess) return const PhotoSaveResult.success();

    final reason = result.errorMessage;
    return PhotoSaveResult.failure(
      (reason != null && reason.isNotEmpty)
          ? reason
          : '保存失败，请检查相册权限',
    );
  } on FileSystemException catch (e) {
    if (kDebugMode) debugPrint('[photoSaver] FS error: $e');
    return const PhotoSaveResult.failure('读取原图失败');
  } catch (e, st) {
    if (kDebugMode) debugPrint('[photoSaver] save failed: $e\n$st');
    final msg = e.toString().toLowerCase();
    if (msg.contains('socket') ||
        msg.contains('timeout') ||
        msg.contains('network') ||
        msg.contains('connection')) {
      return const PhotoSaveResult.failure('网络异常，请稍后重试');
    }
    return const PhotoSaveResult.failure('保存失败，请稍后重试');
  }
}

/// Request the right permission for the current OS. Returns `true` when
/// the platform either grants or doesn't require a permission for our
/// (add-only) save flow.
///
/// - Android Q+ (SDK 29+): MediaStore writes don't need a runtime
///   permission. `Permission.storage.request()` on these versions
///   resolves to `PermissionStatus.denied` *without* showing a prompt,
///   so we deliberately don't fail on `denied` — we still hand the
///   bytes to `saver_gallery` and let MediaStore decide.
/// - Android 9- (SDK <=28): the request maps to legacy
///   `WRITE_EXTERNAL_STORAGE` which actually does prompt.
/// - iOS: requests `Permission.photosAddOnly` (NSPhotoLibraryAddUsage
///   in Info.plist). Both `granted` and `limited` are good enough for
///   add-only writes.
Future<bool> _ensureGalleryPermission() async {
  if (Platform.isAndroid) {
    final status = await Permission.storage.request();
    // On SDK 29+ the request never actually prompts and resolves to
    // `denied`. Treat anything that isn't an explicit
    // `permanentlyDenied` as "let saver_gallery try" — the MediaStore
    // path doesn't depend on the legacy permission and will succeed.
    return !status.isPermanentlyDenied;
  }
  if (Platform.isIOS) {
    final status = await Permission.photosAddOnly.request();
    return status.isGranted || status.isLimited;
  }
  return false;
}

String _buildFilename(int photoId, DateTime? takenAt) {
  final ts = (takenAt ?? DateTime.now()).toLocal();
  final stamp = '${ts.year}${_pad(ts.month)}${_pad(ts.day)}_'
      '${_pad(ts.hour)}${_pad(ts.minute)}${_pad(ts.second)}';
  return 'dangdang_photo_${photoId}_$stamp.jpg';
}

String _pad(int v) => v.toString().padLeft(2, '0');
