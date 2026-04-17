import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../providers/timeline_provider.dart';
import '../../services/photo_service.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

class PhotoViewerScreen extends ConsumerStatefulWidget {
  final int initialPhotoId;
  const PhotoViewerScreen({super.key, required this.initialPhotoId});

  @override
  ConsumerState<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, Future<String>> _urlCache = {};

  @override
  void initState() {
    super.initState();
    final state = ref.read(timelineProvider);
    _currentIndex = state.orderedPhotoIds.indexOf(widget.initialPhotoId);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<String> _getUrl(int photoId) {
    return _urlCache.putIfAbsent(
      photoId,
      () => ref.read(_photoServiceProvider).getOriginalUrl(photoId),
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
        },
        itemBuilder: (context, index) {
          final id = ids[index];
          return FutureBuilder<String>(
            future: _getUrl(id),
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
                imageProvider: NetworkImage(snap.data!),
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
