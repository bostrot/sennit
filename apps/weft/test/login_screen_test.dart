import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/auth/login_screen.dart';
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
