import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';
import '../../app/localisation.dart';

import '../../app/notification_providers.dart';
import '../../app/stores.dart';
import '../../services/contacts/device_contacts.dart';
import '../../services/notifications/push_registration.dart';

/// First-start setup: the three things a messenger is useless without,
/// asked once, in order, with the reason on the page instead of inside a
/// surprise permission dialog.
///
/// Everything here defaults to *on* — the primary button grants, "Not now"
/// skips — and every switch stays reachable in Settings afterwards, so a
/// skip costs nothing permanent. The screen shows exactly once per install;
/// [WeftSettings.onboardingDone] remembers.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  static const _syncChannel = MethodChannel('com.bostrot.weft/sync_control');

  int _step = 0;
  bool _busy = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The steps this platform actually has. Desktop needs no permission for
  /// notifications and has no connection service or contact store, so there
  /// the flow finishes before it starts.
  List<_SetupStep> get _steps {
    final l10n = context.l10n;
    return [
      if (NotificationPlatform.needsPermissionPrompt)
        _SetupStep(
          icon: Icons.notifications_active_outlined,
          title: l10n.setupNotificationsTitle,
          body: l10n.setupNotificationsBody,
          action: l10n.setupNotificationsAction,
          run: _enableNotifications,
        ),
      if (_isAndroid)
        _SetupStep(
          icon: Icons.sync_rounded,
          title: l10n.setupConnectionTitle,
          body: l10n.setupConnectionBody,
          action: l10n.setupConnectionTitle,
          run: _enableConnection,
        ),
      if (_isAndroid || defaultTargetPlatform == TargetPlatform.iOS)
        _SetupStep(
          icon: Icons.person_pin_rounded,
          title: l10n.setupContactsTitle,
          body: l10n.setupContactsBody,
          action: l10n.setupContactsAction,
          run: _enableContactNames,
        ),
    ];
  }

  SettingsStore? get _settings {
    try {
      return ref.read(storesProvider).settings;
    } on Object {
      return null;
    }
  }

  Future<void> _enableNotifications() async {
    markNotificationPermissionAsked(_settings);
    final service = await ref.read(notificationServiceProvider.future);
    await service?.requestPermission();
  }

  Future<void> _enableConnection() async {
    try {
      await _syncChannel.invokeMethod<void>('setEnabled', {'enabled': true});
      // The page above is the walkthrough; the system dialog follows it
      // directly rather than after one more sheet.
      await _syncChannel.invokeMethod<void>('requestBatteryExemption');
    } on Object catch (error) {
      debugPrint('weft: setup could not enable the connection: $error');
    }
  }

  Future<void> _enableContactNames() async {
    final settings = _settings;
    final names = await loadDeviceContactNames();
    if (names == null || settings == null) return;
    settings.setJson(kContactNamesCacheKey, names);
    settings.setBool(WeftSettings.useDeviceContactNames, value: true);
    ref.read(settingsRevisionProvider.notifier).bump();
  }

  Future<void> _advance({required bool granted}) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (granted) {
      try {
        await _steps[_step].run();
      } on Object catch (error) {
        debugPrint('weft: setup step failed: $error');
      }
    }
    if (!mounted) return;
    if (_step + 1 < _steps.length) {
      setState(() {
        _step += 1;
        _busy = false;
      });
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty) {
      // Nothing to set up on this platform.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone());
      return const Scaffold(body: SizedBox.shrink());
    }
    final step = _steps[_step];

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(step.icon, size: 56, color: context.colors.primary),
              const SizedBox(height: WeftSpace.xl),
              Text(
                step.title,
                textAlign: TextAlign.center,
                style: context.text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: WeftSpace.md),
              Text(
                step.body,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const Spacer(),
              // Dots say where in the flow this is.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _steps.length; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _step
                            ? context.colors.primary
                            : context.colors.surfaceContainerHighest,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: WeftSpace.xl),
              FilledButton(
                onPressed: _busy ? null : () => _advance(granted: true),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(step.action),
              ),
              const SizedBox(height: WeftSpace.sm),
              TextButton(
                onPressed: _busy ? null : () => _advance(granted: false),
                child: Text(context.l10n.commonNotNow),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupStep {
  const _SetupStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.run,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final Future<void> Function() run;
}
