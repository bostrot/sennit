import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart' show PushRuleChange;
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/notification_providers.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../../services/notifications/push_registration.dart';
import 'settings_section.dart';

/// What the policy says about one network, as a single choice rather than two
/// sets.
///
/// [NotificationPolicy] keeps `disabledNetworks` and `mutedNetworks` apart
/// because they behave differently in ways a user would notice: a mention
/// breaks through a mute and never through a disable, and only a disable is
/// unconditional enough to push down to the homeserver's own push rules. But
/// nobody has two switches in their head for one network — they have one
/// network and three things they might want from it, so that is what the screen
/// offers and this is the mapping between the two shapes.
enum _NetworkMode {
  on('On'),
  muted('Muted'),
  off('Off');

  const _NetworkMode(this.label);

  final String label;
}

/// When to interrupt, and about what.
///
/// Every control here writes straight through [NotificationPolicyNotifier],
/// which persists as it goes — there is no Save button, because a notification
/// setting that only takes effect when you remember to confirm it is a setting
/// you will believe you changed and did not. The one exception is the push
/// gateway, which is free text and so has to be committed deliberately.
///
/// Two things are kept in step from here rather than left to drift. Changing
/// the policy re-runs [reconcilePushRules], because the homeserver's rules stop
/// the *push* while the policy stops the *display* and the doc comment on
/// `NotificationPolicy` puts the responsibility for their agreeing on this
/// screen. And lapsed timed mutes are pruned on open, so the muted-chat list
/// can promise "muted now" rather than "muted at some point".
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  late final TextEditingController _gateway = TextEditingController(
    text: _settings?.getString(WeftSettings.notifyPushGateway) ?? '',
  );

  /// The outcome of the last test, or null if none has been run this visit.
  ({NotificationDecision decision, ChatNetwork network})? _test;
  bool _testing = false;

  SettingsStore? get _settings {
    try {
      return ref.read(storesProvider).settings;
    } on StateError {
      // A widget test pumping this screen without bootstrapping the stores.
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    // After the first frame, not during it: this writes a provider, and doing
    // that while the tree that reads it is building is the classic way to get a
    // rebuild-during-build assertion out of an otherwise harmless tidy-up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(notificationPolicyProvider.notifier).pruneLapsed();
    });
  }

  @override
  void dispose() {
    _gateway.dispose();
    super.dispose();
  }

  /// Applies [change] to the policy as it is *now*, persists the result, and
  /// brings the homeserver's push rules in line with it.
  ///
  /// [change] is a function rather than a finished value, because the
  /// alternative is every callback closing over the policy its frame was built
  /// from. Two writes between one pair of frames would then each start from
  /// that same stale value and the second would silently undo the first — a
  /// class of bug that is invisible in use, since a rebuild almost always lands
  /// in between, and which this shape cannot express at all.
  ///
  /// Reconciliation is fire-and-forget on purpose: it is a network round trip
  /// per changed room, and a switch that spun for two seconds before moving
  /// would be a worse lie than a rule that lands a moment late. A refused write
  /// is retried on the next pass, because the plan is recomputed from server
  /// state rather than remembered.
  void _update(NotificationPolicy Function(NotificationPolicy) change) {
    final next = change(ref.read(notificationPolicyProvider));
    ref.read(notificationPolicyProvider.notifier).update(next);
    unawaited(
      reconcilePushRules(
        session: ref.read(matrixSessionProvider),
        policy: next,
        chats: ref.read(chatsProvider).value ?? const [],
      ).catchError((Object error) {
        debugPrint('weft: could not reconcile push rules: $error');
        return const <PushRuleChange>[];
      }),
    );
  }

  void _setNetworkMode(ChatNetwork network, _NetworkMode mode) {
    _update(
      (policy) => policy.copyWith(
        disabledNetworks: {
          ...policy.disabledNetworks.where((n) => n != network),
          if (mode == _NetworkMode.off) network,
        },
        mutedNetworks: {
          ...policy.mutedNetworks.where((n) => n != network),
          if (mode == _NetworkMode.muted) network,
        },
      ),
    );
  }

  Future<void> _pickQuietHour({required bool start}) async {
    final current = ref.read(notificationPolicyProvider).quietHours;
    final from = current ?? _defaultQuietHours();
    final minute = start ? from.startMinute : from.endMinute;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (picked == null || !mounted) return;

    final chosen = picked.hour * 60 + picked.minute;
    _update(
      (policy) => policy.copyWith(
        quietHours: (policy.quietHours ?? from).copyWith(
          startMinute: start ? chosen : null,
          endMinute: start ? null : chosen,
          // Re-stamped on every edit rather than only on creation. The window
          // is a time of day and the offset is how a background isolate — which
          // has no reason to share this isolate's timezone — reaches the same
          // verdict; a user who set 22:00 at home and then flew somewhere would
          // otherwise keep last month's offset.
          offsetMinutes: clock.now().timeZoneOffset.inMinutes,
        ),
      ),
    );
  }

  Future<void> _sendTest() async {
    setState(() {
      _testing = true;
      _test = null;
    });
    try {
      final service = await ref.read(notificationServiceProvider.future);
      final network =
          ref.read(chatRepositoryProvider).availableNetworks.firstOrNull ??
          ChatNetwork.matrix;
      final decision = await service?.sendTestNotification(network: network);
      if (!mounted || decision == null) return;
      setState(() => _test = (decision: decision, network: network));
    } on Object catch (error) {
      debugPrint('weft: test notification failed: $error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _saveGateway() {
    _settings?.setString(WeftSettings.notifyPushGateway, _gateway.text.trim());
    ref.read(settingsRevisionProvider.notifier).bump();
    // The pusher is registered from the gateway URL, so a new one has to be
    // registered afresh. Invalidating is the whole retry button.
    ref.invalidate(pushRegistrationProvider);
  }

  @override
  Widget build(BuildContext context) {
    final policy = ref.watch(notificationPolicyProvider);
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final networks = ref.watch(chatRepositoryProvider).availableNetworks;
    final quiet = policy.quietHours;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          SwitchListTile(
            title: const Text('Notifications'),
            subtitle: const Text(
              'The master switch. Off means nothing is posted, on any device '
              'this app is running on.',
            ),
            value: policy.enabled,
            onChanged: (v) => _update((p) => p.copyWith(enabled: v)),
            contentPadding: EdgeInsets.zero,
          ),

          if (policy.enabled) ...[
            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Networks',
              subtitle:
                  'Muted still lets a mention through, if the setting below '
                  'allows it. Off does not — off is off.',
            ),
            for (final network in networks)
              _NetworkRow(
                network: network,
                mode: _modeFor(policy, network),
                onChanged: (mode) => _setNetworkMode(network, mode),
              ),
            if (networks.isEmpty)
              Text(
                'No bridges are configured yet, so there is nothing to switch '
                'off. Networks appear here as they connect.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),

            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'What gets through',
              subtitle:
                  'Applies everywhere. A single chat can disagree with this '
                  'from its own screen.',
            ),
            SwitchListTile(
              title: const Text('Only notify for mentions'),
              subtitle: const Text(
                'Matches your name, your Matrix id, the name each bridge gives '
                'you, and @room.',
              ),
              value: policy.mentionsOnly,
              onChanged: (v) => _update((p) => p.copyWith(mentionsOnly: v)),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              title: const Text('Mentions break through a mute'),
              subtitle: const Text(
                'On: mute a busy group and still get paged in it. Off: a mute '
                'is silence, which is what Matrix itself means by one.',
              ),
              value: policy.mentionsBypassMute,
              onChanged: (v) =>
                  _update((p) => p.copyWith(mentionsBypassMute: v)),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              title: const Text('Show message text on the lock screen'),
              subtitle: const Text(
                'Off still notifies — it says "New message" instead of what was '
                'said. The sender and the chat are still shown.',
              ),
              value: policy.showPreviews,
              onChanged: (v) => _update((p) => p.copyWith(showPreviews: v)),
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Quiet hours',
              subtitle:
                  'A time of day that recurs, stored with your UTC offset so a '
                  'notification decided in the background agrees with one '
                  'decided while the app is open.',
            ),
            SwitchListTile(
              title: const Text('Quiet hours'),
              value: quiet != null,
              onChanged: (v) => _update(
                (p) => p.copyWith(quietHours: v ? _defaultQuietHours() : null),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            if (quiet != null) ...[
              // A time is a *value*, and "From 22:00" read as a label is a
              // statement rather than something a reader knows they can change.
              // The hint is what makes the row an editable setting instead of a
              // fact about the screen.
              _QuietHourTile(
                icon: Icons.bedtime_outlined,
                label: 'Quiet hours start',
                value: _formatMinute(context, quiet.startMinute),
                title: 'From',
                onTap: () => _pickQuietHour(start: true),
              ),
              _QuietHourTile(
                icon: Icons.wb_sunny_outlined,
                label: 'Quiet hours end',
                value: _formatMinute(context, quiet.endMinute),
                title: 'Until',
                onTap: () => _pickQuietHour(start: false),
              ),
              SwitchListTile(
                title: const Text('Let mentions through'),
                value: quiet.allowMentions,
                onChanged: (v) => _update(
                  (p) => p.copyWith(
                    quietHours: (p.quietHours ?? quiet).copyWith(
                      allowMentions: v,
                    ),
                  ),
                ),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: const Text('Deliver silently instead of hiding'),
                subtitle: const Text(
                  'The notification is waiting in the shade in the morning, '
                  'without having made a sound.',
                ),
                value: quiet.deliverSilently,
                onChanged: (v) => _update(
                  (p) => p.copyWith(
                    quietHours: (p.quietHours ?? quiet).copyWith(
                      deliverSilently: v,
                    ),
                  ),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],

            const Divider(height: WeftSpace.xl),
            const SettingsSectionHeader(
              title: 'Muted chats',
              subtitle:
                  'Everything currently silenced, whichever way it was muted. '
                  'A timed mute is Weft\'s own — Matrix push rules cannot '
                  'express an expiry.',
            ),
            _MutedChats(policy: policy, chats: chats),
          ],

          const Divider(height: WeftSpace.xl),
          const SettingsSectionHeader(
            title: 'Push',
            subtitle:
                'How this device is woken when Weft is not running. Weft hosts '
                'no gateway; point this at a sygnal instance you run, exactly '
                'as you do your homeserver. Left empty, notifications still '
                'arrive while the app is open.',
          ),
          const _PushStatus(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: WeftSpace.md),
            child: TextField(
              controller: _gateway,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Push gateway',
                hintText: 'https://sygnal.example.org/_matrix/push/v1/notify',
              ),
              onSubmitted: (_) => _saveGateway(),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonal(
              onPressed: _saveGateway,
              child: const Text('Save gateway'),
            ),
          ),

          const Divider(height: WeftSpace.xl),
          const SettingsSectionHeader(
            title: 'Check it works',
            subtitle:
                'Runs a message Weft made up through the same rules, the same '
                'rendering and the same channel a real one takes. If nothing '
                'appears, the reason is below.',
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: _testing ? null : () => unawaited(_sendTest()),
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text('Send test notification'),
            ),
          ),
          if (_test case final result?) ...[
            const SizedBox(height: WeftSpace.md),
            _TestResult(decision: result.decision, network: result.network),
          ],
        ],
      ),
    );
  }
}

