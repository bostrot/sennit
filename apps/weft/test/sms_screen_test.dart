import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/data/sms_chat_repository.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft/features/settings/sms_screen.dart';
import 'package:weft/services/sms/sms_platform.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_sms/weft_sms.dart';

import 'support/sms_fixtures.dart';

/// The role request, which is the only thing in Weft that hands another program
/// a decision this consequential and then has to live with either answer.
///
/// Every assertion here is about the decline. The grant path is Android's own
/// dialog and a `start()` that `sms_repository_test.dart` already covers; what
/// is easy to get wrong — and what this screen exists for — is the state
/// afterwards, where a user who said no must find an app that works and a
/// sentence saying nothing happened, rather than an error, a retry nag, or an
/// SMS network half-present in the inbox.
void main() {
  late FakeSmsChannel channel;
  late SmsChatRepository repository;

  setUp(() {
    channel = FakeSmsChannel();
    repository = SmsChatRepository(
      gateway: SmsPlatform(channel: channel.channel),
    );
  });

  tearDown(() async {
    await repository.dispose();
    channel.dispose();
  });

  /// The status the phone reports when another app is the default.
  Map<String, Object?> notDefault({String? holder = 'com.android.messaging'}) =>
      {
        'supported': true,
        'isDefault': false,
        'canRequestRole': true,
        'roleAvailable': true,
        'hasPermissions': false,
        'defaultPackage': holder,
      };

  /// The status once Weft holds the role — `canRequestRole` false, because
  /// there is no dialog left to raise.
  const isDefault = {
    'supported': true,
    'isDefault': true,
    'canRequestRole': false,
    'roleAvailable': true,
    'hasPermissions': true,
    'defaultPackage': 'com.bostrot.weft',
  };

  /// Taps a control the RCS section may have pushed below the fold.
  ///
  /// Scrolled to rather than tapped where it sits: with the RCS explanation on
  /// screen the button is past the list's cache extent, so it is not merely off
  /// screen — it has not been built, and `ensureVisible` has nothing to reach.
  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(target, 200);
    } else {
      await tester.ensureVisible(target);
    }
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, {bool present = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsRepositoryProvider.overrideWithValue(present ? repository : null),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const SmsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the plaintext warning is on screen before the offer', (
    tester,
  ) async {
    channel.status = notDefault();
    await repository.start();
    await pump(tester);

    // In the red box, not a footnote: the reason to think twice about the role
    // has to arrive before the button that asks for it.
    expect(find.byType(PrivacyNotice), findsOneWidget);
    expect(find.textContaining('SMS is not encrypted'), findsOneWidget);
    expect(find.text('Make Sennit the SMS app'), findsOneWidget);
  });

  testWidgets('the app that holds the role is named', (tester) async {
    channel.status = notDefault();
    await repository.start();
    await pump(tester);

    // "Weft is not your SMS app" leaves the user hunting. The app in the way is
    // what they can act on — under the name it has in Android's own settings,
    // not the package id the phone reports it by.
    expect(find.textContaining('Messaging holds the role'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('a decline says nothing changed, and is not an error', (
    tester,
  ) async {
    channel.status = notDefault();
    channel.roleOutcome = 'denied';
    await repository.start();
    await pump(tester);

    await tap(tester, 'Make Sennit the SMS app');

    expect(channel.calls, contains('requestRole'));
    expect(find.textContaining('Nothing changed'), findsOneWidget);
    // Not a SnackBar and not a red line: the user chose this, and dressing
    // their choice as a failure is what makes a decline feel like a mistake.
    expect(find.byType(SnackBar), findsNothing);
    // Still offered, because the answer is allowed to change later.
    expect(find.text('Make Sennit the SMS app'), findsOneWidget);
    expect(repository.isReady, isFalse);
    expect(repository.chats, isEmpty);
  });

  testWidgets('a grant switches the screen over and reads the provider', (
    tester,
  ) async {
    channel.status = notDefault();
    await repository.start();
    await pump(tester);

    // The dialog's answer and the role are read separately on the Kotlin side,
    // so the fake flips both the way the phone does.
    channel.roleOutcome = 'granted';
    channel.status = isDefault;
    channel.threads = [smsThreadRow()];
    await tap(tester, 'Make Sennit the SMS app');

    expect(find.text('On'), findsOneWidget);
    // The offer is gone rather than disabled: there is no dialog left to raise.
    expect(find.text('Make Sennit the SMS app'), findsNothing);
    expect(repository.chats, hasLength(1));
  });

  testWidgets('the role without its permissions is called out', (tester) async {
    // Looks healthy and reads empty — the role is Weft's and every provider
    // query comes back with nothing. An inbox that has silently lost its SMS is
    // worse than a sentence saying why.
    channel.status = {
      'supported': true,
      'isDefault': true,
      'canRequestRole': false,
      'hasPermissions': false,
      'defaultPackage': 'com.bostrot.weft',
    };
    await repository.start();
    await pump(tester);

    expect(find.text('On'), findsOneWidget);
    expect(find.textContaining('not the SMS permissions'), findsOneWidget);
  });

  testWidgets('checking again picks up a role granted in Settings', (
    tester,
  ) async {
    channel.status = notDefault();
    await repository.start();
    await pump(tester);

    // Granted outside Weft, which is the case the dialog cannot report.
    channel.status = isDefault;
    channel.threads = [smsThreadRow()];
    await tester.tap(find.byTooltip('Check again'));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
    expect(repository.chats, hasLength(1));
  });

  testWidgets('a phone with no telephony says so and offers nothing', (
    tester,
  ) async {
    channel.status = {'supported': false};
    await repository.start();
    await pump(tester);

    expect(find.text('Not available'), findsOneWidget);
    expect(find.text('Make Sennit the SMS app'), findsNothing);
  });

  /// The RCS consequence, which is the one cost of the role that the user
  /// cannot undo by reading.
  ///
  /// Android has no RCS API for a third-party app: RCS is Google Messages
  /// talking to Google's network, and only while it holds the messaging role.
  /// So taking the role does not move RCS to Sennit, it ends it for the whole
  /// phone — and the screen used to describe everything the role costs except
  /// that. A user who found out afterwards had lost their group chats to green
  /// SMS with no warning at all.
  group('RCS', () {
    /// Google Messages holding the role: the only state where RCS is on.
    Map<String, Object?> withGoogleMessages() =>
        notDefault(holder: kGoogleMessagesPackage);

    testWidgets('says RCS will be turned off before the offer', (tester) async {
      channel.status = withGoogleMessages();
      await repository.start();
      await pump(tester);

      expect(find.textContaining('turn RCS off for the whole phone'), findsOne);
    });

    testWidgets('taking the role asks first, and a no changes nothing', (
      tester,
    ) async {
      channel.status = withGoogleMessages();
      await repository.start();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');
      expect(find.text('This turns RCS off'), findsOne);

      await tester.tap(find.text('Keep RCS'));
      await tester.pumpAndSettle();
      expect(
        channel.calls,
        isNot(contains('requestRole')),
        reason: 'the system dialog must not appear behind a declined warning',
      );
    });

    testWidgets('the warning can be accepted, and then it proceeds', (
      tester,
    ) async {
      channel.status = withGoogleMessages();
      await repository.start();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');
      await tester.tap(find.text('Turn RCS off and continue'));
      await tester.pumpAndSettle();

      expect(channel.calls, contains('requestRole'));
    });

    testWidgets('taking it from an app with no RCS raises no warning', (
      tester,
    ) async {
      // Warning here too would be warning about nothing, and teaches the user
      // to click through the warning that matters.
      channel.status = notDefault(holder: 'com.textra');
      await repository.start();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');

      expect(find.text('This turns RCS off'), findsNothing);
      expect(channel.calls, contains('requestRole'));
      expect(find.textContaining('RCS is already off'), findsOne);
    });

    testWidgets('holding the role says the phone has no RCS, and why', (
      tester,
    ) async {
      channel.status = isDefault;
      await repository.start();
      await pump(tester);

      expect(find.textContaining('no RCS'), findsOne);
      expect(
        find.textContaining('no RCS API for a third-party'),
        findsOne,
        reason: 'a missing feature and an impossible one read differently',
      );
    });

    testWidgets('the way back out is offered, and opens Android settings', (
      tester,
    ) async {
      // No API gives a role up, so without this the role is a one-way door —
      // and it is a door with a cost.
      channel.status = isDefault;
      await repository.start();
      await pump(tester);

      await tap(tester, 'Choose a different SMS app');

      expect(channel.calls, contains('openDefaultAppSettings'));
    });

    testWidgets('there is no way back to offer before the role is held', (
      tester,
    ) async {
      channel.status = withGoogleMessages();
      await repository.start();
      await pump(tester);

      expect(find.text('Choose a different SMS app'), findsNothing);
    });

    testWidgets('a device with no telephony says nothing about RCS', (
      tester,
    ) async {
      channel.status = {'supported': false};
      await repository.start();
      await pump(tester);

      expect(find.text('RCS'), findsNothing);
    });
  });

  /// The three answers that are not a grant, which used to be one answer.
  ///
  /// `requestRole` returned a boolean, so a decline, a system refusal and an
  /// activity destroyed under Android's dialog all arrived as `false` and were
  /// rendered with the decline copy. The third of those is the reported bug:
  /// the user tapped "Sennit", the system made Sennit the default SMS app, the
  /// activity was recreated while the dialog was up, and the screen said
  /// *"Nothing changed. Sennit is not your SMS app."* It was not a wording
  /// problem — the screen had no way to know.
  group('outcomes', () {
    testWidgets('a system refusal does not read as a decline', (tester) async {
      channel.status = notDefault();
      // No dialog could be shown: this ROM has no ROLE_SMS, or the build is
      // missing a component the role requires. The user was never asked.
      channel.roleOutcome = 'unavailable';
      await repository.start();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');

      expect(find.textContaining('did not offer the choice'), findsOneWidget);
      expect(
        find.textContaining('Nothing changed'),
        findsNothing,
        reason: 'nobody declined anything; there was no dialog',
      );
    });

    testWidgets('an interrupted request re-reads the role and reports it', (
      tester,
    ) async {
      channel.status = notDefault();
      await repository.start();
      await pump(tester);

      // The bug, exactly: the role *was* granted, and the answer never came
      // back through the call because the activity died holding it.
      channel.roleOutcome = 'interrupted';
      channel.status = isDefault;
      channel.threads = [smsThreadRow()];
      await tap(tester, 'Make Sennit the SMS app');

      expect(find.text('On'), findsOneWidget);
      expect(
        find.textContaining('Nothing changed'),
        findsNothing,
        reason: 'the screen must not deny a role the phone says Sennit holds',
      );
      // And the inbox actually gained the network, rather than merely
      // relabelling the status row.
      expect(repository.chats, hasLength(1));
    });

    testWidgets('an interrupted request that really was not granted says so', (
      tester,
    ) async {
      channel.status = notDefault();
      channel.roleOutcome = 'interrupted';
      await repository.start();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');

      // Not the decline copy either — nobody knows whether they declined. What
      // the screen can honestly say is that the state above was re-read.
      expect(find.textContaining('lost track of that answer'), findsOneWidget);
      expect(find.textContaining('Nothing changed'), findsNothing);
      expect(repository.isReady, isFalse);
    });

    testWidgets('every outcome re-reads the platform, not just a grant', (
      tester,
    ) async {
      channel.status = notDefault();
      channel.roleOutcome = 'denied';
      await repository.start();
      channel.calls.clear();
      await pump(tester);

      await tap(tester, 'Make Sennit the SMS app');

      // The old code refreshed only on a grant, which left the status row, the
      // RCS section and the offer rendering pre-dialog state after every other
      // answer.
      expect(channel.calls, containsAllInOrder(['requestRole', 'getStatus']));
    });

    testWidgets('a phone with no role to give says so before anybody taps', (
      tester,
    ) async {
      // Nothing to offer, so an explanation that waited for a request would
      // never be read: there is no button to make one with.
      channel.status = {
        'supported': true,
        'isDefault': false,
        'canRequestRole': false,
        'roleAvailable': false,
        'hasPermissions': false,
        'defaultPackage': 'com.android.messaging',
      };
      await repository.start();
      await pump(tester);

      expect(find.text('Make Sennit the SMS app'), findsNothing);
      expect(find.textContaining('did not offer the choice'), findsOneWidget);
    });
  });

  testWidgets('a platform with no SMS at all explains itself', (tester) async {
    // What every non-Android build reads, where the provider is null. The copy
    // has to be a fact about the platform rather than a fault.
    await pump(tester, present: false);

    expect(find.byType(SettingsMessage), findsOneWidget);
    expect(find.textContaining('only on Android'), findsOneWidget);
    expect(find.byType(PrivacyNotice), findsNothing);
  });
}
