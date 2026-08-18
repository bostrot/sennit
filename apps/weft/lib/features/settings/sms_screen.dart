import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
import '../../data/sms_chat_repository.dart';
import '../../services/sms/sms_platform.dart';
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
      appBar: AppBar(
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
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: repository == null
            ? const [
                SettingsMessage(
                  message:
                      'This device has no SMS. Weft carries SMS only on '
                      'Android, where the system can hand one app the '
                      'messaging role — everywhere else your conversations '
                      'arrive over Matrix and its bridges.',
                ),
              ]
            : _body(context, repository),
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
            'can see either network — and Weft cannot change that, because '
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
          'Weft holds the role but not the SMS permissions, so no threads can '
          'be read. Grant them in Android\'s app settings and check again.',
          style: context.text.bodySmall?.copyWith(color: context.colors.error),
        ),
      ],

      if (status.canRequestRole) ...[
        const SizedBox(height: WeftSpace.lg),
        const SettingsSectionHeader(
          title: 'What the role does',
          subtitle:
              'Android gives it all at once. The default app receives every '
              'incoming message, is the only app allowed to write to the '
              'phone\'s message store, and answers the "send a message" action '
              'from your contacts and dialler. Weft writes what it receives '
              'and sends into that same store, so switching back to another '
              'app leaves your history where it was.',
        ),
        const SizedBox(height: WeftSpace.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: const Text('Make Weft the SMS app'),
            onPressed: _busy ? null : () => _request(repository),
          ),
        ),
      ],

      if (_declined) ...[
        const SizedBox(height: WeftSpace.md),
        Text(
          'Nothing changed. Weft is not your SMS app, the SMS network stays '
          'out of your inbox, and every other conversation works exactly as '
          'it did. You can come back here whenever you like.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    ];
  }

  /// The sentence under the section header, which is the state in words.
  String _explain(SmsPlatformStatus status) => switch (status.availability) {
    SmsAvailability.ready =>
      'Weft is your default messaging app. Texts arrive in the same inbox as '
          'every bridged network, and a number that also has a WhatsApp or '
          'Signal chat can be merged with it.',
    SmsAvailability.notDefault when status.defaultPackage != null =>
      'Another app holds the role: ${status.defaultPackage}. Until that '
          'changes, Weft cannot read or send texts and the SMS network is '
          'absent from your inbox.',
    SmsAvailability.notDefault =>
      'Weft is not your messaging app, so the SMS network is absent from your '
          'inbox. Everything else is unaffected.',
    SmsAvailability.unsupported =>
      'This device cannot hand out the messaging role — it has no telephony, '
          'or the system does not offer the role at all.',
  };

  Future<void> _request(SmsChatRepository repository) async {
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

    return Row(
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
    );
  }
}
