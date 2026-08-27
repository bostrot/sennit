import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft_sms/weft_sms.dart';

import '../../app/providers.dart';
import '../../data/sms_chat_repository.dart';
import '../../services/sms/sms_platform.dart';
import '../bridges/bridges_screen.dart';
import 'settings_section.dart';

/// The one place Weft asks for Android's default-SMS-app role.
///
/// The whole SMS track is built to work without this: on a desktop, on iOS, and
/// on an Android phone where another app is the default, the SMS network is
/// simply absent from the inbox and nothing else changes. So the screen's job
/// is not to press — it is to say what the role costs, offer it once, and be
/// equally readable after a decline. Android grants the role all-or-nothing:
/// there is no "read my messages but do not send", and the app that holds it
/// becomes the only one allowed to write to the system provider. Saying that
/// before the dialog appears is the difference between a choice and a prompt
/// somebody dismissed.
///
/// Its own screen rather than a row on the bridges screen, following the
/// distinction that one already draws: bridges are servers the user runs, and
/// this is a permission the *phone* grants. Nothing here is configured.
class SmsScreen extends ConsumerStatefulWidget {
  const SmsScreen({super.key});

  @override
  ConsumerState<SmsScreen> createState() => _SmsScreenState();
}

class _SmsScreenState extends ConsumerState<SmsScreen> {
  /// True while the system dialog is up, so the button cannot raise a second.
  bool _busy = false;

  /// Set when the last request was declined, and cleared by the next one.
  ///
  /// A decline is an answer, so it is reported in the quiet box rather than a
  /// SnackBar that slides away — the user needs to be able to look at the
  /// screen afterwards and see that the state they are in is the one they
  /// chose, not a failure.
  bool _declined = false;

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(smsRepositoryProvider);

