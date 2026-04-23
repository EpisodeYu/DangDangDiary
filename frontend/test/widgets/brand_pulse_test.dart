// ignore_for_file: depend_on_referenced_packages
import 'package:dangdang_diary/widgets/brand_pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('BrandPulse opacity oscillates between 0.5 and 1.0',
      (tester) async {
    await tester.pumpWidget(_host(const BrandPulse()));

    final values = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final opacity = tester.widget<Opacity>(find.byType(Opacity));
      values.add(opacity.opacity);
    }

    expect(
      values.every((v) => v >= 0.5 - 0.001 && v <= 1.0 + 0.001),
      isTrue,
      reason: 'Expected opacities in [0.5, 1.0], got $values',
    );
    // At least one near-min and one near-max frame over a full cycle.
    expect(values.any((v) => v < 0.6), isTrue,
        reason: 'Missed a low-opacity frame: $values');
    expect(values.any((v) => v > 0.9), isTrue,
        reason: 'Missed a high-opacity frame: $values');
  });

  testWidgets('BrandPulse mounts and unmounts without dangling ticker',
      (tester) async {
    await tester.pumpWidget(_host(const BrandPulse()));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(_host(const SizedBox()));
  });
}
