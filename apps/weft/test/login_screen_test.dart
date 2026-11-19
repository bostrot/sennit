import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/auth/login_screen.dart';
import 'package:weft/features/auth/matrix_server_sheet.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// The sign-in screen's second form: creating the account instead of signing
/// in to it.
///
/// Signing in is covered on a device by the Patrol `login_test`, against a
/// real homeserver. What that cannot reach cheaply is every way a server
/// answers a sign-up — open, invitation only, switched off — and each of
/// those changes what the form shows before anything is typed.
void main() {
  Future<_FakeSession> pumpResolved(
    WidgetTester tester, {
    RegistrationOffer? offer = RegistrationOffer.open,
  }) async {
    final session = _FakeSession(offer: offer);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [matrixSessionProvider.overrideWithValue(session)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const LoginScreen(),
        ),
      ),
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    return session;
  }

  Future<void> openCreateForm(WidgetTester tester) async {
    await tester.ensureVisible(find.text('New here? Create an account'));
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
  }

  group('What is a Matrix server?', () {
    Future<_FakeSession> pumpUnresolved(WidgetTester tester) async {
      final session = _FakeSession(offer: RegistrationOffer.open);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [matrixSessionProvider.overrideWithValue(session)],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const LoginScreen(),
          ),
        ),
      );
      return session;
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byType(MatrixServerInfoButton));
      await tester.pumpAndSettle();
    }

    testWidgets('sits under the server field and explains it', (tester) async {
      await pumpUnresolved(tester);
      expect(find.text('What is a Matrix server?'), findsOneWidget);

      await openSheet(tester);
      expect(find.byType(MatrixServerSheet), findsOneWidget);
      expect(find.text('Use our public server'), findsOneWidget);
      expect(find.text('Host your own'), findsOneWidget);
      expect(find.text('Bridges'), findsOneWidget);
      expect(find.textContaining('matrix.aachen.dev'), findsWidgets);
    });

    testWidgets('picking our server fills the field and resolves it', (
      tester,
    ) async {
      final session = await pumpUnresolved(tester);
      await tester.enterText(find.byType(TextField).first, 'elsewhere.org');
      await openSheet(tester);

      await tester.ensureVisible(find.text('Use matrix.aachen.dev'));
      await tester.tap(find.text('Use matrix.aachen.dev'));
      await tester.pumpAndSettle();

      expect(find.byType(MatrixServerSheet), findsNothing);
      expect(session.resolved, kDefaultHomeserver);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('links open outside the app', (tester) async {
      final launched = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url']! as String);
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await pumpUnresolved(tester);
      await openSheet(tester);
      for (final label in [
        'Synapse installation guide',
        'Browse available bridges',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      expect(launched, [
        MatrixServerLinks.synapse.toString(),
        MatrixServerLinks.bridges.toString(),
      ]);
    });
  });

  testWidgets('a new install is pointed at the default server', (tester) async {
    final session = await pumpResolved(tester);
    expect(session.resolved, kDefaultHomeserver);
    expect(kDefaultHomeserver, 'matrix.aachen.dev');
  });

  testWidgets('signing in is still server, username, password', (tester) async {
    await pumpResolved(tester);
    // The Patrol suite finds these three by position.
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('creates an account with the typed name, lowercased', (
    tester,
  ) async {
    final session = await pumpResolved(tester);
    await openCreateForm(tester);

    // Server, username, password, password again — and no invite code, since
    // this server did not ask for one.
    expect(find.byType(TextField), findsNWidgets(4));
    await tester.enterText(find.byType(TextField).at(1), ' Anna ');
    await tester.pump();
    expect(find.text('You will be @anna:matrix.aachen.dev'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(2), 'correct horse');
    await tester.enterText(find.byType(TextField).at(3), 'correct horse');
    await submit(tester);

    expect(session.registrations, [
      (username: 'anna', password: 'correct horse', token: ''),
    ]);
  });

  testWidgets('a mistyped repeat is caught before the server is asked', (
    tester,
  ) async {
    final session = await pumpResolved(tester);
    await openCreateForm(tester);
    await tester.enterText(find.byType(TextField).at(1), 'anna');
    await tester.enterText(find.byType(TextField).at(2), 'correct horse');
    await tester.enterText(find.byType(TextField).at(3), 'correct hores');
    await submit(tester);

    expect(find.text('The two passwords do not match.'), findsOneWidget);
    expect(session.registrations, isEmpty);
  });

  testWidgets('an invitation-only server gets an invite code field', (
    tester,
  ) async {
    final session = await pumpResolved(
      tester,
      offer: RegistrationOffer.needsToken,
    );
    await openCreateForm(tester);
    expect(find.byType(TextField), findsNWidgets(5));

    await tester.enterText(find.byType(TextField).at(1), 'anna');
    await tester.enterText(find.byType(TextField).at(2), 'correct horse');
    await tester.enterText(find.byType(TextField).at(3), 'correct horse');
    await submit(tester);
    expect(find.text('Enter your invite code.'), findsOneWidget);
    expect(session.registrations, isEmpty);

    session.failure = const RegistrationException(
      RegistrationFailure.tokenRejected,
    );
    await tester.enterText(find.byType(TextField).at(4), 'not-a-code');
    await submit(tester);
    expect(
      find.text(
        'That invite code was not accepted. Check it, or ask for a new one.',
      ),
      findsOneWidget,
    );
    // The refusal leaves the form as it was: what was typed is still there.
    expect(find.text('anna'), findsOneWidget);

    session.failure = null;
    await tester.enterText(find.byType(TextField).at(4), 'welcome');
    await submit(tester);
    expect(session.registrations.last.token, 'welcome');
  });

  testWidgets('a server with sign-up switched off says so, with no form', (
    tester,
  ) async {
    await pumpResolved(tester, offer: RegistrationOffer.closed);
    await openCreateForm(tester);

    expect(
      find.text(
        'matrix.aachen.dev is not accepting new accounts from the app right '
        'now.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create account'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a taken username is named as that', (tester) async {
    final session = await pumpResolved(tester);
    session.failure = Exception('M_USER_IN_USE: User ID already taken.');
    await openCreateForm(tester);
    await tester.enterText(find.byType(TextField).at(1), 'anna');
    await tester.enterText(find.byType(TextField).at(2), 'correct horse');
    await tester.enterText(find.byType(TextField).at(3), 'correct horse');
    await submit(tester);

    expect(find.text('That username is taken. Try another.'), findsOneWidget);
  });
}

class _FakeSession implements WeftMatrixSession {
  _FakeSession({required this.offer});

  final RegistrationOffer? offer;

  /// Thrown by the next [register] instead of creating anything.
  Exception? failure;

  String? resolved;
  final List<({String username, String password, String token})> registrations =
      [];

  @override
  Future<HomeserverDiscovery> checkHomeserver(String input) async {
    resolved = input;
    return HomeserverDiscovery(
      baseUrl: Uri.parse('https://$input'),
      serverName: input,
    );
  }

  @override
  Future<List<LoginFlow>> supportedLoginFlows() async => const [];

  @override
  Future<RegistrationOffer> registrationOffer() async {
    // Null stands for a server that could not be asked.
    return offer ?? (throw Exception('offline'));
  }

  @override
  Future<void> register({
    required String username,
    required String password,
    String? registrationToken,
  }) async {
    if (failure case final error?) throw error;
    registrations.add((
      username: username,
      password: password,
      token: registrationToken ?? '',
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