/// One end of the quiet-hours window, as a value a reader can act on.
class _QuietHourTile extends StatelessWidget {
  const _QuietHourTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.title,
    required this.onTap,
  });

  final IconData icon;

  /// The accessible name. "From" is only meaningful next to "Until", which is
  /// exactly the relationship a reader landing on one row does not have.
  final String label;
  final String value;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: label,
      value: value,
      hint: 'change the time',
      excludeSemantics: true,
      // Restated because excluding the subtree excludes the `ListTile`'s own
      // tap action with it.
      onTap: onTap,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        trailing: Text(value, style: context.text.titleMedium),
        onTap: onTap,
      ),
    );
  }
}

/// One network, and the three things the policy can say about it.
class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.network,
    required this.mode,
    required this.onChanged,
  });

  final ChatNetwork network;
  final _NetworkMode mode;
  final ValueChanged<_NetworkMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // The title beside it is the network's name; a labelled glyph is that
      // name a second time.
      leading: NetworkGlyph(network: network, size: 28, semanticsLabel: ''),
      title: Text(network.label),
      // The control sits in the subtitle rather than the trailing slot so it
      // gets the tile's full width: three segments plus a network name does not
      // fit on one line of a narrow phone, and an overflowing settings row is
      // an unusable one.
      subtitle: Padding(
        padding: const EdgeInsets.only(top: WeftSpace.xs),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: SegmentedButton<_NetworkMode>(
            showSelectedIcon: false,
            // No compact density. It took 8dp off each axis of the segments'
            // tap targets, leaving three 40dp buttons — three adjacent choices
            // where the neighbour of "Muted" is "Off", and a miss silences a
            // network rather than quieting it.
            segments: [
              for (final option in _NetworkMode.values)
                ButtonSegment(
                  value: option,
                  // Each segment names its network. A tile announcing
                  // "WhatsApp" and then three loose buttons reading "On",
                  // "Muted", "Off" leaves a reader on a screen of nine
                  // identical words and no way to tell which three belong to
                  // the row they are in.
                  label: Semantics(
                    label: '${network.label}: ${option.label}',
                    excludeSemantics: true,
                    child: Text(option.label),
                  ),
                ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
      ),
    );
  }
}

