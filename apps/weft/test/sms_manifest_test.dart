import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The manifest entries the default-SMS-app role is gated on.
///
/// A test over XML looks like testing a config file, and normally would be. It
/// is here because of *how* this configuration fails: Android decides whether
/// Weft is eligible for the role by looking for the complete set — two
/// receivers, the respond-via-message service, an `ACTION_SENDTO` filter and
/// four permissions — and an app missing any one of them simply never appears
/// in the system's "Default SMS app" list. There is no error, no exception, no
/// log line and no failed call. The feature is absent, on a device, with
/// nothing to attach a debugger to.
///
/// Every string below is one Android reads by exact match, and each is spelled
/// in exactly one other place.
void main() {
  late String manifest;

  setUpAll(() {
    final file = File('android/app/src/main/AndroidManifest.xml');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'run from apps/weft, where flutter test puts the working directory',
    );
    manifest = file.readAsStringSync();
  });

  test('declares every permission the role requires', () {
    for (final permission in const [
      'android.permission.READ_SMS',
      'android.permission.SEND_SMS',
      'android.permission.RECEIVE_SMS',
      'android.permission.RECEIVE_MMS',
    ]) {
      expect(
        manifest,
        contains('android:name="$permission"'),
        reason: '$permission missing makes Weft ineligible with no error',
      );
    }
  });

  test('declares the SMS_DELIVER receiver, guarded by BROADCAST_SMS', () {
    expect(manifest, contains('android:name=".sms.SmsReceiver"'));
    expect(
      manifest,
      contains('android.provider.Telephony.SMS_DELIVER'),
      reason:
          'SMS_RECEIVED is the read-only broadcast every app gets; the '
          'default app is told about a message through SMS_DELIVER alone',
    );
    expect(
      manifest,
      contains('android:permission="android.permission.BROADCAST_SMS"'),
      reason: 'without it any installed app can forge an inbound message',
    );
  });

  test('declares the WAP_PUSH_DELIVER receiver for MMS', () {
    expect(manifest, contains('android:name=".sms.MmsReceiver"'));
    expect(manifest, contains('android.provider.Telephony.WAP_PUSH_DELIVER'));
    expect(manifest, contains('application/vnd.wap.mms-message'));
    expect(
      manifest,
      contains('android:permission="android.permission.BROADCAST_WAP_PUSH"'),
    );
  });

  test('declares the respond-via-message service', () {
    expect(manifest, contains('android:name=".sms.HeadlessSmsSendService"'));
    expect(manifest, contains('android.intent.action.RESPOND_VIA_MESSAGE'));
    expect(
      manifest,
      contains(
        'android:permission="android.permission.SEND_RESPOND_VIA_MESSAGE"',
      ),
    );
  });

  test('accepts ACTION_SENDTO on all four telephony schemes', () {
    expect(manifest, contains('android.intent.action.SENDTO'));
    for (final scheme in const ['sms', 'smsto', 'mms', 'mmsto']) {
      expect(
        manifest,
        contains('android:scheme="$scheme"'),
        reason:
            'callers are inconsistent about which of the four they use, '
            'and the resolver does not treat them as synonyms',
      );
    }
  });

  test('the send-status receiver is not exported', () {
    // Its only legitimate sender is this app's own PendingIntent. An exported
    // one lets any app on the device fake a delivery report.
    expect(
      manifest,
      contains(
        '<receiver\n'
        '            android:name=".sms.SmsStatusReceiver"\n'
        '            android:exported="false"/>',
      ),
    );
  });
}
