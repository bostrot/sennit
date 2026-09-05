import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The configuration that decides whether Weft syncs after a reboot.
///
/// A test over XML and Kotlin source looks like testing a config file, and
/// `sms_manifest_test.dart` explains why that is worth doing for the SMS role.
/// The reasoning is the same here and the failure is quieter still: a receiver
/// registered for the wrong action, or an action registered and then ignored by
/// the handler, produces **no error at all**. Nothing throws, nothing logs, no
/// call fails. The phone simply does not sync until somebody opens the app — a
/// day later, wondering why they missed a message — and there is nothing to
/// attach a debugger to, because the code that would have run never ran.
///
/// What this does *not* establish is that Android delivers the broadcast, that
/// the foreground service is allowed to start at boot, or that the session
/// survives. Those are device facts and they are recorded, with the commands
/// that produced them, in `docs/architecture/notifications.md` under "Coming
/// back after a reboot".
void main() {
  late String manifest;
  late String receiver;
  late String service;

  setUpAll(() {
    String read(String path) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'run from apps/weft, where flutter test puts the working directory',
      );
      return file.readAsStringSync();
    }

    manifest = read('android/app/src/main/AndroidManifest.xml');
    receiver = read(
      'android/app/src/main/kotlin/com/bostrot/weft/sync/SyncBootReceiver.kt',
    );
    service = read(
      'android/app/src/main/kotlin/com/bostrot/weft/sync/WeftSyncService.kt',
    );
  });

  /// The actions a boot receiver has to answer to.
  ///
  /// `QUICKBOOT_POWERON` in both spellings because a number of vendor ROMs send
  /// one of them *instead of* `BOOT_COMPLETED` after their fast-boot shutdown,
  /// which on those phones is the ordinary way the device turns off. An app
  /// listening only for the documented action is never started on them.
  const bootActions = [
    'android.intent.action.BOOT_COMPLETED',
    'android.intent.action.QUICKBOOT_POWERON',
    'com.htc.intent.action.QUICKBOOT_POWERON',
  ];

  group('the boot receiver', () {
    test('holds the permission without which it is never called', () {
      // Declared and normal: granted at install, no prompt. Absent, the
      // `<intent-filter>` below is ignored by the system with no error.
      expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    });

    test('is exported, because the sender is the system', () {
      final block = _receiverBlock(manifest, '.sync.SyncBootReceiver');
      expect(
        block,
        contains('android:exported="true"'),
        reason: 'a non-exported receiver never hears a system broadcast',
      );
    });

    test('is registered for every action a device might send', () {
      final block = _receiverBlock(manifest, '.sync.SyncBootReceiver');
      for (final action in bootActions) {
        expect(
          block,
          contains('android:name="$action"'),
          reason: 'a ROM sending only $action would never start the sync',
        );
      }
    });

    test('the handler answers exactly the actions it is registered for', () {
      // The pair that silently breaks: an action in the manifest and not in the
      // handler is a receiver woken to do nothing; one in the handler and not
      // in the manifest is a branch that can never run.
      for (final action in bootActions) {
        final short = action.split('.').last;
        expect(
          // `BOOT_COMPLETED` is written as `Intent.ACTION_BOOT_COMPLETED`; the
          // two vendor actions have no constant and are string literals.
          receiver.contains(action) || receiver.contains('ACTION_$short'),
          isTrue,
          reason: '$action is registered in the manifest and ignored in Kotlin',
        );
      }
    });

    test('it starts the connection through the service, and only when on', () {
      // Two invariants in one, because they fail into each other. Starting the
      // service is the whole job; doing it unconditionally would turn a
      // background connection on for every user who never asked for one, and a
      // reboot is not consent.
      expect(receiver, contains('WeftSyncService.start(context)'));
      expect(receiver, contains('WeftSyncService.isEnabled(context)'));
      expect(
        receiver.indexOf('isEnabled'),
        lessThan(receiver.indexOf('WeftSyncService.start(context)')),
        reason: 'the toggle has to be read before the service is started',
      );
    });

    test('a refused start is caught rather than crashing the boot', () {
      // Android 12+ can refuse a foreground start outright. An uncaught
      // exception in a boot receiver is a crash dialog on a phone that has just
      // been switched on.
      expect(receiver, contains('catch'));
    });
  });

  group('direct boot', () {
    test('the receiver is not woken before the user has unlocked', () {
      final block = _receiverBlock(manifest, '.sync.SyncBootReceiver');
      // Both halves, because either one alone is the bug. `directBootAware`
      // without `LOCKED_BOOT_COMPLETED` is inert; `LOCKED_BOOT_COMPLETED`
      // without `directBootAware` is never delivered. Together they would wake
      // a process that cannot read the Matrix session, the account keys or the
      // preference saying the connection is wanted — all of which live in
      // credential-protected storage, and must, because the alternative is an
      // E2EE messenger whose long-term keys the OS decrypts before anyone has
      // proved they own the phone.
      expect(block, isNot(contains('directBootAware')));
      expect(block, isNot(contains('LOCKED_BOOT_COMPLETED')));
    });

    test('the reason is written down where the next person will stand', () {
      expect(
        receiver,
        contains('credential-protected'),
        reason:
            'someone will try to add LOCKED_BOOT_COMPLETED; the class comment '
            'is where they will be when they do',
      );
    });
  });

  group('the service it starts', () {
    test('declares the one foreground type still allowed at boot', () {
      // Android 15 forbids starting a `dataSync` foreground service from
      // BOOT_COMPLETED. `specialUse` is not on that list, which is the whole
      // reason this service is typed the way it is — and it needs the matching
      // permission or Android 14+ refuses the start.
      expect(manifest, contains('android:foregroundServiceType="specialUse"'));
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
      );
      expect(manifest, contains('PROPERTY_SPECIAL_USE_FGS_SUBTYPE'));
    });

    test('posts its notification in the same call that starts it', () {
      // A foreground service has roughly ten seconds to call `startForeground`
      // or the system kills it — and at boot, on a cold device, ten seconds is
      // not as long as it sounds. The call has to be in `onStartCommand`, not
      // behind the engine start that follows it.
      final start = service.indexOf('onStartCommand');
      final foreground = service.indexOf('startForeground(', start);
      final daemon = service.indexOf('SyncEngineHolder.startDaemon', start);
      expect(foreground, greaterThan(start));
      expect(
        foreground,
        lessThan(daemon),
        reason: 'the notification must be posted before the Dart engine starts',
      );
    });

    test('it is startForegroundService that is used, not startService', () {
      // From Android 8 a background `startService` throws
      // `IllegalStateException`, and a boot receiver is background.
      expect(service, contains('context.startForegroundService(intent)'));
    });
  });
}

/// The `<receiver>` element declaring [name], as text.
///
/// Sliced rather than parsed: the assertions are about strings Android matches
/// exactly, and an XML parser would let a test pass on a document whose
/// attribute Android reads differently from the parser.
String _receiverBlock(String manifest, String name) {
  final start = manifest.indexOf('android:name="$name"');
  expect(start, greaterThan(-1), reason: '$name is not in the manifest');
  final open = manifest.lastIndexOf('<receiver', start);
  final close = manifest.indexOf('</receiver>', start);
  expect(open, greaterThan(-1));
  expect(close, greaterThan(open));
  return manifest.substring(open, close);
}
