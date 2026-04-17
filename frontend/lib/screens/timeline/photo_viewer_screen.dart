import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../providers/timeline_provider.dart';
import '../../services/original_photo_cache.dart';

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
              return PhotoView(
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
              );
            },
          );
        },
      ),
    );
  }
}
