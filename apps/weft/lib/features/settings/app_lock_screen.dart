import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../lock/app_lock.dart';
import '../lock/lock_screen.dart';

/// Turns the app lock on and off, and sets how it unlocks and when it returns.
///
/// Everything here stays on this device; see [AppLockSettings].
class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() =>
      _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends ConsumerState<AppLockSettingsScreen> {
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkBiometrics());
  }

  Future<void> _checkBiometrics() async {
    final available = await ref.read(appLockBiometricsProvider).available();
    if (mounted) setState(() => _biometricsAvailable = available);
  }

  void _changed() => ref.read(settingsRevisionProvider.notifier).bump();

  /// Asks for a new PIN twice and keeps its hash; false when abandoned.
  Future<bool> _choosePin() async {
    final pin = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const AppLockPinSetupScreen()),
    );
    if (pin == null) return false;
    final hash = await ref.read(appLockPinHasherProvider).hash(pin);
    await ref.read(appLockPinStoreProvider).write(hash);
    return true;
  }

  Future<void> _setEnabled({required bool value}) async {
    final settings = ref.read(storesProvider).settings;
    if (value) {
      if (!await _choosePin() || !mounted) return;
      // Whoever just chose the PIN is the one person who need not type it.
      ref.read(appLockSessionProvider.notifier).unlock();
      settings.setBool(AppLockSettings.enabled, value: true);
    } else {
      settings
        ..setBool(AppLockSettings.enabled, value: false)
        ..setBool(AppLockSettings.biometrics, value: false);
      await ref.read(appLockPinStoreProvider).write(null);
    }
    _changed();
  }

  Future<void> _setBiometrics({required bool value}) async {
    final settings = ref.read(storesProvider).settings;
    if (value) {
      // Proven once here, so the lock never offers a prompt that cannot pass.
      final reason = context.l10n.appLockBiometricReason;
      final prompting = ref.read(appLockPromptingProvider.notifier)
        ..set(value: true);
      final ok = await ref.read(appLockBiometricsProvider).authenticate(reason);
      prompting.set(value: false);
      if (!ok) return;
    }
    settings.setBool(AppLockSettings.biometrics, value: value);
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsRevisionProvider);
    final l10n = context.l10n;
    final settings = ref.watch(storesProvider).settings;
    final enabled = appLockEnabled(settings);
    final after =
        settings.getInt(AppLockSettings.afterSeconds) ??
        kDefaultAppLockAfterSeconds;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsAppLockTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            SwitchListTile(
              title: Text(l10n.appLockSwitchTitle),
              subtitle: Text(l10n.appLockSwitchSubtitle),
              value: enabled,
              onChanged: (value) => _setEnabled(value: value),
              contentPadding: EdgeInsets.zero,
            ),
            if (enabled) ...[
              if (_biometricsAvailable)
                SwitchListTile(
                  title: Text(l10n.appLockBiometricsTitle),
                  subtitle: Text(l10n.appLockBiometricsSubtitle),
                  value: settings.getBool(AppLockSettings.biometrics),
                  onChanged: (value) => _setBiometrics(value: value),
                  contentPadding: EdgeInsets.zero,
                ),
              ListTile(
                title: Text(l10n.appLockChangePin),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _choosePin,
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(height: WeftSpace.xl),
              Text(l10n.appLockAfterTitle, style: context.text.labelLarge),
              const SizedBox(height: WeftSpace.sm),
              Wrap(
                spacing: WeftSpace.sm,
                runSpacing: WeftSpace.sm,
                children: [
                  for (final seconds in kAppLockAfterChoices)
                    ChoiceChip(
                      label: Text(
                        seconds == 0
                            ? l10n.appLockAfterNow
                            : l10n.appLockAfterMinutes(seconds ~/ 60),
                      ),
                      selected: after == seconds,
                      onSelected: (_) {
                        settings.setInt(AppLockSettings.afterSeconds, seconds);
                        _changed();
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Choose a PIN, then type it again; pops with the PIN once both agree.
class AppLockPinSetupScreen extends StatefulWidget {
  const AppLockPinSetupScreen({super.key});

  @override
  State<AppLockPinSetupScreen> createState() => _AppLockPinSetupScreenState();
}

class _AppLockPinSetupScreenState extends State<AppLockPinSetupScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();

  /// The first entry, while the second is being typed.
  String? _first;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _next() {
    final pin = _pin.text;
    final first = _first;
    if (first == null) {
      if (!isValidAppLockPin(pin)) return;
      setState(() {
        _first = pin;
        _error = null;
      });
    } else if (pin == first) {
      Navigator.of(context).pop(pin);
      return;
    } else {
      setState(() {
        _first = null;
        _error = context.l10n.appLockPinMismatch;
      });
    }
    _pin.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final confirming = _first != null;
    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsAppLockTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            AppLockPinField(
              // A new field per step, so the label and focus start over.
              key: ValueKey(confirming),
              controller: _pin,
              focusNode: _focus,
              label: confirming ? l10n.appLockRepeatPin : l10n.appLockChoosePin,
              helper: l10n.appLockPinHint,
              error: _error,
              onSubmitted: _next,
            ),
            const SizedBox(height: WeftSpace.lg),
            ListenableBuilder(
              listenable: _pin,
              builder: (context, _) => FilledButton(
                onPressed: isValidAppLockPin(_pin.text) ? _next : null,
                child: Text(confirming ? l10n.commonSave : l10n.appLockNext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
