import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/original_photo_cache.dart';

/// Shows the cached original of a photo, falling back to the thumbnail while
/// the original is being fetched or if the fetch fails.
///
/// Wire-up notes:
/// - On first build we synchronously check the in-memory index by kicking off
///   [OriginalPhotoCache.fetchOriginal] and await it inside the widget.
/// - While we wait we render the thumbnail so the user always sees something.
/// - Once the file is on disk we switch to an [Image.file] with a tiny fade so
///   the transition is not jarring.
/// - We also listen to [OriginalPhotoCache.instance.revision] so tiles already
///   on screen pick up originals that were just prefetched.
class OriginalPhotoImage extends StatefulWidget {
  final int photoId;
  final String? thumbnailUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Optional decode width hint (in physical pixels) for `Image.file`. Setting
  /// this is critical for the immersive timeline: full-resolution originals
  /// are easily 4000×3000 and decoding them at source size eats ~50 MiB each
  /// in the image cache, evicting every neighbour and forcing re-decodes on
  /// every scroll. Pass roughly `viewportWidth * devicePixelRatio` so the
  /// decoded bitmap matches the painted size.
  final int? decodeCacheWidth;
  final Widget Function(BuildContext context)? errorBuilder;

  const OriginalPhotoImage({
    super.key,
    required this.photoId,
    required this.thumbnailUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.decodeCacheWidth,
    this.errorBuilder,
  });

  @override
  State<OriginalPhotoImage> createState() => _OriginalPhotoImageState();
}

class _OriginalPhotoImageState extends State<OriginalPhotoImage> {
  Future<File>? _future;
  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _kickOff();
  }

  @override
  void didUpdateWidget(covariant OriginalPhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoId != widget.photoId) {
      _future = null;
      _kickOff();
    }
  }

  void _kickOff() {
    _future = OriginalPhotoCache.instance.fetchOriginal(widget.photoId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: OriginalPhotoCache.instance.revision,
      builder: (context, revision, _) {
        if (revision != _lastRevision && _lastRevision != -1) {
          // A prefetch for some other id completed; re-check our own cache
          // state without restarting an in-flight download.
          OriginalPhotoCache.instance
              .getCachedOriginalFile(widget.photoId)
              .then((file) {
            if (!mounted || file == null) return;
            if (_future == null) return;
            // Replace future with resolved file so FutureBuilder swaps in.
            setState(() {
              _future = Future.value(file);
            });
          });
        }
        _lastRevision = revision;

        return FutureBuilder<File>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData) {
              return Image.file(
                snapshot.data!,
                fit: widget.fit,
                width: widget.width,
                height: widget.height,
                cacheWidth: widget.decodeCacheWidth,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, _, stack) =>
                    _fallback(loadingFailed: true),
              );
            }
            return _fallback(loadingFailed: snapshot.hasError);
          },
        );
      },
    );
  }

  Widget _fallback({required bool loadingFailed}) {
    final thumb = widget.thumbnailUrl;
    if (thumb != null && thumb.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: thumb,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        placeholder: (context, _) => Container(color: const Color(0xFFEFE5DD)),
        errorWidget: (context, _, err) => widget.errorBuilder != null
            ? widget.errorBuilder!(context)
            : Container(
                color: const Color(0xFFEFE5DD),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.broken_image_rounded,
                  size: 24,
                  color: Colors.black45,
                ),
              ),
      );
    }
    if (loadingFailed && widget.errorBuilder != null) {
      return widget.errorBuilder!(context);
    }
    return Container(color: const Color(0xFFEFE5DD));
  }
}
