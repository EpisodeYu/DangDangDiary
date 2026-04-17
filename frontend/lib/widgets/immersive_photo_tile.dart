import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/timeline.dart';

/// Single-row photo tile used in the immersive timeline mode.
///
/// Each tile takes the full width of the list and keeps the source aspect ratio
/// so no part of the photo gets cropped. A pet-name badge can be overlaid when
/// browsing multiple pets at once.
class ImmersivePhotoTile extends StatelessWidget {
  final TimelinePhoto photo;
  final bool showPetLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ImmersivePhotoTile({
    super.key,
    required this.photo,
    required this.showPetLabel,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.bottomLeft,
            children: [
              if (photo.thumbnailUrl.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: photo.thumbnailUrl,
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  placeholder: (context, _) => const _Placeholder(),
                  errorWidget: (context, _, err) => const _ErrorTile(),
                )
              else
                const _ErrorTile(),
              if (showPetLabel)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          photo.petType == 'cat' ? '🐱' : '🐶',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 120),
                          child: Text(
                            photo.petName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(color: const Color(0xFFEFE5DD)),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        color: const Color(0xFFEFE5DD),
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          size: 32,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
