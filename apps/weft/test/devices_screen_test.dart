import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/settings/devices_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/session_fakes.dart';

void main() {
  final seen = DateTime.utc(2026, 8, 18, 9);

  final fixtures = [
    WeftDevice(
      deviceId: 'THISONE',
      displayName: 'Weft on Pixel',
      lastSeenIp: '10.0.0.4',
      lastSeenAt: seen,
      isCurrent: true,
      trust: DeviceTrust.verified,
    ),
    WeftDevice(
      deviceId: 'LAPTOP',
      displayName: 'Weft on laptop',
      lastSeenIp: '203.0.113.9',
      lastSeenAt: seen.subtract(const Duration(days: 2)),
      trust: DeviceTrust.unverified,
    ),
    WeftDevice(
      deviceId: 'OLDPHONE',
      lastSeenAt: seen.subtract(const Duration(days: 400)),
      trust: DeviceTrust.noKeys,
    ),
  ];

  Future<FakeDeviceManager> pump(
    WidgetTester tester, {
    FakeDeviceManager? manager,
  }) async {
    final devices = manager ?? FakeDeviceManager(fixtures);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceManagerProvider.overrideWithValue(devices)],
        child: MaterialApp(
          theme: WeftTheme.build(),
          home: const DevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return devices;
  }

  testWidgets('lists every session with its name, address and trust', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Weft on Pixel'), findsOneWidget);
    expect(find.text('Weft on laptop'), findsOneWidget);
    // No display name: the row is titled with the device id rather than left
    // blank, which would be indistinguishable from a rendering bug.
    expect(find.text('OLDPHONE'), findsOneWidget);

    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('No encryption keys'), findsOneWidget);

    expect(find.textContaining('203.0.113.9'), findsOneWidget);
  });

  testWidgets('the current device is first and the unverified one next', (
    tester,
  ) async {
    await pump(tester);

    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => ((tile.title! as Row).children.first as Flexible).child)
        .map((text) => (text as Text).data)
        .toList();

    expect(titles, ['Weft on Pixel', 'Weft on laptop', 'OLDPHONE']);
  });

  testWidgets('only an unverified device offers Verify', (tester) async {
    await pump(tester);

    // The current device is verified: rename and sign out, nothing else.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Verify'), findsNothing);
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Verify'), findsOneWidget);
  });

  testWidgets('renaming sends the new name to the homeserver', (tester) async {
    final manager = await pump(tester);

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  Work laptop  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(manager.renames, [(deviceId: 'LAPTOP', name: 'Work laptop')]);
    // The list is refetched rather than patched, so what is on screen is what
    // the server says.
    expect(find.text('Work laptop'), findsOneWidget);
  });

  testWidgets('cancelling the rename dialog changes nothing', (tester) async {
    final manager = await pump(tester);

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'never saved');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.renames, isEmpty);
    expect(find.text('Weft on laptop'), findsOneWidget);
  });

  testWidgets('signing out others is confirmed first and spares this one', (
    tester,
  ) async {
    final manager = await pump(tester);

    await tester.tap(find.text('Sign out other devices'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out 2 other devices?'), findsOneWidget);
    expect(manager.signOuts, isEmpty, reason: 'not until it is confirmed');

    await tester.tap(find.text('Sign out others'));
    await tester.pumpAndSettle();

    expect(manager.signOuts, [
      ['LAPTOP', 'OLDPHONE'],
    ]);
    expect(find.text('Weft on Pixel'), findsOneWidget);
    expect(find.text('Weft on laptop'), findsNothing);
  });

  testWidgets('declining the confirmation signs nothing out', (tester) async {
    final manager = await pump(tester);

    await tester.tap(find.text('Sign out other devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.signOuts, isEmpty);
    expect(find.text('Weft on laptop'), findsOneWidget);
  });

  testWidgets('a homeserver that wants the password gets it', (tester) async {
    final manager = await pump(
      tester,
      manager: FakeDeviceManager(fixtures)..demandsReauth = true,
    );

    await tester.tap(find.text('Sign out other devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out others'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm it is you'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(manager.passwordsGiven, ['hunter2']);
    expect(manager.signOuts, [
      ['LAPTOP', 'OLDPHONE'],
    ]);
  });

  testWidgets('backing out of the password prompt is silent, not an error', (
    tester,
  ) async {
    final manager = await pump(
      tester,
      manager: FakeDeviceManager(fixtures)..demandsReauth = true,
    );

    await tester.tap(find.text('Sign out other devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out others'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.passwordsGiven, [null]);
    expect(manager.signOuts, isEmpty);
    // Nothing happened, and saying so would be noise about the user's own
    // decision.
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Weft on laptop'), findsOneWidget);
  });

  testWidgets('an unloadable list says so instead of showing nothing', (
    tester,
  ) async {
    // An empty list and a failed load look identical, and only one of them
    // means "you have no other devices".
    await pump(
      tester,
      manager: FakeDeviceManager(fixtures)
        ..failure = StateError(
          'WeftMatrixSession.initialize() has not '
          'been called',
        ),
    );

    expect(find.textContaining('initialize()'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a refused sign-out explains itself in the server\'s words', (
    tester,
  ) async {
    final manager = FakeDeviceManager(fixtures);
    await pump(tester, manager: manager);

    manager.failure = const DeviceActionException(
      'Your homeserver wants a kind of confirmation Weft cannot show here yet.',
    );

    await tester.tap(find.text('Sign out other devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out others'));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('cannot show here yet'),
      ),
      findsOneWidget,
      reason: 'the exception carries a sentence fit to show',
    );
  });

  group('describeLastSeen', () {
    final now = DateTime.utc(2026, 8, 18, 12);

    test('a missing timestamp is named, not rendered as a blank', () {
      expect(describeLastSeen(null, now: now), 'Last seen unknown');
    });

    test('rounds off inside the window the server itself is vague about', () {
      // The homeserver's own timestamp is allowed to be minutes stale, so a
      // to-the-minute rendering would be precision the number does not have.
      expect(
        describeLastSeen(now.subtract(const Duration(minutes: 2)), now: now),
        'Active now',
      );
      expect(
        describeLastSeen(now.subtract(const Duration(minutes: 40)), now: now),
        '40 minutes ago',
      );
      expect(
        describeLastSeen(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      expect(
        describeLastSeen(now.subtract(const Duration(days: 1)), now: now),
        'Yesterday',
      );
      expect(
        describeLastSeen(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
    });

    test('a clock ahead of the server reads as now, not as the future', () {
      expect(
        describeLastSeen(now.add(const Duration(minutes: 5)), now: now),
        'Active now',
      );
    });

    test('past a week it becomes a date', () {
      expect(
        describeLastSeen(DateTime.utc(2026, 1, 9), now: now),
        contains('2026'),
      );
    });
  });
}