/// Every chat currently silenced, from both places a mute can live.
///
/// The policy's own overrides *and* `Chat.muted`, which is the homeserver's
/// push rule as written by `ChatRepository.setMuted` from the chat screen.
/// Listing only the first would leave a user who muted a chat the ordinary way
/// looking at an empty list while their phone stayed quiet — which reads as a
/// bug in the mute, not as a gap in this screen.
class _MutedChats extends ConsumerWidget {
  const _MutedChats({required this.policy, required this.chats});

  final NotificationPolicy policy;
  final List<Chat> chats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = clock.now();
    final titles = {for (final chat in chats) chat.id: chat.title};
    final serverMuted = {
      for (final chat in chats)
        if (chat.muted) chat.id,
    };

    final ids = <String>{
      ...policy.chats.entries
          .where((e) => e.value.isMutedAt(now))
          .map((e) => e.key),
      ...serverMuted,
    }.toList()..sort((a, b) => (titles[a] ?? a).compareTo(titles[b] ?? b));

    if (ids.isEmpty) {
      return Text(
        'Nothing is muted.',
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      );
    }

    return Column(
      children: [
        for (final id in ids)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_off_outlined),
            // A chat the inbox has not resolved — archived, or not yet synced —
            // shows its id rather than vanishing from a list of things that are
            // silencing it.
            title: Text(titles[id] ?? id),
            subtitle: Text(
              _muteDetail(
                policy.overrideFor(id),
                onServer: serverMuted.contains(id),
                now: now,
              ),
            ),
            trailing: TextButton(
              onPressed: () => unawaited(
                _unmute(ref, id, onServer: serverMuted.contains(id)),
              ),
              child: const Text('Unmute'),
            ),
          ),
      ],
    );
  }

  /// Lifts the mute wherever it is, not wherever it was easiest to find.
  ///
  /// A chat muted both ways — silenced from the chat screen and then again for
  /// an hour from a notification action — has to lose both, or the button is a
  /// button that visibly does nothing.
  Future<void> _unmute(
    WidgetRef ref,
    String chatId, {
    required bool onServer,
  }) async {
    if (policy.overrideFor(chatId).isMutedAt(clock.now())) {
      ref.read(notificationPolicyProvider.notifier).unmuteChat(chatId);
    }
    if (onServer) {
      try {
        await ref.read(chatRepositoryProvider).setMuted(chatId, muted: false);
      } on Object catch (error) {
        debugPrint('weft: could not unmute $chatId on the server: $error');
      }
    }
  }
}

