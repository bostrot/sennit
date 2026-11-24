import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' show MatrixException;
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/delete_account_screen.dart';
import 'package:weft/services/account/account_deletion.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// A bridge with a fixed set of logins, recording what was signed out.
class _Bridge implements BridgeLoginBackend {
  _Bridge(this.ids, {this.fails = false});

  final List<String> ids;
  final bool fails;
  final List<String> loggedOut = [];
  bool disposed = false;

  @override
  Future<BridgeWhoami> whoami() async {
    if (fails) throw const BridgeException('bridge did not answer');
    return BridgeWhoami(
      logins: [
        for (final id in ids)
          BridgeLogin(id: id, state: BridgeLoginState.connected),
      ],
    );
  }

  @override
  Future<void> logout(String loginId) async => loggedOut.add(loginId);

  @override
  void dispose() => disposed = true;

  @override
  Future<List<BridgeLoginFlow>> loginFlows() => throw UnimplementedError();

  @override
  Future<LoginStep> startLogin(String flowId, {String? reloginId}) =>
      throw UnimplementedError();

  @override
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) => throw UnimplementedError();

  @override
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) => throw UnimplementedError();

  @override
  Future<void> cancelLogin(String loginId) async {}

  @override
  bool get supportsCookies => false;

  @override
  bool get acceptsUnlistedFlows => false;
}

/// Records the order the deletion did things in.
class _Run {
  final List<String> log = [];
  AccountReauth? reauth;
}

