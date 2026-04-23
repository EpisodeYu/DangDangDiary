// ignore_for_file: depend_on_referenced_packages
import 'package:dangdang_diary/config/theme.dart';
import 'package:dangdang_diary/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('BrandMark defaults to AppTheme.primaryColor via srcIn',
      (tester) async {
    await tester.pumpWidget(_host(const BrandMark()));

    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      picture.colorFilter,
      ColorFilter.mode(AppTheme.primaryColor, BlendMode.srcIn),
    );
  });

  testWidgets('BrandMark respects custom color override', (tester) async {
    await tester.pumpWidget(_host(const BrandMark(color: Colors.black)));

    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      picture.colorFilter,
      const ColorFilter.mode(Colors.black, BlendMode.srcIn),
    );
  });

  testWidgets('BrandMark applies size to SvgPicture', (tester) async {
    await tester.pumpWidget(_host(const BrandMark(size: 42)));
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(picture.width, 42);
    expect(picture.height, 42);
  });
}
