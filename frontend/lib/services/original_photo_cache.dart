import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'photo_service.dart';

/// Maximum disk budget for the original-photo cache, in bytes.
const int _defaultMaxBytes = 1024 * 1024 * 1024; // 1 GiB

/// Filename prefix for photo-id bound cache entries.
const String _photoPrefix = 'photo_';

/// Filename prefix for upload-time pending entries.
const String _pendingPrefix = 'pending_';

/// Eviction low-water mark: after an over-quota eviction we try to stay at
/// roughly 90% of [_defaultMaxBytes] so the next insert doesn't trigger
/// another scan immediately.
const double _evictLowWaterRatio = 0.9;

/// Single metadata record stored in the persisted index.
class _CacheEntry {
  final String key; // 'photo_<id>' or 'pending_<token>'
  final int sizeBytes;
  DateTime lastAccess;

  _CacheEntry({
    required this.key,
    required this.sizeBytes,
    required this.lastAccess,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'size': sizeBytes,
        'last_access': lastAccess.millisecondsSinceEpoch,
      };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) {
    return _CacheEntry(
      key: json['key'] as String,
      sizeBytes: json['size'] as int,
      lastAccess: DateTime.fromMillisecondsSinceEpoch(
        json['last_access'] as int,
      ),
    );
  }
}

/// Persistent on-disk cache for full-resolution pet photos.
///
/// Responsibilities:
/// - Pre-upload caching: the record screen writes the compressed JPEG here
///   before the multipart upload begins, so the very same bytes can be reused
///   once the server assigns a photo id.
/// - Post-download caching: the immersive timeline and the full-screen viewer
///   ask [fetchOriginal] for a `photo_id`. Hit → return the on-disk file.
///   Miss → call [PhotoService.getOriginalUrl] for a fresh presigned URL,
///   download the bytes, write atomically, update the LRU index.
/// - 1 GiB LRU quota: on every write we re-check total usage and drop the
///   oldest entries (pending or photo-bound) until we are below 90% of the
///   quota.
///
/// The signed URL returned by the backend is short-lived and therefore never
/// persisted. The cache key is the stable `photo_id` so the file survives app
/// restarts and can be reused across days/weeks.
class OriginalPhotoCache {
  OriginalPhotoCache._();

  static final OriginalPhotoCache instance = OriginalPhotoCache._();

  final PhotoService _photoService = PhotoService();
  final Dio _downloadDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  Directory? _cacheDir;
  File? _indexFile;
  final Map<String, _CacheEntry> _index = {};
  Completer<void>? _initCompleter;

  /// In-flight download dedup — keyed by photo id.
  final Map<int, Future<File>> _inflightDownloads = {};

  /// Photo ids currently being prefetched in the background (fire-and-forget).
  /// We keep a weak record to avoid re-requesting within a short window.
  final Set<int> _prefetching = <int>{};

  /// Notifies listeners (widgets) that the cache state changed — useful for
  /// tiles that want to transparently swap from thumbnail to cached original
  /// after a prefetch completes. The value is a monotonically increasing
  /// counter so equal-to-previous comparisons always rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  int _maxBytes = _defaultMaxBytes;
  bool _saveInProgress = false;
  bool _saveDirty = false;

  /// Override the quota (mainly for tests).
  @visibleForTesting
  void setMaxBytesForTest(int bytes) {
    _maxBytes = bytes;
  }

  Future<void> _ensureInitialized() {
    if (_initCompleter != null) return _initCompleter!.future;
    final completer = Completer<void>();
    _initCompleter = completer;
    _initialize().then(completer.complete).catchError((Object e, StackTrace st) {
      completer.completeError(e, st);
    });
    return completer.future;
  }

