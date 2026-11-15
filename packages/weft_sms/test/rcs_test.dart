import 'package:test/test.dart';
import 'package:weft_sms/weft_sms.dart';

/// What the messaging role costs in RCS.
///
/// The screen that asks for the role listed everything it takes — every
/// incoming message, sole write access to the message store, the "send a
/// message" action — and left out the one consequence the user cannot undo by
/// reading: RCS stops working on the phone. Android has no RCS API for a
/// third-party app, Google Messages speaks RCS only while it is the default,
/// and so taking the role does not move RCS to Sennit, it ends it. A user who
/// finds that out afterwards has lost their group chats to green SMS with no
/// warning at all.
void main() {
  group('rcsStanding', () {
    RcsStanding standing({
      bool supported = true,
      bool sennitIsDefault = false,
      String? defaultPackage,
    }) => rcsStanding(
      supported: supported,
      sennitIsDefault: sennitIsDefault,
      defaultPackage: defaultPackage,
    );

    test('a device with no SMS has no RCS question to answer', () {
      expect(
        standing(supported: false, defaultPackage: kGoogleMessagesPackage),
        RcsStanding.unavailable,
      );
    });

    test('Google Messages holding the role means RCS is working', () {
      expect(
        standing(defaultPackage: kGoogleMessagesPackage),
        RcsStanding.withGoogleMessages,
      );
    });

    test('Sennit holding the role means SMS and MMS only', () {
      expect(
        standing(sennitIsDefault: true, defaultPackage: 'com.bostrot.weft'),
        RcsStanding.offForSennit,
      );
    });

    test('another third-party app is the same position Sennit would be in', () {
      expect(standing(defaultPackage: 'com.textra'), RcsStanding.offForOther);
      expect(standing(defaultPackage: null), RcsStanding.offForOther);
    });
  });

  group('takingRoleEndsRcs', () {
    test('is true only where RCS is plausibly on right now', () {
      expect(takingRoleEndsRcs(kGoogleMessagesPackage), isTrue);
    });

    test('taking the role from another SMS app costs no RCS', () {
      // Warning here too would teach the user to click through the warning
      // that matters.
      expect(takingRoleEndsRcs('com.textra'), isFalse);
      expect(takingRoleEndsRcs('org.fossify.messages'), isFalse);
      expect(takingRoleEndsRcs(null), isFalse);
      expect(takingRoleEndsRcs(''), isFalse);
    });
  });

  group('messagingAppName', () {
    test('names the apps a phone is likely to be holding', () {
      expect(messagingAppName(kGoogleMessagesPackage), 'Google Messages');
      expect(
        messagingAppName('com.samsung.android.messaging'),
        'Samsung Messages',
      );
    });

    test('an app nobody here has heard of keeps its package id', () {
      // Ugly, and actionable: the user can find it in Android's settings by
      // exactly this string. A made-up friendly name could not be found at all.
      expect(messagingAppName('com.example.sms'), 'com.example.sms');
    });

    test('nothing holding the role is nothing to name', () {
      expect(messagingAppName(null), isNull);
      expect(messagingAppName('   '), isNull);
    });
  });
}
