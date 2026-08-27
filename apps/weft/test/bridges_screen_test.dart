import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

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

  /// A bridge with nothing bridged through it yet.
  ///
  /// The row exists at all because detection now takes the bot as proof, and
  /// what it says has to match: zero is the normal state of a bridge you have
  /// not signed into, not a fault. "0 bridged chat(s)" read like one.
  group('a bridge that carries nothing yet', () {
    Future<void> pump(WidgetTester tester) async {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            detectedBridgesProvider.overrideWithValue(const [
              DetectedBridge(
                network: ChatNetwork.discord,
                botUserId: '@discordbot:example.org',
              ),
            ]),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: const BridgesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('is listed', (tester) async {
      await pump(tester);
      expect(find.text('Discord'), findsOneWidget);
    });

    testWidgets('says so in words, not as a count of zero', (tester) async {
      await pump(tester);
      expect(
        find.textContaining('No chats bridged yet'),
        findsOneWidget,
        reason: 'the row is an invitation to sign in, not a broken bridge',
      );
      expect(find.textContaining('0 bridged'), findsNothing);
    });

    testWidgets('offers the sign-in its bot makes possible', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });
  });
}