void main() {
  group('AccountDeletion', () {
    test(
      'signs out every login on every bridge, and goes on past a failure',
      () async {
        final whatsapp = _Bridge(['wa-1', 'wa-2']);
        final broken = _Bridge(['x'], fails: true);
        final signal = _Bridge(['sig']);
        final deletion = AccountDeletion(
          bridges: () async => [
            (network: 'WhatsApp', backend: whatsapp),
            (network: 'Telegram', backend: broken),
            (network: 'Signal', backend: signal),
          ],
          deactivate: (_) async {},
          wipe: () async {},
        );

        final report = await deletion.signOutBridges();

        expect(whatsapp.loggedOut, ['wa-1', 'wa-2']);
        expect(signal.loggedOut, ['sig']);
        expect(report.signedOut, 3);
        expect(report.failed, ['Telegram']);
        expect(
          [whatsapp, broken, signal].every((bridge) => bridge.disposed),
          isTrue,
        );
      },
    );

    test('deactivates before it wipes', () async {
      final log = <String>[];
      final deletion = AccountDeletion(
        bridges: () async => const [],
        deactivate: (_) async => log.add('deactivate'),
        wipe: () async => log.add('wipe'),
      );

      await deletion.deleteAccount(_NoReauth());

      expect(log, ['deactivate', 'wipe']);
    });

    test('clears nothing when the server did not deactivate', () async {
      var wiped = false;
      final deletion = AccountDeletion(
        bridges: () async => const [],
        deactivate: (_) async => throw const AccountDeactivationCancelled(),
        wipe: () async => wiped = true,
      );

      await expectLater(
        deletion.deleteAccount(_NoReauth()),
        throwsA(isA<AccountDeactivationCancelled>()),
      );
      expect(wiped, isFalse);
    });
  });

  group('wipeLocalData', () {
    setUp(() {
      // The keychain has no platform side under flutter_test; answer it so the
      // wipe is asserted against a completed call rather than a missing plugin.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          );
    });

    test('empties the database and forgets the credentials', () async {
      final stores = WeftStores.inMemory()
        ..llmApiKey = 'sk-secret'
        ..calendarIcsUrl = 'https://calendar.example.org/private.ics';
      stores.settings.setString(WeftSettings.themeMode, 'dark');
      stores.search.indexMessage(
        WeftMessage(
          eventId: r'$1',
          roomId: '!room:example.org',
          network: ChatNetwork.signal,
          senderId: '@peer:example.org',
          senderName: 'Peer',
          timestamp: DateTime.utc(2026, 11, 22),
          kind: MessageKind.text,
          isOwn: false,
          body: 'meet at the zebracorn',
        ),
        chatId: 'chat',
      );
      final container = ProviderContainer(
        overrides: [storesProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);

      await container
          .read(
            Provider(
              (ref) =>
                  () => wipeLocalData(ref),
            ),
          )
          .call();

      expect(stores.settings.getString(WeftSettings.themeMode), isNull);
      expect(await stores.search.keywordSearch('zebracorn'), isEmpty);
      expect(stores.llmApiKey, isNull);
      expect(stores.calendarIcsUrl, isNull);
    });
  });

  group('DeleteAccountScreen', () {
    Future<_Run> pump(
      WidgetTester tester, {
      List<BridgeSignOutTarget> bridges = const [],
      Future<void> Function(AccountReauth reauth)? deactivate,
    }) async {
      // Phone-width and tall enough for the whole form in the test font, whose
      // square glyphs wrap the consequence list to twice its real height.
      tester.view.physicalSize = const Size(430, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final run = _Run();
      final deletion = AccountDeletion(
        bridges: () async {
          run.log.add('bridges');
          return bridges;
        },
        deactivate: (reauth) async {
          run.log.add('deactivate');
          run.reauth = reauth;
          await deactivate?.call(reauth);
        },
        wipe: () async => run.log.add('wipe'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ownUserIdProvider.overrideWithValue('@alice:matrix.example.org'),
            accountDeletionProvider.overrideWithValue(deletion),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DeleteAccountScreen(),
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
      return run;
    }

    /// Frames, not `pumpAndSettle`: the progress bar under a dialog animates
    /// for as long as the deletion waits on it, so it never settles.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Finder deleteButton() =>
        find.widgetWithText(FilledButton, 'Delete account');

    Future<void> confirm(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'alice');
      await tester.pump();
      await tester.tap(deleteButton());
      await settle(tester);
    }

    testWidgets('says what happens, naming the account and its server', (
      tester,
    ) async {
      await pump(tester);

      expect(find.textContaining('@alice:matrix.example.org'), findsOneWidget);
      expect(
        find.textContaining(
          'Your account on matrix.example.org is '
          'deactivated for good',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('keep their copies'), findsOneWidget);
      expect(find.textContaining('signed out first'), findsOneWidget);
    });

    testWidgets('stays locked until the username is typed', (tester) async {
      await pump(tester);

      FilledButton button() => tester.widget<FilledButton>(deleteButton());
      expect(button().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'alic');
      await tester.pump();
      expect(button().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'alice');
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('signs out bridges, asks for the password, deletes, and '
        'returns to the first screen', (tester) async {
      final bridge = _Bridge(['wa']);
      String? password;
      final run = await pump(
        tester,
        bridges: [(network: 'WhatsApp', backend: bridge)],
        deactivate: (reauth) async => password = await reauth.password(),
      );

      await confirm(tester);

      expect(find.text('Confirm it’s you'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'hunter2',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete account'),
        ),
      );
      await settle(tester);

      expect(bridge.loggedOut, ['wa']);
      expect(password, 'hunter2');
      expect(run.log, ['bridges', 'deactivate', 'wipe']);
      expect(find.byType(DeleteAccountScreen), findsNothing);
      expect(find.text('Your account was deleted.'), findsOneWidget);
    });

    testWidgets('a wrong password is said, and asked again', (tester) async {
      final retries = <bool>[];
      await pump(
        tester,
        deactivate: (reauth) async {
          await reauth.password();
          retries.add(true);
          await reauth.password(retry: true);
        },
      );

      await confirm(tester);
      await tester.enterText(find.byType(TextField).last, 'wrong');
      await tester.tap(find.text('Delete account').last);
      await settle(tester);

      expect(find.textContaining('That password wasn’t right'), findsOneWidget);
    });

    testWidgets('single sign-on opens the browser and waits for the person', (
      tester,
    ) async {
      final launched = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') {
            launched.add((call.arguments as Map)['url']! as String);
          }
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
      bool? finished;
      final run = await pump(
        tester,
        deactivate: (reauth) async => finished = await reauth.completeInBrowser(
          Uri.parse(
            'https://matrix.example.org/_matrix/client/v3/auth/m.login.sso/'
            'fallback/web?session=S1',
          ),
        ),
      );

      await confirm(tester);

      expect(launched.single, contains('/auth/m.login.sso/fallback/web'));
      expect(find.text('Finish in your browser'), findsOneWidget);
      await tester.tap(find.text('I’m done'));
      await settle(tester);

      expect(finished, isTrue);
      expect(run.log.last, 'wipe');
    });

    testWidgets('backing out of the password deletes nothing and says so', (
      tester,
    ) async {
      final run = await pump(
        tester,
        bridges: [
          (network: 'Signal', backend: _Bridge(['sig'])),
        ],
        deactivate: (reauth) async {
          if (await reauth.password() == null) {
            throw const AccountDeactivationCancelled();
          }
        },
      );

      await confirm(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(run.log, isNot(contains('wipe')));
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
      expect(
        find.textContaining('but your bridges are signed out'),
        findsOneWidget,
      );
    });

    testWidgets('a bridge that will not sign out is asked about first', (
      tester,
    ) async {
      final run = await pump(
        tester,
        bridges: [
          (network: 'Telegram', backend: _Bridge(['tg'], fails: true)),
        ],
      );

      await confirm(tester);

      expect(find.textContaining('Telegram didn’t answer'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(run.log, ['bridges']);
      expect(find.text('Your account wasn’t deleted.'), findsOneWidget);
    });

    testWidgets('a bridge failure can be overridden', (tester) async {
      final run = await pump(
        tester,
        bridges: [
          (network: 'Telegram', backend: _Bridge(['tg'], fails: true)),
        ],
      );

      await confirm(tester);
      await tester.tap(find.text('Delete anyway'));
      await settle(tester);

      expect(run.log, ['bridges', 'deactivate', 'wipe']);
    });

    testWidgets('a server refusal is reported and nothing is cleared', (
      tester,
    ) async {
      final run = await pump(
        tester,
        deactivate: (_) async => throw MatrixException.fromJson({
          'errcode': 'M_FORBIDDEN',
          'error': 'Deactivation is disabled',
        }),
      );

      await confirm(tester);

      expect(run.log, isNot(contains('wipe')));
      expect(
        find.text('Couldn’t delete the account: Deactivation is disabled'),
        findsOneWidget,
      );
    });

    testWidgets('a stage Sennit cannot draw points at the server', (
      tester,
    ) async {
      await pump(
        tester,
        deactivate: (_) async => throw const AccountDeactivationUnsupported(),
      );

      await confirm(tester);

      expect(
        find.textContaining('Delete the account on matrix.example.org’s own'),
        findsOneWidget,
      );
    });
  });

  test('splits a Matrix ID into its username and server', () {
    expect(localpartOfUserId('@alice:example.org:8448'), 'alice');
    expect(serverOfUserId('@alice:example.org:8448'), 'example.org:8448');
  });
}

class _NoReauth implements AccountReauth {
  @override
  Future<String?> password({bool retry = false}) async => null;

  @override
  Future<bool> completeInBrowser(Uri url) async => false;
}
