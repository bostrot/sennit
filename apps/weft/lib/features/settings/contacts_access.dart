import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/contacts/device_contacts.dart';
import 'settings_section.dart';

/// Says how a request for the address book ended, when it did not end well.
///
/// A refusal for good gets the system settings as its action: Android will not
/// show the prompt again, so a button that asks again would do nothing.
void showContactsAccessResult(BuildContext context, ContactsAccess access) {
  switch (access) {
    case ContactsAccess.granted:
      return;
    case ContactsAccess.denied:
      showWeftMessage(context, context.l10n.settingsContactsDenied);
    case ContactsAccess.blocked:
      showWeftMessage(
        context,
        context.l10n.contactsBlocked,
        action: SnackBarAction(
          label: context.l10n.commonSettings,
          onPressed: () =>
              unawaited(FlutterContacts.permissions.openSettings()),
        ),
      );
  }
}

/// Asks for the address book from a tap, and reports a refusal.
Future<void> requestDeviceContacts(BuildContext context, WidgetRef ref) async {
  final settings = ref.read(storesBootstrapProvider).value?.settings;
  if (settings == null) return;
  final access = await enableDeviceContacts(
    settings,
    onChanged: ref.read(settingsRevisionProvider.notifier).bump,
  );
  if (context.mounted) showContactsAccessResult(context, access);
}

/// The offer to name SMS threads from the address book, made in the thread.
///
/// SMS is the network where a number is all there is, so the moment someone
/// reads one is the moment the offer makes sense — not a settings screen they
/// visit once. Shown until it is taken or put away, and never again after
/// either; the switch in Settings stays as the way back.
class SmsContactsBanner extends ConsumerWidget {
  const SmsContactsBanner({super.key, required this.visible});

  /// Whether the conversation has an SMS leg at all.
  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visible || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    ref.watch(settingsRevisionProvider);
    // The bootstrap's value rather than [storesProvider]: a chat view drawn
    // before the database is open must not be an error, just no strip.
    final settings = ref.watch(storesBootstrapProvider).value?.settings;
    if (settings == null) return const SizedBox.shrink();
    if (settings.getBool(WeftSettings.useDeviceContactNames) ||
        settings.getBool(kContactsSmsPromptDismissedKey)) {
      return const SizedBox.shrink();
    }

    final message = context.l10n.smsContactsPrompt;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: message,
      child: Material(
        color: context.colors.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            WeftSpace.sm,
            WeftSpace.sm,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.person_pin_rounded,
                      size: 18,
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: WeftSpace.md),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        message,
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      settings.setBool(
                        kContactsSmsPromptDismissedKey,
                        value: true,
                      );
                      ref.read(settingsRevisionProvider.notifier).bump();
                    },
                    child: Text(context.l10n.commonNotNow),
                  ),
                  TextButton(
                    onPressed: () =>
                        unawaited(requestDeviceContacts(context, ref)),
                    child: Text(context.l10n.setupContactsAction),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The SMS screen's word on contact names: on, or a button to turn them on.
class SmsContactsSection extends ConsumerWidget {
  const SmsContactsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    final settings = ref.watch(storesBootstrapProvider).value?.settings;
    if (settings == null) return const SizedBox.shrink();
    final enabled = settings.getBool(WeftSettings.useDeviceContactNames);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(
          title: l10n.smsContactsTitle,
          subtitle: enabled ? l10n.smsContactsOn : l10n.smsContactsOff,
        ),
        if (!enabled) ...[
          const SizedBox(height: WeftSpace.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.person_pin_rounded, size: 18),
              label: Text(l10n.setupContactsAction),
              onPressed: () => unawaited(requestDeviceContacts(context, ref)),
            ),
          ),
        ],
      ],
    );
  }
}
