/// Several shared calendars on the integrations screen.
///
/// The claim is about what is kept: every address the user typed, one per
/// line under the single secret that used to hold one, so an install that had
/// one calendar still has it and gains a way to add the next.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/integrations_screen.dart';

import 'support/golden_harness.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));

  // Tall, because the screen is a lazy list and the calendars are at its end.
  const tall = Size(500, 2400);

  Finder calendarFields() => find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        w.decoration?.labelText == en.integrationsCalendarUrlField,
  );

  testWidgets('a stored address shows as one field, and more can be added', (
    tester,
  ) async {
    final stores = WeftStores.inMemory()
      ..calendarIcsUrl = 'https://cal.example/work.ics';
    await pumpWeft(
      tester,
      const IntegrationsScreen(),
      size: tall,
      stores: stores,
    );

    expect(calendarFields(), findsOneWidget);
    // One calendar has nothing to remove but its own text.
    expect(find.byTooltip(en.integrationsCalendarRemove), findsNothing);

    await tester.tap(find.text(en.integrationsCalendarAdd));
    await tester.pump();
    expect(calendarFields(), findsNWidgets(2));

    await tester.enterText(
      calendarFields().last,
      'webcal://cal.example/home.ics',
    );
    await tester.tap(find.text(en.commonSave));
    await tester.pumpAndSettle();

    expect(
      stores.calendarIcsUrl,
      'https://cal.example/work.ics\nwebcal://cal.example/home.ics',
    );
  });

  testWidgets('removing a calendar keeps the others', (tester) async {
    final stores = WeftStores.inMemory()
      ..calendarIcsUrl =
          'https://cal.example/work.ics\nhttps://cal.example/home.ics';
    await pumpWeft(
      tester,
      const IntegrationsScreen(),
      size: tall,
      stores: stores,
    );

    expect(calendarFields(), findsNWidgets(2));
    await tester.tap(find.byTooltip(en.integrationsCalendarRemove).first);
    await tester.pump();
    expect(calendarFields(), findsOneWidget);

    await tester.tap(find.text(en.commonSave));
    await tester.pumpAndSettle();
    expect(stores.calendarIcsUrl, 'https://cal.example/home.ics');
  });
}
