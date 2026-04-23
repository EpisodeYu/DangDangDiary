import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/theme.dart';

/// Small monochrome brand mark, sized for AppBar titles / lead slots.
///
/// Uses `logo_mono.svg` which is drawn with `currentColor`, so the [color]
/// parameter (defaults to [AppTheme.primaryColor]) takes effect through the
/// `colorFilter` pipeline.
class BrandMark extends StatelessWidget {
  final double size;
  final Color? color;

  const BrandMark({super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/brand/logo_mono.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? AppTheme.primaryColor,
        BlendMode.srcIn,
      ),
    );
  }
}
