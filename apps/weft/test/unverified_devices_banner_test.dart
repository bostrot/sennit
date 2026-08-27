import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/features/chat/unverified_devices_banner.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The warning that sits above a conversation when something in it is unchecked.
///
/// Its whole value is that it appears in exactly the right cases: a strip over
/// every chat is one nobody reads, and a strip that never appears is the same
/// as not having built it.
void main() {
  Future<int> pump(WidgetTester tester, RoomTrust trust) async {
    var verifyTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(
          body: UnverifiedDevicesBanner(
            trust: trust,
            onVerify: () => verifyTaps++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return verifyTaps;
  }

  testWidgets('an untroubled chat gets no strip at all', (tester) async {
    await pump(tester, RoomTrust.none);

    // Not a collapsed strip or a zero-height box with padding: nothing, so the
    // caller can place it unconditionally and never reason about encryption.
    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(UnverifiedDevicesBanner)), Size.zero);
  });

  testWidgets('an unencrypted room never warns, whatever it contains', (
    tester,
  ) async {
    // SMS is the case in the building: plaintext end to end, and there is no
    // such thing as an unverified device on it. The composer says so; this
    // strip must not double up with a warning it cannot act on.
    await pump(
      tester,
      const RoomTrust(
        encrypted: false,
        unverifiedDevices: 4,
        unverifiedUsers: 2,
        includesOwnDevice: true,
      ),
    );

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('our own unverified device is named as ours, with a way out', (
    tester,
  ) async {
    await pump(
      tester,
      const RoomTrust(
        encrypted: true,
        unverifiedDevices: 1,
        unverifiedUsers: 1,
        includesOwnDevice: true,
      ),
    );

    expect(find.textContaining('One of your own devices'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
  });

  testWidgets('tapping Verify hands off to the one verification flow', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: WeftTheme.build(),
        home: Scaffold(
          body: UnverifiedDevicesBanner(
            trust: const RoomTrust(
              encrypted: true,
              unverifiedDevices: 1,
              unverifiedUsers: 1,
              includesOwnDevice: true,
            ),
            onVerify: () => taps++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Verify'));
    expect(taps, 1);
  });

  testWidgets('somebody else\'s device is stated, not alarmed about', (
    tester,
  ) async {
    // There is nothing this side can do about another person's new phone, and
    // a button that could not fix it would be a button that lies. The same
    // reasoning applies to the colour: an unclearable red bar over every chat
    // with anyone who has not been verified is how a warning stops being read,
    // including the one that can be acted on.
    await pump(
      tester,
      const RoomTrust(
        encrypted: true,
        unverifiedDevices: 1,
        unverifiedUsers: 1,
        includesOwnDevice: false,
      ),
    );

    expect(find.textContaining('has not been verified'), findsOneWidget);
    expect(find.text('Verify'), findsNothing);

    // `.first`: the strip's own Material, not the button's inside it.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(UnverifiedDevicesBanner),
            matching: find.byType(Material),
          )
          .first,
    );
    final colors = WeftTheme.build().colorScheme;
    expect(
      material.color,
      isNot(colors.errorContainer),
      reason: 'a fact about someone else is not an error of yours',
    );
  });

  testWidgets('own devices keep the red, and the button', (tester) async {
    await pump(
      tester,
      const RoomTrust(
        encrypted: true,
        unverifiedDevices: 1,
        unverifiedUsers: 1,
        includesOwnDevice: true,
      ),
    );

    // `.first`: the strip's own Material, not the button's inside it.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(UnverifiedDevicesBanner),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, WeftTheme.build().colorScheme.errorContainer);
    expect(find.text('Verify'), findsOneWidget);
  });

  testWidgets('several devices are counted, and so are the people', (
    tester,
  ) async {
    await pump(
      tester,
      const RoomTrust(
        encrypted: true,
        unverifiedDevices: 3,
        unverifiedUsers: 2,
        includesOwnDevice: false,
      ),
    );

    expect(find.textContaining('3 devices'), findsOneWidget);
    expect(find.textContaining('2 people'), findsOneWidget);
  });

  testWidgets('one person is a person, not "1 people"', (tester) async {
    await pump(
      tester,
      const RoomTrust(
        encrypted: true,
        unverifiedDevices: 8,
        unverifiedUsers: 1,
        includesOwnDevice: false,
      ),
    );

    expect(find.textContaining('someone here'), findsOneWidget);
    expect(find.textContaining('1 people'), findsNothing);
  });
}
