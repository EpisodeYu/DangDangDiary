import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Color tokens for skeleton placeholders. Kept faint enough that
/// shimmer animation is the dominant signal (vs. a slab of grey).
const Color _kBase = Color(0xFFF1ECE7);
const Color _kHighlight = Color(0xFFFBF7F3);

/// A single shimmering rounded rectangle. Use this as the building
/// block of every per-screen skeleton layout.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;
  final EdgeInsetsGeometry? margin;
  final BoxShape shape;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 8,
    this.margin,
    this.shape = BoxShape.rectangle,
  });

  const SkeletonBox.circle({
    super.key,
    required double size,
    this.margin,
  })  : width = size,
        height = size,
        radius = 0,
        shape = BoxShape.circle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: _kBase,
        borderRadius: shape == BoxShape.circle ? null : BorderRadius.circular(radius),
        shape: shape,
      ),
    );
  }
}

/// Wrap a tree of [SkeletonBox] widgets with this to make them shimmer
/// in lockstep. One [Shimmer] parent keeps the gradient anchored across
/// the whole skeleton (cheaper + visually consistent vs. shimmering
/// each box independently).
class SkeletonShimmer extends StatelessWidget {
  final Widget child;
  final bool enabled;

  const SkeletonShimmer({
    super.key,
    required this.child,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: _kBase,
      highlightColor: _kHighlight,
      enabled: enabled,
      period: const Duration(milliseconds: 1400),
      child: child,
    );
  }
}

/// Drop-in skeleton for a single horizontally-laid-out list row with
/// an avatar circle on the left and 2 stacked text lines on the right.
/// Matches the cadence of weight / deworming / vaccination tabs.
class SkeletonListRow extends StatelessWidget {
  final double avatarSize;
  final EdgeInsetsGeometry padding;

  const SkeletonListRow({
    super.key,
    this.avatarSize = 40,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          SkeletonBox.circle(size: avatarSize),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SkeletonBox(width: 140, height: 14, radius: 6),
                SizedBox(height: 8),
                SkeletonBox(width: 200, height: 12, radius: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton tailored for the calendar (`SliverGrid`) timeline view: a
/// section title bar followed by N square tiles.
class SkeletonPhotoGrid extends StatelessWidget {
  final int groups;
  final int tilesPerGroup;
  final int crossAxisCount;

  const SkeletonPhotoGrid({
    super.key,
    this.groups = 3,
    this.tilesPerGroup = 8,
    this.crossAxisCount = 4,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (int g = 0; g < groups; g++) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 12, 0, 10),
              child: SkeletonBox(width: 120, height: 16, radius: 6),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: tilesPerGroup,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemBuilder: (_, _) => const SkeletonBox(radius: 6),
            ),
          ],
        ],
      ),
    );
  }
}

/// Skeleton for the immersive (single-column) timeline view: tall
/// rounded photo blocks with a caption line below each.
class SkeletonImmersiveList extends StatelessWidget {
  final int count;
  const SkeletonImmersiveList({super.key, this.count = 3});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (_, _) => const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 260, radius: 14),
              SizedBox(height: 8),
              SkeletonBox(width: 140, height: 12, radius: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for the standard health-tab list (status header + several
/// "history" rows). Used by weight / deworming / vaccination tabs.
class SkeletonHealthList extends StatelessWidget {
  final int rows;
  const SkeletonHealthList({super.key, this.rows = 5});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Container(
            height: 96,
            decoration: BoxDecoration(
              color: _kBase,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const SizedBox(height: 20),
          const SkeletonBox(width: 80, height: 14, radius: 6),
          const SizedBox(height: 12),
          for (int i = 0; i < rows; i++) ...[
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: _kBase,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// Pretty default for "loading a screen we don't have a custom skeleton
/// for yet" — keeps us off `CircularProgressIndicator` everywhere.
class SkeletonGenericList extends StatelessWidget {
  final int rows;
  const SkeletonGenericList({super.key, this.rows = 6});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (int i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Container(
                  height: 64,
                  decoration: BoxDecoration(
                    color: _kBase,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

