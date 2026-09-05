import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;
import '../../app/localisation.dart';

import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../inbox/inbox_shell.dart';
import 'login_screen.dart';
import 'setup_screen.dart';
import 'verification_screen.dart';

/// Chooses the screen for the current session state.
///
/// The verification step is skippable, and that choice is remembered for the
/// session — otherwise every sync that re-emits `unverified` would yank the
/// user back out of their inbox.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  bool _verificationDismissed = false;

  SettingsStore? get _settings {
    try {
      return ref.read(storesProvider).settings;
    } on Object {
      return null;
    }
  }

  bool get _setupDone {
    if (kDemoMode) return true;
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
    return switch (state) {
      WeftSessionState.loggedOut || WeftSessionState.softLoggedOut =>
        const LoginScreen(key: ValueKey('login')),
      WeftSessionState.connecting => const _Splash(key: ValueKey('splash')),
      WeftSessionState.unverified when !_verificationDismissed =>
        VerificationScreen(
          key: const ValueKey('verify'),
          onContinue: () => setState(() => _verificationDismissed = true),
        ),
      _ when !_setupDone => SetupScreen(
        key: const ValueKey('setup'),
        onDone: _finishSetup,
      ),
      _ => const InboxShell(key: ValueKey('inbox')),
    };
  }
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
