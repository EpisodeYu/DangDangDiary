import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../config/theme.dart';
import '../../providers/pet_provider.dart';
import '../../providers/timeline_provider.dart';
import '../../services/original_photo_cache.dart';
import '../../services/photo_saver.dart';
import '../../services/photo_service.dart';
import '../../utils/api_error.dart';
import '../../widgets/photo_info_dialog.dart';

/// How many neighbors on either side of the current page to prefetch.
const int _viewerPrefetchRadius = 2;

class PhotoViewerScreen extends ConsumerStatefulWidget {
  final int initialPhotoId;
  const PhotoViewerScreen({super.key, required this.initialPhotoId});

  @override
  ConsumerState<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;

  /// Cache the fetch future per photo id so scrolling left/right doesn't kick
  /// off duplicate network calls for pages we already started fetching.
  final Map<int, Future<File>> _futureCache = {};

  @override
  void initState() {
    super.initState();
    final state = ref.read(timelineProvider);
    _currentIndex = state.orderedPhotoIds.indexOf(widget.initialPhotoId);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchNeighbors();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<File> _getFile(int photoId) {
    return _futureCache.putIfAbsent(
      photoId,
      () => OriginalPhotoCache.instance.fetchOriginal(photoId),
    );
  }

  /// Kick off background downloads for pages within [_viewerPrefetchRadius]
  /// of [_currentIndex]. Safe to call on every page change.
  void _prefetchNeighbors() {
    final ids = ref.read(timelineProvider).orderedPhotoIds;
    if (ids.isEmpty) return;
    final start =
        (_currentIndex - _viewerPrefetchRadius).clamp(0, ids.length - 1);
    final end =
        (_currentIndex + _viewerPrefetchRadius).clamp(0, ids.length - 1);
    for (var i = start; i <= end; i++) {
      if (i == _currentIndex) continue;
      OriginalPhotoCache.instance.prefetch(ids[i]);
    }
  }

  Future<void> _onLongPress(int photoId) async {
    final photo = ref.read(timelineProvider).photoMap[photoId];
    if (photo == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详细信息'),
              onTap: () => Navigator.pop(ctx, 'info'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('保存到相册'),
              onTap: () => Navigator.pop(ctx, 'save'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppTheme.errorColor),
              title: const Text(
                '删除',
                style: TextStyle(color: AppTheme.errorColor),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'info':
        await showPhotoInfoDialog(context, photo);
        break;
      case 'save':
        _showSnack('正在保存...');
        final result =
            await savePhotoToGallery(photo.id, takenAt: photo.takenAt);
        if (!mounted) return;
        _showSnack(
          result.success ? '已保存到相册' : (result.errorMessage ?? '保存失败'),
        );
        break;
      case 'delete':
        final confirmed = await _confirmDelete();
        if (!mounted || confirmed != true) return;
        await _deletePhoto(photoId);
        break;
    }
  }

  Future<bool?> _confirmDelete() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定删除这张照片吗？'),
        content: const Text('删除后不可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePhoto(int photoId) async {
    try {
      await PhotoService().deletePhoto(photoId);
      if (!mounted) return;
      ref.read(timelineProvider.notifier).removePhotos([photoId]);
      _futureCache.remove(photoId);
      final remaining = ref.read(timelineProvider).orderedPhotoIds;
      _showSnack('已删除');
      if (remaining.isEmpty) {
        Navigator.of(context).pop();
      }
    } on DioException catch (e) {
      if (!mounted) return;
      if (isPermissionError(e)) {
        // Opt Step 4: pull the fresh role silently before next attempt.
        ref.read(petListProvider.notifier).silentRefresh();
        _showSnack('权限已更新，请重试');
      } else {
        _showSnack(_deleteErrorMessage(e));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnack('删除失败，请稍后重试');
    }
  }

  String _deleteErrorMessage(DioException e) {
    // Permission errors are handled before this is called; this only
    // formats non-permission failures.
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      return (data['message'] as String?) ?? '删除失败，请稍后重试';
    }
    return '删除失败，请稍后重试';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(timelineProvider);
    final ids = state.orderedPhotoIds;

    if (ids.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      );
    }

    if (_currentIndex >= ids.length) {
      _currentIndex = ids.length - 1;
    }

    final total = ids.length;
    final currentId = ids[_currentIndex];
    final photo = state.photoMap[currentId];
    final titleText = photo == null
        ? ''
        : '${photo.takenAt.year}-${photo.takenAt.month.toString().padLeft(2, '0')}-${photo.takenAt.day.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              titleText,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (photo != null)
              Text(
                '${photo.petName} · ${_currentIndex + 1}/$total',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: total,
        physics: const BouncingScrollPhysics(),
        onPageChanged: (i) {
          setState(() => _currentIndex = i);
          ref.read(timelineProvider.notifier).ensureNeighborsLoaded(i);
          _prefetchNeighbors();
        },
        itemBuilder: (context, index) {
          final id = ids[index];
          return FutureBuilder<File>(
            future: _getFile(id),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white70),
                  ),
                );
              }
              if (snap.hasError || snap.data == null) {
                return const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 48,
                  ),
                );
              }
              return GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onLongPress: () => _onLongPress(id),
                child: PhotoView(
                  imageProvider: FileImage(snap.data!),
                  heroAttributes: PhotoViewHeroAttributes(tag: 'photo_$id'),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  backgroundDecoration:
                      const BoxDecoration(color: Colors.black),
                  loadingBuilder: (ctx, event) => const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white70),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