    return Scaffold(
      appBar: WeftAppBar(
        title: const Text('SMS'),
        actions: [
          if (repository != null)
            IconButton(
              tooltip: 'Check again',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy ? null : () => _recheck(repository),
            ),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: repository == null
              ? const [
                  SettingsMessage(
                    message:
                        'This device has no SMS. Braid carries SMS only on '
                        'Android, where the system can hand one app the '
                        'messaging role — everywhere else your conversations '
                        'arrive over Matrix and its bridges.',
                  ),
                ]
              : _body(context, repository),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, SmsChatRepository repository) {
    final status = repository.status;

    return [
      const PrivacyNotice(
        message:
            'SMS is not encrypted. Every message you send this way is readable '
            'by your carrier, by the recipient\'s carrier, and by anyone who '
            'can see either network — and Braid cannot change that, because '
            'there is no encryption in SMS to switch on. It is here so one '
            'person\'s texts and their bridged chats can be one conversation, '
            'not because it is safe.',
      ),
      const SizedBox(height: WeftSpace.lg),

      SettingsSectionHeader(
        title: 'Default messaging app',
        subtitle: _explain(status),
      ),
      _StatusRow(status: status),

      if (status.availability == SmsAvailability.ready &&
          !status.hasPermissions) ...[
        const SizedBox(height: WeftSpace.md),
        // The one state that looks fine and reads empty: the role is Weft's,
        // and the permission group under it is not granted, so every read comes
        // back with nothing. An inbox that has mysteriously lost its SMS is
        // worse than a sentence saying why.
        Text(
          'Braid holds the role but not the SMS permissions, so no threads can '
          'be read. Grant them in Android\'s app settings and check again.',
          style: context.text.bodySmall?.copyWith(color: context.colors.error),
        ),
      ],

      const SizedBox(height: WeftSpace.lg),
      ..._rcs(context, status),

      if (status.canRequestRole) ...[
        const SizedBox(height: WeftSpace.lg),
        const SettingsSectionHeader(
          title: 'What the role does',
          subtitle:
              'Android gives it all at once. The default app receives every '
              'incoming message, is the only app allowed to write to the '
              'phone\'s message store, and answers the "send a message" action '
              'from your contacts and dialler. Braid writes what it receives '
              'and sends into that same store, so switching back to another '
              'app leaves your history where it was.',
        ),
        const SizedBox(height: WeftSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: const Text('Make Braid the SMS app'),
            onPressed: _busy ? null : () => _request(repository),
          ),
        ),
      ],

      if (_declined) ...[
        const SizedBox(height: WeftSpace.md),
        Text(
          'Nothing changed. Braid is not your SMS app, the SMS network stays '
          'out of your inbox, and every other conversation works exactly as '
          'it did. You can come back here whenever you like.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    ];
  }

  /// Whether a Google Messages bridge is relaying this phone into the inbox.
  ///
  /// It matters here because that bridge relays *through the app*, and an app
  /// that is not the default receives nothing to relay. Taking the role
  /// therefore costs the user their RCS twice over: once on the phone, and
  /// once in the inbox they were reading it in.
  bool get _hasGoogleMessagesBridge {
    try {
      return ref
          .read(detectedBridgesProvider)
          .any((bridge) => bridge.network == ChatNetwork.gmessages);
    } on Object {
      return false;
    }
  }

  /// Where RCS stands on this phone, which the role decides and cannot move.
  ///
  /// The section that was missing. Everything else here described the role
  /// honestly — every incoming message, sole write access to the store — and
  /// left out the consequence a user cannot undo by reading: taking the role
  /// ends RCS for the whole phone. Android has no RCS API for a third-party
  /// app, so this is not a feature Braid has yet to build; it is one it cannot
  /// have, and saying so is the only useful thing to do about it.
  List<Widget> _rcs(BuildContext context, SmsPlatformStatus status) {
    final standing = rcsStanding(
      supported: status.availability != SmsAvailability.unsupported,
      braidIsDefault: status.isReady,
      defaultPackage: status.defaultPackage,
    );
    if (standing == RcsStanding.unavailable) return const [];

    final holder = messagingAppName(status.defaultPackage) ?? 'Another app';

    return [
      SettingsSectionHeader(
        title: 'RCS',
        subtitle: switch (standing) {
          RcsStanding.withGoogleMessages =>
            'Google Messages holds the messaging role, so this phone has RCS. '
                'Braid cannot take that over: Android has no RCS API for a '
                'third-party app — RCS is Google Messages talking to Google\'s '
                'network, and only while it is the default. Making Braid your '
                'SMS app would turn RCS off for the whole phone and drop those '
                'conversations back to SMS and MMS.',
          RcsStanding.offForBraid =>
            'This phone sends SMS and MMS, and no RCS. That is not a setting '
                'waiting to be found: Android has no RCS API for a third-party '
                'app, and RCS works only in Google Messages while it holds the '
                'messaging role. To have RCS again, hand the role back.',
          RcsStanding.offForOther =>
            'RCS is already off on this phone. $holder holds the messaging '
                'role and RCS on Android works only in Google Messages, so '
                'making Braid your SMS app costs you no chat features.',
          RcsStanding.unavailable => '',
        },
      ),

      if (standing != RcsStanding.offForOther) ...[
        const SizedBox(height: WeftSpace.sm),
        Text(
          _hasGoogleMessagesBridge
              ? 'The way to have both is the one you are already running: '
                    'leave Google Messages as the default and let your Google '
                    'Messages bridge carry it. RCS and SMS both arrive in this '
                    'inbox that way, and a number that also has a WhatsApp or '
                    'Signal chat can still be merged with them.'
              : 'The way to have both is a bridge rather than the role: '
                    'mautrix-gmessages pairs with Google Messages on this '
                    'phone and puts those conversations — RCS included — in '
                    'this inbox, while Google Messages stays the default app.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],

      if (status.isReady) ...[
        const SizedBox(height: WeftSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Choose a different SMS app'),
            onPressed: _busy ? null : _handBack,
          ),
        ),
      ],
    ];
  }

  /// The sentence under the section header, which is the state in words.
  String _explain(SmsPlatformStatus status) => switch (status.availability) {
    SmsAvailability.ready =>
      'Braid is your default messaging app. Texts arrive in the same inbox as '
          'every bridged network, and a number that also has a WhatsApp or '
          'Signal chat can be merged with it.',
    // Named rather than spelled as a package id where the id is one anybody
    // ships: "Google Messages" is the app the user chose in a settings screen,
    // and `com.google.android.apps.messaging` is not.
    SmsAvailability.notDefault when status.defaultPackage != null =>
      '${messagingAppName(status.defaultPackage)} holds the role. Until that '
          'changes, Braid cannot read or send texts and the SMS network is '
          'absent from your inbox.',
    SmsAvailability.notDefault =>
      'Braid is not your messaging app, so the SMS network is absent from your '
          'inbox. Everything else is unaffected.',
    SmsAvailability.unsupported =>
      'This device cannot hand out the messaging role — it has no telephony, '
          'or the system does not offer the role at all.',
  };

  /// Sends the user to Android's default-apps settings to give the role up.
  Future<void> _handBack() async {
    final repository = ref.read(smsRepositoryProvider);
    if (repository == null) return;
    setState(() => _busy = true);
    try {
      final opened = await repository.openDefaultAppSettings();
      if (!mounted || opened) return;
      // A ROM with neither screen. Rare, and worth saying out loud rather than
      // leaving a button that does nothing.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This device has no default-apps screen to open. The setting is in '
            'Android settings, under default apps.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The one warning worth a dialog: the role is about to end the phone's RCS.
  ///
  /// Only raised when RCS is plausibly on — Google Messages holds the role
  /// right now. Warning when the role is coming from another SMS app would be
  /// warning about nothing, and teaches the user to click through the warning
  /// that matters.
  Future<bool> _confirmLosingRcs(SmsPlatformStatus status) async {
    if (!takingRoleEndsRcs(status.defaultPackage)) return true;

    final bridged = _hasGoogleMessagesBridge;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This turns RCS off'),
        content: Text(
          'Google Messages is your SMS app, so this phone has RCS: typing '
          'indicators, read receipts, full-size photos, group chats that work. '
          'Braid cannot carry any of it — Android has no RCS API for a '
          'third-party app.\n\n'
          'Taking the role turns RCS off for the whole phone. Those '
          'conversations drop back to SMS and MMS'
          '${bridged ? ', and your Google Messages bridge relays through the '
                    'app on this phone, so it stops receiving too' : ''}'
          '.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep RCS'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn RCS off and continue'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _request(SmsChatRepository repository) async {
    if (!await _confirmLosingRcs(repository.status)) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _declined = false;
    });
    try {
      final granted = await repository.requestRole();
      if (!mounted) return;
      setState(() => _declined = !granted);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-reads the role, for the user who granted it in Android's own settings.
  Future<void> _recheck(SmsChatRepository repository) async {
    setState(() => _busy = true);
    try {
      await repository.refreshStatus();
      if (!mounted) return;
      setState(() => _declined = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The role's current state as a chip and a line, in the network's own colour.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});

  final SmsPlatformStatus status;

  @override
  Widget build(BuildContext context) {
    final ready = status.availability == SmsAvailability.ready;
    final color = ready
        ? context.palette.online
        : context.colors.onSurfaceVariant;

    // "On" is a word with no subject. It qualifies *SMS*, and the only thing
    // saying so is a lettermark at the far end of the same row — which is 22dp
    // of nothing to a reader, and reads as "Sm" to one that tries.
    return Semantics(
      container: true,
      label: switch (status.availability) {
        SmsAvailability.ready => 'SMS is on. Braid is your messaging app.',
        SmsAvailability.notDefault =>
          'SMS is off. Braid is not your messaging app.',
        SmsAvailability.unsupported => 'SMS is not available on this device.',
      },
      excludeSemantics: true,
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle_rounded : Icons.sms_failed_outlined,
            size: 20,
            color: color,
          ),
          const SizedBox(width: WeftSpace.sm),
          Text(
            switch (status.availability) {
              SmsAvailability.ready => 'On',
              SmsAvailability.notDefault => 'Off',
              SmsAvailability.unsupported => 'Not available',
            },
            style: context.text.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          NetworkGlyph(network: ChatNetwork.sms, size: 22),
        ],
      ),
    );
  }
}
