import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/auth/auth_gate.dart';
import 'package:weft/features/auth/setup_screen.dart';
import 'package:weft/features/auth/verification_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

/// The steps after sign-in, in their one order.
///
/// What has to hold: verifying the device comes first and stays until the
/// user verifies or skips it — even when the session turns `ready` under it,
/// which an OAuth token refresh used to do — and nothing that asks for
/// notifications gets in before that. The reporter saw the verification
/// screen give way to the notification prompt before they could use it.
void main() {
  late WeftStores stores;
  late StreamController<WeftSessionState> states;
  late ProviderContainer container;
  late WidgetRef widgetRef;

  setUp(() {
    stores = WeftStores.inMemory();
    states = StreamController<WeftSessionState>();
  });
  tearDown(() async {
    await states.close();
    stores.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesBootstrapProvider.overrideWith((ref) => stores),
          sessionStateProvider.overrideWith((ref) => states.stream),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            widgetRef = ref;
            return MaterialApp(
              localizationsDelegates: weftLocalizationsDelegates,
              supportedLocales: weftSupportedLocales,
              theme: WeftTheme.build(surface: WeftSurface.touch),
              home: const AuthGate(),
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> emit(WidgetTester tester, WeftSessionState state) async {
    states.add(state);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  bool stepsDone() => container.read(signInStepsDoneProvider);

  testWidgets('password sign-in: verification, then setup', (tester) async {
    await pump(tester);
    await emit(tester, WeftSessionState.connecting);
    await emit(tester, WeftSessionState.unverified);

    expect(find.byType(VerificationScreen), findsOneWidget);
    expect(find.byType(SetupScreen), findsNothing);

    await tester.tap(find.text('Continue without verifying'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(VerificationScreen), findsNothing);
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.text('Get told about messages'), findsOneWidget);
    expect(stepsDone(), isFalse, reason: 'setup is still a step');
  });

  testWidgets('OAuth sign-in: turning ready does not skip verification', (
    tester,
  ) async {
    await pump(tester);
    await emit(tester, WeftSessionState.connecting);
    await emit(tester, WeftSessionState.unverified);
    // What a token refresh a few minutes after an OAuth sign-in reported:
    // by then the SDK trusts its own device's keys.
    await emit(tester, WeftSessionState.ready);

    expect(find.byType(VerificationScreen), findsOneWidget);
    expect(find.byType(SetupScreen), findsNothing);
    expect(stepsDone(), isFalse);

    await tester.tap(find.text('Continue without verifying'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SetupScreen), findsOneWidget);
  });

  testWidgets('the skip lasts until the next sign-in', (tester) async {
    await pump(tester);
    await emit(tester, WeftSessionState.unverified);
    await tester.tap(find.text('Continue without verifying'));
    await tester.pump();

    await emit(tester, WeftSessionState.unverified);
    expect(find.byType(VerificationScreen), findsNothing);

    // Signing out and in again asks again.
    stores.settings.setBool(WeftSettings.onboardingDone, value: true);
    await emit(tester, WeftSessionState.loggedOut);
    await emit(tester, WeftSessionState.connecting);
    await emit(tester, WeftSessionState.unverified);
    expect(find.byType(VerificationScreen), findsOneWidget);
  });

  testWidgets('the notification prompt waits for the steps', (tester) async {
    await pump(tester);
    await emit(tester, WeftSessionState.unverified);

    var prompted = false;
    unawaited(untilSignInStepsDone(widgetRef).then((_) => prompted = true));
    await tester.pump();
    expect(prompted, isFalse, reason: 'verification is still on screen');

    container.read(signInStepsDoneProvider.notifier).report(done: true);
    await tester.pump();
    expect(prompted, isTrue);
  });
}
