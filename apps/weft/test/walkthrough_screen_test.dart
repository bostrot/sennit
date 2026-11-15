import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/billing_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/auth/walkthrough_screen.dart';
import 'package:weft/features/settings/pro_screen.dart';
import 'package:weft/services/billing/entitlements.dart';
import 'package:weft_design/weft_design.dart';

/// The walkthrough after a first sign-in.
///
/// Nothing on it is required, so the two things that have to hold are that it
/// can be left from the first page and that it ends when its pages do — a
/// tour with no way out is the inbox withheld.
void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    SennitEdition edition = SennitEdition.community,
  }) async {
    final done = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sennitEditionProvider.overrideWithValue(edition),
          storeBillingPlatformProvider.overrideWithValue(true),
          billingStoreProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: WalkthroughScreen(onDone: () => done.add('done')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return done;
  }

  testWidgets('can be skipped from the first page', (tester) async {
    final done = await pump(tester);
    expect(find.text('Welcome to Sennit'), findsOneWidget);

    await tester.tap(find.text('Skip the tour'));
    expect(done, ['done']);
  });

  testWidgets('walks every feature, then ends', (tester) async {
    final done = await pump(tester);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();

    const titles = [
      'Bring your other messengers',
      'Add an AI assistant',
      'Or keep it on this device',
      'Let Sennit answer for you',
      'A to-do list that fills itself',
    ];
    for (final title in titles) {
      expect(find.text(title), findsOneWidget);
      expect(done, isEmpty);
      await tester.tap(find.text(title == titles.last ? 'Done' : 'Next'));
      await tester.pumpAndSettle();
    }
    expect(done, ['done']);
  });

  testWidgets('a Pro feature is marked until Pro is unlocked', (tester) async {
    await pump(tester, edition: SennitEdition.store);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    // Bridges are free.
    expect(find.byType(ProBadge), findsNothing);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Add an AI assistant'), findsOneWidget);
    expect(find.byType(ProBadge), findsOneWidget);
  });

  testWidgets('a build that does not charge marks nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Add an AI assistant'), findsOneWidget);
    expect(find.byType(ProBadge), findsNothing);
  });

  testWidgets('says where in the tour a page is', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(find.bySemanticsLabel('Step 1 of 6'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('fits a small phone at the largest text size', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Skip the tour').hitTestable(), findsOneWidget);
  });
}
