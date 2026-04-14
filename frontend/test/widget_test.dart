import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dangdang_diary/app.dart';

void main() {
  testWidgets('App renders with bottom navigation', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: DangDangDiaryApp()),
    );

    expect(find.text('记录'), findsOneWidget);
    expect(find.text('健康'), findsOneWidget);
    expect(find.text('时间轴'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });
}