/// Whether push is set up, in one sentence the user can act on.
class _PushStatus extends ConsumerWidget {
  const _PushStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outcome = ref.watch(pushRegistrationProvider);

    // `AsyncLoading` first, because a reload that keeps its previous value
    // would otherwise match the data arm and show a stale status as settled.
    // `PushRegistrationOutcome` is non-nullable, so the `value?` arm covers
    // every remaining case and there is no fallback to write.
    final (icon, text) = switch (outcome) {
      AsyncLoading() => (Icons.hourglass_empty_rounded, 'Checking…'),
      AsyncError(:final error) => (Icons.error_outline, '$error'),
      AsyncValue(:final value?) => (
        value.isRegistered
            ? Icons.check_circle_outline
            : Icons.info_outline_rounded,
        value.message ?? _pushStatusLabel(value.status),
      ),
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ExcludeSemantics(child: Icon(icon)),
      // Live: this line is the answer to "did Retry do anything?", and Retry
      // leaves the button, the row and the glyph looking exactly as they were
      // apart from the sentence.
      title: Semantics(liveRegion: true, child: Text(text)),
      trailing: TextButton(
        onPressed: () => ref.invalidate(pushRegistrationProvider),
        child: const Text('Retry'),
      ),
    );
  }
}

/// What the test notification decided, in the user's terms.
class _TestResult extends StatelessWidget {
  const _TestResult({required this.decision, required this.network});

  final NotificationDecision decision;
  final ChatNetwork network;

