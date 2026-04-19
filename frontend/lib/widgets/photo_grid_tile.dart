import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/timeline.dart';

class PhotoGridTile extends StatelessWidget {
  final TimelinePhoto photo;
  final bool showPetLabel;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const PhotoGridTile({
    super.key,
    required this.photo,
    required this.showPetLabel,
    this.selectionMode = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // Each grid tile is roughly 1/4 of the screen width minus padding —
    // ~90 logical pixels on a typical phone. We pass ONLY one cache
    // dimension so `ResizeImage` keeps the source aspect ratio: setting
    // both `memCacheWidth` and `memCacheHeight` makes
    // `ResizeImagePolicy.exact` (the cached_network_image default) decode
    // every photo as a square, which visibly distorts non-1:1 photos in
    // the grid. The server thumbnails are already capped at 200/400 px on
    // the long side, so capping width here just ensures the fallback
    // (large) tier on legacy rows decodes at a reasonable size without
    // ever stretching the image.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cachePx = (110 * dpr).round().clamp(180, 420);
    // Prefer the grid tier (`thumbnail_sm_url`, ~512 px long side) — its
    // pixel budget is sized so the source short side ≥ a 4-col grid cell
    // on every common DPR (2.0–3.5), which keeps thumbnails crisp instead
    // of relying on paint-time upscaling. The legacy 400 px detail tier
    // is used as fallback when the server hasn't generated the grid tier
    // yet (old rows). Either way, `memCacheWidth` above caps the decoded
    // bitmap to roughly the cell physical size, so RAM usage is the same
    // whichever URL we resolve.
    final url = photo.gridThumbnailUrl;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: const Color(0xFFEFE5DD)),
              if (url.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  memCacheWidth: cachePx,
                  fadeInDuration: const Duration(milliseconds: 120),
                  fadeOutDuration: const Duration(milliseconds: 60),
                  placeholder: (context, _) => Container(
                    color: const Color(0xFFEFE5DD),
                  ),
                  errorWidget: (context, _, err) => Container(
                    color: const Color(0xFFEFE5DD),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      size: 20,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              if (showPetLabel)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          photo.petType == 'cat' ? '🐱' : '🐶',
                          style: const TextStyle(fontSize: 10),
                        ),
                        const SizedBox(width: 2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 56),
                          child: Text(
                            photo.petName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (selectionMode && selected)
                Container(color: Colors.black.withValues(alpha: 0.25)),
              if (selectionMode)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _SelectionCheck(selected: selected),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionCheck extends StatelessWidget {
  final bool selected;
  const _SelectionCheck({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppTheme.primaryColor : Colors.black.withValues(alpha: 0.25),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }
}
