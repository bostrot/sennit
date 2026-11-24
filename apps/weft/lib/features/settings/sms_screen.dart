import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft_sms/weft_sms.dart';
import '../../app/localisation.dart';

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

  /// How the last request ended, and null before there has been one.
  ///
  /// An outcome rather than a "declined" flag, because three of the four
  /// answers need different words and the flag could only say one of them: a
  /// decline is a choice, a refusal is a fact about the phone, and an
  /// interrupted request is neither — it is a request whose answer has to be
  /// re-read rather than reported. Collapsing them is what put "Nothing
  /// changed. Sennit is not your SMS app" under a role the system had just
  /// granted.
  ///
  /// Reported in the quiet box rather than a SnackBar that slides away — the
  /// user needs to be able to look at the screen afterwards and see that the
  /// state they are in is the one they chose, not a failure.
  SmsRoleOutcome? _outcome;

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(smsRepositoryProvider);

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.smsTitle),
        actions: [
          if (repository != null)
            IconButton(
              tooltip: context.l10n.smsCheckAgain,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy ? null : () => _recheck(repository),
            ),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: repository == null
              ? [SettingsMessage(message: context.l10n.smsUnsupportedDevice)]
              : _body(context, repository),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, SmsChatRepository repository) {
    final status = repository.status;

    return [
      PrivacyNotice(message: context.l10n.smsPrivacyNotice),
      const SizedBox(height: WeftSpace.lg),

      SettingsSectionHeader(
        title: context.l10n.smsDefaultAppTitle,
        subtitle: _explain(context.l10n, status),
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
          context.l10n.smsMissingPermissions,
          style: context.text.bodySmall?.copyWith(color: context.colors.error),
        ),
      ],

      const SizedBox(height: WeftSpace.lg),
      ..._rcs(context, status),

      if (status.canRequestRole) ...[
        const SizedBox(height: WeftSpace.lg),
        SettingsSectionHeader(
          title: context.l10n.smsRoleTitle,
          subtitle: context.l10n.smsRoleSubtitle,
        ),
        const SizedBox(height: WeftSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: Text(context.l10n.smsMakeSennitDefault),
            onPressed: _busy ? null : () => _request(repository),
          ),
        ),
      ],

      ?_outcomeNote(context, status),
    ];
  }

  /// The sentence for how the last request ended, or nothing to say.
  ///
  /// [SmsRoleOutcome.granted] says nothing here on purpose: the whole screen
  /// has already changed — the status row reads "On", the offer is gone — and a
  /// line announcing it would be the third place saying the same thing.
  /// [SmsRoleOutcome.superseded] says nothing either, because the request that
  /// replaced it is the one still running and it will report for both.
  ///
  /// Takes [status] as well as the outcome so that a phone with no role to give
  /// says so *before* anybody taps: there is no button on such a device, so an
  /// explanation that waited for a request would never be read. It is the same
  /// sentence either way, and it appears once.
  Widget? _outcomeNote(BuildContext context, SmsPlatformStatus status) {
    final unavailable =
        status.availability == SmsAvailability.notDefault &&
        !status.canRequestRole &&
        !status.roleAvailable;

    final message = switch (_outcome) {
      SmsRoleOutcome.denied => context.l10n.smsDeclined,
      SmsRoleOutcome.unavailable => context.l10n.smsRoleUnavailable,
      SmsRoleOutcome.interrupted => context.l10n.smsRoleInterrupted,
      SmsRoleOutcome.granted ||
      SmsRoleOutcome.superseded ||
      null => unavailable ? context.l10n.smsRoleUnavailable : null,
    };
    if (message == null) return null;

    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.md),
      child: Text(
        message,
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
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
  /// app, so this is not a feature Sennit has yet to build; it is one it cannot
  /// have, and saying so is the only useful thing to do about it.
  List<Widget> _rcs(BuildContext context, SmsPlatformStatus status) {
    final standing = rcsStanding(
      supported: status.availability != SmsAvailability.unsupported,
      sennitIsDefault: status.isReady,
      defaultPackage: status.defaultPackage,
    );
    if (standing == RcsStanding.unavailable) return const [];

    final l10n = context.l10n;
    final holder =
        messagingAppName(status.defaultPackage) ?? l10n.smsAnotherApp;

    return [
      SettingsSectionHeader(
        title: l10n.smsRcsTitle,
        subtitle: switch (standing) {
          RcsStanding.withGoogleMessages => l10n.smsRcsWithGoogleMessages,
          RcsStanding.offForSennit => l10n.smsRcsOffForSennit,
          RcsStanding.offForOther => l10n.smsRcsOffForOther(holder),
          RcsStanding.unavailable => '',
        },
      ),

      if (standing != RcsStanding.offForOther) ...[
        const SizedBox(height: WeftSpace.sm),
        Text(
          _hasGoogleMessagesBridge
              ? l10n.smsRcsBothViaBridge
              : l10n.smsRcsBothViaMautrix,
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
            label: Text(l10n.smsChooseDifferentApp),
            onPressed: _busy ? null : _handBack,
          ),
        ),
      ],
    ];
  }

  /// The sentence under the section header, which is the state in words.
  String _explain(AppL10n l10n, SmsPlatformStatus status) =>
      switch (status.availability) {
        SmsAvailability.ready => l10n.smsStateReady,
        // Named rather than spelled as a package id where the id is one
        // anybody ships: "Google Messages" is the app the user chose in a
        // settings screen, and `com.google.android.apps.messaging` is not.
        SmsAvailability.notDefault when status.defaultPackage != null =>
          l10n.smsStateHeldByApp(messagingAppName(status.defaultPackage)!),
        SmsAvailability.notDefault => l10n.smsStateNotDefault,
        SmsAvailability.unsupported => l10n.smsStateUnsupported,
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
        SnackBar(content: Text(context.l10n.smsNoDefaultAppsScreen)),
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
        title: Text(context.l10n.smsRcsDialogTitle),
        content: Text(
          context.l10n.smsRcsDialogBody(
            bridged ? context.l10n.smsRcsDialogBridgeClause : '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.smsKeepRcs),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.smsTurnRcsOff),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Asks for the role and says what came back — whatever came back.
  ///
  /// The repository has already re-read the platform by the time this resolves,
  /// so the status row, the RCS section and the offer below are the phone's
  /// current answer rather than the dialog's. That ordering is the fix: the
  /// screen used to keep pre-dialog state on every outcome but a grant.
  Future<void> _request(SmsChatRepository repository) async {
    if (!await _confirmLosingRcs(repository.status)) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _outcome = null;
    });
    try {
      final outcome = await repository.requestRole();
      if (!mounted) return;
      setState(() => _outcome = outcome);
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
      // The note described an earlier request, and this is a fresh reading of
      // the same question. Keeping it would leave "nothing changed" under a
      // status row that has just changed.
      setState(() => _outcome = null);
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
        SmsAvailability.ready => context.l10n.smsStatusReadySemantics,
        SmsAvailability.notDefault => context.l10n.smsStatusNotDefaultSemantics,
        SmsAvailability.unsupported =>
          context.l10n.smsStatusUnsupportedSemantics,
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
              SmsAvailability.ready => context.l10n.smsStatusOn,
              SmsAvailability.notDefault => context.l10n.smsStatusOff,
              SmsAvailability.unsupported => context.l10n.smsStatusUnavailable,
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