  @override
  Widget build(BuildContext context) {
    final delivered = decision.delivers;
    final text = switch (decision) {
      NotifyDecision() =>
        'Posted on the ${network.label} channel. If nothing '
            'appeared, the block is the operating system rather than Weft — '
            'check its notification settings for this app.',
      SilentDecision() =>
        'Posted silently: quiet hours are in force and set to deliver without '
            'a sound. It is in the shade rather than on your screen.',
      SuppressedDecision(:final reason) =>
        'Nothing was posted. ${_suppressionLabel(reason)}',
    };

    // This box is the whole result of pressing "Send test notification", and it
    // appears below the fold on a phone. Live, and the delivered/blocked state
    // is said in words rather than left to a green tick and a red panel — the
    // two differ only in colour otherwise.
    return Semantics(
      liveRegion: true,
      container: true,
      label: '${delivered ? 'Delivered' : 'Blocked'}. $text',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(WeftSpace.md),
        decoration: BoxDecoration(
          color: delivered
              ? context.colors.surfaceContainerHigh
              : context.colors.errorContainer.withValues(alpha: 0.5),
          borderRadius: WeftRadius.allMd,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              delivered ? Icons.check_circle_outline : Icons.block_outlined,
              size: 20,
              color: delivered
                  ? context.palette.online
                  : context.colors.onErrorContainer,
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(child: Text(text, style: context.text.bodySmall)),
          ],
        ),
      ),
    );
  }
}

_NetworkMode _modeFor(NotificationPolicy policy, ChatNetwork network) {
  if (!policy.isNetworkEnabled(network)) return _NetworkMode.off;
  if (policy.isNetworkMuted(network)) return _NetworkMode.muted;
  return _NetworkMode.on;
}

/// 22:00 to 07:00 — the window people mean when they say "quiet hours", and a
/// starting point they can edit rather than an empty pair of pickers.
QuietHours _defaultQuietHours() => QuietHours(
  startMinute: 22 * 60,
  endMinute: 7 * 60,
  offsetMinutes: clock.now().timeZoneOffset.inMinutes,
);

String _formatMinute(BuildContext context, int minute) =>
    TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

/// Why one chat is silent, said once however many mutes are on it.
String _muteDetail(
  ChatNotificationOverride override, {
  required bool onServer,
  required DateTime now,
}) {
  final parts = <String>[];
  if (override.muted) {
    parts.add('Muted in Weft');
  } else if (override.mutedUntil case final until?) {
    parts.add('Muted for another ${_remaining(until.difference(now))}');
  }
  if (onServer) parts.add('Muted on the homeserver');
  return parts.isEmpty ? 'Muted' : parts.join(' · ');
}

/// Rounded up, never down: "for another 0 minutes" on a mute that is still in
/// force reads as a bug in the mute.
String _remaining(Duration left) {
  if (left.inHours >= 1) {
    final hours = left.inHours;
    return '$hours hour${hours == 1 ? '' : 's'}';
  }
  final minutes = left.inMinutes + (left.inSeconds % 60 == 0 ? 0 : 1);
  final clamped = minutes < 1 ? 1 : minutes;
  return '$clamped minute${clamped == 1 ? '' : 's'}';
}

String _pushStatusLabel(PushRegistrationStatus status) => switch (status) {
  PushRegistrationStatus.registered => 'Registered with your homeserver.',
  PushRegistrationStatus.unchanged => 'Registered with your homeserver.',
  PushRegistrationStatus.unsupportedPlatform =>
    'This platform has no push. Notifications arrive while Weft is running.',
  PushRegistrationStatus.notConfigured =>
    'No push gateway configured, so this device is not woken.',
  PushRegistrationStatus.noToken =>
    'Waiting for a token from the operating system.',
  PushRegistrationStatus.failed => 'Registration failed.',
};

/// The rule that fired, named as the setting the user would go and change.
///
/// `evaluateNotification` reports the *first* rule that matched rather than all
/// of them, which is what makes this a single actionable sentence instead of a
/// list of everything currently silencing a message.
String _suppressionLabel(NotificationSuppression reason) => switch (reason) {
  NotificationSuppression.globallyDisabled =>
    'Notifications are switched off at the top of this screen.',
  NotificationSuppression.networkDisabled =>
    'That network is set to Off, and nothing breaks through Off.',
  NotificationSuppression.networkMuted => 'That network is muted.',
  NotificationSuppression.chatMuted => 'That chat is muted.',
  NotificationSuppression.sourceMuted =>
    'That chat is muted on the network the message arrived on.',
  NotificationSuppression.mentionsOnly =>
    'Only mentions get through, and a test message does not mention you.',
  NotificationSuppression.quietHours => 'Quiet hours are in force.',
  // The remaining reasons cannot fire for a synthetic message — it is not
  // yours, not redacted, not a state event, has no read marker and is not
  // deduped — so there is nothing for the user to act on if one ever does.
  _ =>
    'It was suppressed as ${reason.name}, which should not happen for a '
        'test. Please report it.',
};
