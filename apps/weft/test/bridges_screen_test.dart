import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft_design/weft_design.dart';

void main() {
  // Regression hunt for the on-device crash: popping the bridges screen threw
  // `'dependents.isEmpty': is not true` from InheritedElement.debugDeactivated.
  testWidgets('opening and closing the bridges screen does not throw', (
    tester,
  ) async {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storesProvider.overrideWithValue(stores)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const BridgesScreen(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Bridges'), findsOneWidget);

    // Pop exactly the way the user did.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('open'), findsOneWidget);
  });
}
