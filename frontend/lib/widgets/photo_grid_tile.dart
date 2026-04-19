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
    // ~90 logical pixels on a typical phone. Decoding the 400×400 server
    // thumbnail at that physical size (DPR 3 → ~270 px) keeps each entry
    // tiny in the image cache so dozens of tiles stay warm and don't get
    // evicted (and re-decoded) as the user scrolls.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cachePx = (110 * dpr).round().clamp(180, 420);
    // Prefer the small (~200 px) tier when available — it decodes to
    // roughly a quarter of the bytes of the standard thumbnail, which is
    // what makes 4-col scrolling feel like the system photo album. The
    // server returns an empty string for legacy rows, in which case the
    // model's `gridThumbnailUrl` falls back to the larger tier.
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
                  memCacheHeight: cachePx,
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
