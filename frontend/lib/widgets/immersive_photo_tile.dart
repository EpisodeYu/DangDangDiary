import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/timeline.dart';
import 'original_photo_image.dart';

/// Single-row photo tile used in the immersive timeline mode.
///
/// Each tile takes the full width of the list and keeps the source aspect ratio
/// so no part of the photo gets cropped. The original photo (from the
/// persistent cache or fetched on demand) is shown whenever available; the
/// server-side thumbnail is only used as a placeholder while the original is
/// loading for the first time.
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
    final media = MediaQuery.of(context);
    // Decode each original at viewport-width physical pixels instead of full
    // source resolution. A 4000×3000 photo decoded at source costs ~48 MiB in
    // the image cache and pushes every neighbour out, which is exactly why the
    // immersive list felt like it was reloading from scratch on every scroll
    // or tab switch.
    final decodeWidth = (media.size.width * media.devicePixelRatio)
        .round()
        .clamp(720, 1440);
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
              OriginalPhotoImage(
                photoId: photo.id,
                thumbnailUrl: photo.thumbnailUrl,
                fit: BoxFit.fitWidth,
                width: double.infinity,
                decodeCacheWidth: decodeWidth,
                errorBuilder: (context) => const _ErrorTile(),
              ),
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
          Icons.broken_image_rounded,
          size: 32,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
