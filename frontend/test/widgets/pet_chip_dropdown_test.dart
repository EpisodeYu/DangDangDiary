// ignore_for_file: depend_on_referenced_packages
import 'package:dangdang_diary/models/pet.dart';
import 'package:dangdang_diary/widgets/pet_chip_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Pet _pet(int id, String name, {String role = 'owner', String? avatarUrl}) =>
    Pet(
      id: id,
      name: name,
      petType: 'cat',
      avatarUrl: avatarUrl,
      internalReminderEnabled: false,
      externalReminderEnabled: false,
      combinedReminderEnabled: false,
      bathReminderEnabled: false,
      nailTrimReminderEnabled: false,
      groomingReminderEnabled: false,
      isOwner: role == 'owner',
      myRole: role,
      createdAt: '2024-01-01T00:00:00',
      updatedAt: '2024-01-01T00:00:00',
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: child),
      ),
    );

void main() {
  testWidgets(
      'isRecognizing shows spinner and 识别中 label but remains tappable',
      (tester) async {
    final pets = [_pet(1, '咪咪'), _pet(2, '橘子')];
    Pet? chosen;

    await tester.pumpWidget(_host(PetChipDropdown(
      pets: pets,
      selected: null,
      isRecognizing: true,
      wasAutoAssigned: true,
      onChanged: (p) => chosen = p,
    )));

    expect(find.text('识别中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // While recognising the chip must still expose a PopupMenuButton
    // so the user can override the model's pick mid-flight.
    expect(find.byType(PopupMenuButton<int>), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<int>));
    // The chip keeps a spinning CircularProgressIndicator, so
    // `pumpAndSettle` would never settle — step the frame pump
    // manually to let the popup finish its open animation.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('咪咪'), findsOneWidget);
    expect(find.text('橘子'), findsOneWidget);

    await tester.tap(find.text('橘子').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(chosen, isNotNull);
    expect(chosen!.id, 2);
  });

  testWidgets('no selection renders 选择宠物 and caret, tapping opens menu',
      (tester) async {
    final pets = [_pet(1, '咪咪'), _pet(2, '橘子')];
    Pet? chosen;

    await tester.pumpWidget(_host(PetChipDropdown(
      pets: pets,
      selected: null,
      isRecognizing: false,
      wasAutoAssigned: false,
      onChanged: (p) => chosen = p,
    )));

    expect(find.text('选择宠物'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();

    // Menu shows both pets.
    expect(find.text('咪咪'), findsOneWidget);
    expect(find.text('橘子'), findsOneWidget);

    await tester.tap(find.text('橘子').last);
    await tester.pumpAndSettle();
    expect(chosen, isNotNull);
    expect(chosen!.id, 2);
  });

  testWidgets('selected pet shows its name and picking another pet calls onChanged',
      (tester) async {
    final pets = [_pet(1, '咪咪'), _pet(2, '橘子')];
    Pet? chosen;

    await tester.pumpWidget(_host(PetChipDropdown(
      pets: pets,
      selected: pets[0],
      isRecognizing: false,
      wasAutoAssigned: true,
      onChanged: (p) => chosen = p,
    )));

    // Compact chip renders pet name.
    expect(find.text('咪咪'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();

    // Picking the current selection still fires onChanged (simpler
    // semantics — the parent decides whether to no-op).
    await tester.tap(find.text('橘子').last);
    await tester.pumpAndSettle();
    expect(chosen, isNotNull);
    expect(chosen!.id, 2);
  });

  testWidgets('enabled=false makes the chip non-interactive', (tester) async {
    Pet? chosen;
    final pets = [_pet(1, '咪咪')];

    await tester.pumpWidget(_host(PetChipDropdown(
      pets: pets,
      selected: pets[0],
      isRecognizing: false,
      wasAutoAssigned: true,
      enabled: false,
      onChanged: (p) => chosen = p,
    )));

    // No PopupMenuButton → tapping does nothing.
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    await tester.tap(find.text('咪咪'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
  });

  testWidgets('empty pet list disables the chip even when enabled=true',
      (tester) async {
    Pet? chosen;

    await tester.pumpWidget(_host(PetChipDropdown(
      pets: const [],
      selected: null,
      isRecognizing: false,
      wasAutoAssigned: false,
      onChanged: (p) => chosen = p,
    )));

    expect(find.text('选择宠物'), findsOneWidget);
    // No PopupMenuButton wired up when there's nothing to choose.
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    await tester.tap(find.text('选择宠物'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
  });
}
