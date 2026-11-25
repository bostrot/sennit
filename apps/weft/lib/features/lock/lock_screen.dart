import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../app/stores.dart';
import 'app_lock.dart';

/// Draws the lock over the whole app while it is locked.
///
/// Sits above the navigator, so no route — a chat, a share sheet, a call —
/// shows through, and keyboard shortcuts below it go quiet: focus cannot reach
/// them while the lock holds it. The app underneath stays built, so unlocking
/// returns to exactly where the user was.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  /// iOS photographs the app for its switcher as it goes inactive; this is
  /// what it photographs instead while the lock is on.
  bool _covered = false;

  bool? _hideApplied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  int get _afterSeconds =>
      ref
          .read(storesBootstrapProvider)
          .value
          ?.settings
          .getInt(AppLockSettings.afterSeconds) ??
      kDefaultAppLockAfterSeconds;

  bool get _enabled {
    final settings = ref.read(storesBootstrapProvider).value?.settings;
    return settings != null && appLockEnabled(settings);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) {
      if (_covered) setState(() => _covered = false);
      return;
    }
    // The biometric prompt takes the screen for a moment; that is not leaving.
    if (ref.read(appLockPromptingProvider)) return;
    final session = ref.read(appLockSessionProvider.notifier);
    switch (state) {
      case AppLifecycleState.inactive:
        // Only iOS: on macOS inactive is merely another window in front.
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          setState(() => _covered = true);
        }
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        session.wentAway(_afterSeconds);
      case AppLifecycleState.resumed:
        session.cameBack(_afterSeconds);
        if (_covered) setState(() => _covered = false);
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsRevisionProvider);
    final settings = ref.watch(storesBootstrapProvider).value?.settings;
    final enabled = settings != null && appLockEnabled(settings);
    final unlocked = ref.watch(appLockSessionProvider).unlocked;
    final locked = enabled && !unlocked;

    if (settings != null && _hideApplied != enabled) {
      _hideApplied = enabled;
      unawaited(applyHideInRecents(hide: enabled));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: locked,
          child: ExcludeSemantics(excluding: locked, child: widget.child),
        ),
        if (locked)
          const _Isolated(child: LockScreen())
        else if (_covered && enabled)
          const _Isolated(child: _PrivacyCover()),
      ],
    );
  }
}

/// Whether the biometric prompt is up, so its comings and goings are not
/// read as the app being left.
final appLockPromptingProvider = NotifierProvider<_Prompting, bool>(
  _Prompting.new,
);

class _Prompting extends Notifier<bool> {
  @override
  bool build() => false;

  void set({required bool value}) => state = value;
}

/// The gate is above the navigator, so it brings the overlay a text field
/// needs for its cursor and selection handles.
class _Isolated extends StatelessWidget {
  const _Isolated({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [OverlayEntry(builder: (_) => child)]);
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.surface,
      child: Center(
        child: Icon(
          Icons.lock_rounded,
          size: 48,
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The PIN field, and the biometric prompt when the user turned it on.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _checking = false;
  bool _biometrics = false;
  int _wrong = 0;
  DateTime? _waitUntil;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_offerBiometrics());
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _offerBiometrics() async {
    final settings = ref.read(storesBootstrapProvider).value?.settings;
    if (settings == null || !settings.getBool(AppLockSettings.biometrics)) {
      return;
    }
    final available = await ref.read(appLockBiometricsProvider).available();
    if (!mounted || !available) return;
    setState(() => _biometrics = true);
    await _useBiometrics();
  }

  Future<void> _useBiometrics() async {
    final reason = context.l10n.appLockBiometricReason;
    final prompting = ref.read(appLockPromptingProvider.notifier)
      ..set(value: true);
    final ok = await ref.read(appLockBiometricsProvider).authenticate(reason);
    prompting.set(value: false);
    if (!mounted) return;
    if (ok) {
      ref.read(appLockSessionProvider.notifier).unlock();
    } else {
      _focus.requestFocus();
    }
  }

  bool get _waiting {
    final until = _waitUntil;
    return until != null && clock.now().isBefore(until);
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    if (_checking || _waiting || pin.isEmpty) return;
    setState(() => _checking = true);
    final stored = await ref.read(appLockPinStoreProvider).read();
    final ok =
        stored == null ||
        await ref.read(appLockPinHasherProvider).verify(pin, stored);
    if (!mounted) return;
    if (ok) {
      ref.read(appLockSessionProvider.notifier).unlock();
      return;
    }
    _pin.clear();
    _wrong++;
    setState(() {
      _checking = false;
      _error = context.l10n.appLockWrongPin;
      if (_wrong >= kAppLockMaxTries) {
        _wrong = 0;
        _waitUntil = clock.now().add(kAppLockWait);
        _waitTimer = Timer(kAppLockWait, () {
          if (!mounted) return;
          setState(() {
            _waitUntil = null;
            _error = null;
          });
          _focus.requestFocus();
        });
      }
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final waiting = _waiting;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(WeftSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 48,
                    color: context.colors.primary,
                  ),
                  const SizedBox(height: WeftSpace.lg),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.appLockLocked,
                      style: context.text.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: WeftSpace.xl),
                  AppLockPinField(
                    controller: _pin,
                    focusNode: _focus,
                    label: l10n.appLockEnterPin,
                    enabled: !waiting && !_checking,
                    error: waiting
                        ? l10n.appLockWait(kAppLockWait.inSeconds)
                        : _error,
                    onSubmitted: _submit,
                  ),
                  const SizedBox(height: WeftSpace.lg),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: waiting || _checking ? null : _submit,
                      child: Text(l10n.appLockUnlock),
                    ),
                  ),
                  if (_biometrics) ...[
                    const SizedBox(height: WeftSpace.sm),
                    TextButton.icon(
                      onPressed: _useBiometrics,
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: Text(l10n.appLockUseBiometrics),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A PIN entry: digits only, hidden, at most [kAppLockPinMaxLength].
class AppLockPinField extends StatelessWidget {
  const AppLockPinField({
    required this.controller,
    required this.label,
    required this.onSubmitted,
    this.focusNode,
    this.error,
    this.helper,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String? error;
  final String? helper;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: true,
      obscureText: true,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: kAppLockPinMaxLength,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: context.text.headlineSmall?.copyWith(letterSpacing: 8),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        errorText: error,
        counterText: '',
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}
