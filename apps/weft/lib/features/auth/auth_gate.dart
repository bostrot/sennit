import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;
import '../../app/localisation.dart';

import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../inbox/inbox_shell.dart';
import '../whats_new/whats_new.dart';
import '../../services/web/phone_connection_errors.dart';
import 'connect_phone_screen.dart';
import 'login_screen.dart';
import 'setup_screen.dart';
import 'verification_screen.dart';
import 'walkthrough_screen.dart';

/// Chooses the screen for the current session state.
///
/// After sign-in the steps come in one order: verifying this device, then
/// first-start setup, then the walkthrough, then the inbox — and only then
/// does anything else get to ask the user something; see
/// [signInStepsDoneProvider].
///
/// The verification step is skippable, and that choice is remembered until
/// the next sign-in — otherwise every sync that re-emits `unverified` would
/// yank the user back out of their inbox. Once shown it also stays until the
/// user verifies or skips, even if the state turns `ready` underneath it:
/// a step that vanished by itself read as having been skipped for them.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  _Verification _verification = _Verification.notAsked;

  SettingsStore? get _settings {
    try {
      return ref.read(storesProvider).settings;
    } on Object {
      return null;
    }
  }

  bool get _setupDone {
    if (kNoMatrix) return true;
    final settings = _settings;
    // Stores not up yet: claim done rather than flashing setup on the way
    // to the splash — the gate rebuilds when they open.
    if (settings == null) return true;
    return settings.getBool(WeftSettings.onboardingDone);
  }

  void _finishSetup() {
    _settings?.setBool(WeftSettings.onboardingDone, value: true);
    setState(() {});
  }

  bool get _walkthroughPending {
    if (kNoMatrix) return false;
    return _settings?.getBool(WeftSettings.walkthroughPending) ?? false;
  }

  /// Owes the walkthrough to whoever signs in from the sign-in screen, once
  /// per install. Keyed on that screen having been shown rather than on a
  /// successful sign-in: the session state turns over inside the sign-in
  /// call, and a flag set after it would arrive after the inbox had.
  void _armWalkthrough() {
    final settings = _settings;
    if (settings == null) return;
    if (settings.getBool(WeftSettings.walkthroughDone)) return;
    if (settings.getBool(WeftSettings.walkthroughPending)) return;
    settings.setBool(WeftSettings.walkthroughPending, value: true);
  }

  void _finishWalkthrough() {
    _settings
      ?..setBool(WeftSettings.walkthroughPending, value: false)
      ..setBool(WeftSettings.walkthroughDone, value: true);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionStateProvider);
    // Stores open before anything renders data: every provider below the gate
    // reads them synchronously.
    final stores = ref.watch(storesBootstrapProvider);
    if (stores.isLoading) return const _Splash(key: ValueKey('splash'));
    if (stores.hasError) {
      return _StartupError(
        key: const ValueKey('error'),
        error: stores.error!,
        onRetry: () => ref.invalidate(storesBootstrapProvider),
      );
    }

    return AnimatedSwitcher(
      duration: WeftMotion.normal,
      switchInCurve: WeftMotion.enter,
      child: switch (state) {
        AsyncLoading() => const _Splash(key: ValueKey('splash')),
        AsyncError(:final PhoneConnectionException error) => ConnectPhoneScreen(
          key: const ValueKey('connect'),
          problem: error.problem,
          onRetry: () => ref.invalidate(remoteRepositoryProvider),
        ),
        AsyncError(:final error) => _StartupError(
          key: const ValueKey('error'),
          error: error,
          onRetry: () => ref.invalidate(sessionBootstrapProvider),
        ),
        AsyncData(:final value) => _forState(value),
      },
    );
  }

  Widget _forState(WeftSessionState state) {
    if (state == WeftSessionState.loggedOut) {
      _armWalkthrough();
      _verification = _Verification.notAsked;
    }
    if (state == WeftSessionState.unverified &&
        _verification == _Verification.notAsked) {
      _verification = _Verification.owed;
    }
    final screen = switch (state) {
      WeftSessionState.loggedOut || WeftSessionState.softLoggedOut =>
        const LoginScreen(key: ValueKey('login')),
      WeftSessionState.connecting => const _Splash(key: ValueKey('splash')),
      _ when _verification == _Verification.owed => VerificationScreen(
        key: const ValueKey('verify'),
        onContinue: () => setState(() => _verification = _Verification.settled),
      ),
      _ when !_setupDone => SetupScreen(
        key: const ValueKey('setup'),
        onDone: _finishSetup,
      ),
      _ when _walkthroughPending => WalkthroughScreen(
        key: const ValueKey('walkthrough'),
        onDone: _finishWalkthrough,
      ),
      _ => const WhatsNewGate(key: ValueKey('inbox'), child: InboxShell()),
    };
    _reportStepsDone(screen is WhatsNewGate);
    return screen;
  }

  /// Tells [signInStepsDoneProvider] whether the inbox is up. After the
  /// frame, because a provider must not change while the tree is building.
  void _reportStepsDone(bool done) {
    if (ref.read(signInStepsDoneProvider) == done) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(signInStepsDoneProvider.notifier).report(done: done);
    });
  }
}

/// Where this sign-in is with verifying the device.
enum _Verification {
  /// Not shown yet: the session has not reported `unverified`.
  notAsked,

  /// Shown and waiting for the user to verify or skip.
  owed,

  /// Verified or skipped; not asked again until the next sign-in.
  settled,
}

class _Splash extends StatelessWidget {
  const _Splash({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 72),
            const SizedBox(height: WeftSpace.xl),
            SizedBox(
              height: 20,
              width: 20,
              // A slow start is a blank screen with a spinner on it, and a
              // spinner with no label is a screen with nothing on it at all.
              child: Semantics(
                label: context.l10n.authStarting,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: context.colors.error,
              ),
              const SizedBox(height: WeftSpace.lg),
              Text(
                context.l10n.authStartupFailed,
                style: context.text.titleMedium,
              ),
              const SizedBox(height: WeftSpace.sm),
              Text(
                // l10n-ignore: the underlying error, in English, from the SDK.
                '$error',
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: WeftSpace.xl),
              FilledButton(
                onPressed: onRetry,
                child: Text(context.l10n.settingsTryAgain),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