  Future<void> _initialize() async {
    final baseDir = await getApplicationSupportDirectory();
    final dir = Directory('${baseDir.path}/original_photo_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    _indexFile = File('${dir.path}/index.json');

    if (await _indexFile!.exists()) {
      try {
        final text = await _indexFile!.readAsString();
        if (text.trim().isNotEmpty) {
          final decoded = json.decode(text) as Map<String, dynamic>;
          final entries = (decoded['entries'] as List<dynamic>?) ?? const [];
          for (final raw in entries) {
            final entry = _CacheEntry.fromJson(raw as Map<String, dynamic>);
            _index[entry.key] = entry;
          }
        }
      } catch (e) {
        debugPrint('[OriginalPhotoCache] failed to load index: $e');
        _index.clear();
      }
    }

    // Reconcile against on-disk state: drop index entries whose files are
    // gone, and forget on-disk orphans.
    await _reconcileWithFilesystem();
  }

  Future<void> _reconcileWithFilesystem() async {
    final dir = _cacheDir!;
    final knownKeys = _index.keys.toSet();
    final seenKeys = <String>{};

    await for (final item in dir.list()) {
      if (item is! File) continue;
      final name = item.uri.pathSegments.last;
      if (name == 'index.json' || name.startsWith('.tmp_')) continue;
      if (!name.startsWith(_photoPrefix) && !name.startsWith(_pendingPrefix)) {
        continue;
      }
      seenKeys.add(name);
      if (!knownKeys.contains(name)) {
        // Orphan file with no index record — delete to reclaim space.
        try {
          await item.delete();
        } catch (_) {}
      } else {
        // Refresh size from actual file in case it differs.
        final size = await item.length();
        final entry = _index[name]!;
        if (entry.sizeBytes != size) {
          _index[name] = _CacheEntry(
            key: entry.key,
            sizeBytes: size,
            lastAccess: entry.lastAccess,
          );
        }
      }
    }

    // Drop index entries whose files disappeared.
    final missing = knownKeys.difference(seenKeys);
    for (final k in missing) {
      _index.remove(k);
    }
    if (missing.isNotEmpty) {
      _scheduleSave();
    }
  }

  String _photoKey(int photoId) => '$_photoPrefix$photoId';
  String _pendingKey(String token) => '$_pendingPrefix$token';

  File _fileForKey(String key) => File('${_cacheDir!.path}/$key');

  /// Returns the cached file for [photoId] if one is present on disk.
  /// Touches its LRU timestamp on hit.
  Future<File?> getCachedOriginalFile(int photoId) async {
    await _ensureInitialized();
    final key = _photoKey(photoId);
    final entry = _index[key];
    if (entry == null) return null;
    final file = _fileForKey(key);
    if (!await file.exists()) {
      _index.remove(key);
      _scheduleSave();
      return null;
    }
    entry.lastAccess = DateTime.now();
    _scheduleSave();
    return file;
  }

  /// Local-first read: returns a cached file if present, otherwise downloads
  /// the original from the backend using a fresh presigned URL. Concurrent
  /// callers for the same [photoId] share a single download.
  Future<File> fetchOriginal(int photoId) async {
    await _ensureInitialized();
    final cached = await getCachedOriginalFile(photoId);
    if (cached != null) return cached;

    final existing = _inflightDownloads[photoId];
    if (existing != null) return existing;

    final future = _downloadToCache(photoId);
    _inflightDownloads[photoId] = future;
    try {
      return await future;
    } finally {
      _inflightDownloads.remove(photoId);
    }
  }

  Future<File> _downloadToCache(int photoId) async {
    final url = await _photoService.getOriginalUrl(photoId);
    final tempPath =
        '${_cacheDir!.path}/.tmp_${_photoKey(photoId)}_${DateTime.now().microsecondsSinceEpoch}';
    await _downloadDio.download(url, tempPath);
    final tempFile = File(tempPath);
    final finalFile = _fileForKey(_photoKey(photoId));
    if (await finalFile.exists()) {
      try {
        await finalFile.delete();
      } catch (_) {}
    }
    await tempFile.rename(finalFile.path);
    final size = await finalFile.length();
    _index[_photoKey(photoId)] = _CacheEntry(
      key: _photoKey(photoId),
      sizeBytes: size,
      lastAccess: DateTime.now(),
    );
    _scheduleSave();
    _bumpRevision();
    await _evictIfNeeded();
    return finalFile;
  }

  /// Kick off a download in the background. Safe to call repeatedly; the
  /// in-flight dedup ensures a single request. Never throws.
  void prefetch(int photoId) {
    if (_prefetching.contains(photoId)) return;
    _prefetching.add(photoId);
    Future<void>(() async {
      try {
        await _ensureInitialized();
        final cached = await getCachedOriginalFile(photoId);
        if (cached != null) return;
        await fetchOriginal(photoId);
      } catch (e) {
        debugPrint('[OriginalPhotoCache] prefetch($photoId) failed: $e');
      } finally {
        _prefetching.remove(photoId);
      }
    });
  }

  /// Copy [source] into the cache under a new pending token. The compressed
  /// JPEG the record screen produces lives in the OS temp dir and may be
  /// cleaned out by the OS at any moment; copying it here guarantees we can
  /// reuse the same bytes once the upload succeeds.
  Future<String> cacheUploadSource(File source) async {
    await _ensureInitialized();
    final token = _generateToken();
    final key = _pendingKey(token);
    final dest = _fileForKey(key);
    await source.copy(dest.path);
    final size = await dest.length();
    _index[key] = _CacheEntry(
      key: key,
      sizeBytes: size,
      lastAccess: DateTime.now(),
    );
    _scheduleSave();
    await _evictIfNeeded();
    return token;
  }

  /// Promote a pending entry to a photo-id bound entry. If [token] is no
  /// longer cached (evicted or never inserted) this is a no-op.
  Future<void> bindPendingToPhoto(String token, int photoId) async {
    await _ensureInitialized();
    final srcKey = _pendingKey(token);
    final srcEntry = _index[srcKey];
    if (srcEntry == null) return;
    final srcFile = _fileForKey(srcKey);
    if (!await srcFile.exists()) {
      _index.remove(srcKey);
      _scheduleSave();
      return;
    }
    final dstKey = _photoKey(photoId);
    final dstFile = _fileForKey(dstKey);
    if (await dstFile.exists()) {
      try {
        await dstFile.delete();
      } catch (_) {}
    }
    await srcFile.rename(dstFile.path);
    _index.remove(srcKey);
    _index[dstKey] = _CacheEntry(
      key: dstKey,
      sizeBytes: srcEntry.sizeBytes,
      lastAccess: DateTime.now(),
    );
    _scheduleSave();
    _bumpRevision();
  }

  /// Remove a pending entry (e.g., user cancelled the upload). If the token is
  /// unknown we silently ignore.
  Future<void> releasePending(String token) async {
    await _ensureInitialized();
    final key = _pendingKey(token);
    final entry = _index.remove(key);
    if (entry == null) return;
    final file = _fileForKey(key);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _scheduleSave();
  }

  /// Drop a cached original after the photo has been deleted from the server.
  Future<void> removePhoto(int photoId) async {
    await _ensureInitialized();
    final key = _photoKey(photoId);
    final entry = _index.remove(key);
    if (entry == null) return;
    final file = _fileForKey(key);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _scheduleSave();
    _bumpRevision();
  }

  /// Current on-disk usage in bytes across all cached entries.
  int get totalBytes =>
      _index.values.fold<int>(0, (sum, e) => sum + e.sizeBytes);

  Future<void> _evictIfNeeded() async {
    if (totalBytes <= _maxBytes) return;
    final target = (_maxBytes * _evictLowWaterRatio).floor();
    final entries = _index.values.toList()
      ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
    var used = totalBytes;
    for (final entry in entries) {
      if (used <= target) break;
      final file = _fileForKey(entry.key);
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      _index.remove(entry.key);
      used -= entry.sizeBytes;
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_saveInProgress) {
      _saveDirty = true;
      return;
    }
    _saveInProgress = true;
    Future<void>.microtask(() async {
      try {
        do {
          _saveDirty = false;
          await _persistIndex();
        } while (_saveDirty);
      } finally {
        _saveInProgress = false;
      }
    });
  }

  Future<void> _persistIndex() async {
    final file = _indexFile;
    if (file == null) return;
    try {
      final payload = {
        'version': 1,
        'entries': _index.values.map((e) => e.toJson()).toList(),
      };
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json.encode(payload));
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[OriginalPhotoCache] failed to persist index: $e');
    }
  }

  void _bumpRevision() {
    revision.value = revision.value + 1;
  }

  String _generateToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(9, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// For tests only. Waits for any pending save microtask to finish so tests
  /// can deterministically inspect the on-disk index before tearing down.
  @visibleForTesting
  Future<void> flushForTest() async {
    // Yield once so a just-scheduled microtask starts, then keep yielding
    // until no save is in flight. Bounded to guard against pathological
    // stalls.
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (!_saveInProgress && !_saveDirty) return;
    }
  }

  /// For tests only.
  @visibleForTesting
  Future<void> resetForTest() async {
    await flushForTest();
    _inflightDownloads.clear();
    _prefetching.clear();
    _index.clear();
    _initCompleter = null;
    _cacheDir = null;
    _indexFile = null;
    _saveInProgress = false;
    _saveDirty = false;
    _maxBytes = _defaultMaxBytes;
  }
}
