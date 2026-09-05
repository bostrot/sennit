import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart' show PushRuleChange;
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/notification_providers.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../../services/notifications/push_registration.dart';
import '../../services/notifications/unified_push.dart';
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
  on,
  muted,
  off;

  String label(AppL10n l10n) => switch (this) {
    _NetworkMode.on => l10n.notificationsModeOn,
    _NetworkMode.muted => l10n.notificationsModeMuted,
    _NetworkMode.off => l10n.notificationsModeOff,
  };
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
      appBar: WeftAppBar(title: Text(context.l10n.notificationsTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            const _BuiltInConnectionSection(),
            const _UnifiedPushSection(),
            SwitchListTile(
              title: Text(context.l10n.notificationsTitle),
              subtitle: Text(context.l10n.notificationsMasterSubtitle),
              value: policy.enabled,
              onChanged: (v) => _update((p) => p.copyWith(enabled: v)),
              contentPadding: EdgeInsets.zero,
            ),

            if (policy.enabled) ...[
              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.settingsNetworksSectionTitle,
                subtitle: context.l10n.notificationsNetworksSubtitle,
              ),
              for (final network in networks)
                _NetworkRow(
                  network: network,
                  mode: _modeFor(policy, network),
                  onChanged: (mode) => _setNetworkMode(network, mode),
                ),
              if (networks.isEmpty)
                Text(
                  context.l10n.notificationsNoBridges,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.notificationsWhatGetsThroughTitle,
                subtitle: context.l10n.notificationsWhatGetsThroughSubtitle,
              ),
              SwitchListTile(
                title: Text(context.l10n.notificationsMentionsOnlyTitle),
                subtitle: Text(context.l10n.notificationsMentionsOnlySubtitle),
                value: policy.mentionsOnly,
                onChanged: (v) => _update((p) => p.copyWith(mentionsOnly: v)),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: Text(context.l10n.notificationsMentionsBypassTitle),
                subtitle: Text(
                  context.l10n.notificationsMentionsBypassSubtitle,
                ),
                value: policy.mentionsBypassMute,
                onChanged: (v) =>
                    _update((p) => p.copyWith(mentionsBypassMute: v)),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: Text(context.l10n.notificationsShowPreviewsTitle),
                subtitle: Text(context.l10n.notificationsShowPreviewsSubtitle),
                value: policy.showPreviews,
                onChanged: (v) => _update((p) => p.copyWith(showPreviews: v)),
                contentPadding: EdgeInsets.zero,
              ),
              const _SmartRepliesTile(),

              const Divider(height: WeftSpace.xl),
              SettingsSectionHeader(
                title: context.l10n.notificationsQuietHoursTitle,
                subtitle: context.l10n.notificationsQuietHoursSubtitle,
              ),
              SwitchListTile(
                title: Text(context.l10n.notificationsQuietHoursTitle),
                value: quiet != null,
                onChanged: (v) => _update(
                  (p) =>
                      p.copyWith(quietHours: v ? _defaultQuietHours() : null),
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
                  label: context.l10n.notificationsQuietStartLabel,
                  value: _formatMinute(context, quiet.startMinute),
                  title: context.l10n.notificationsQuietFrom,
                  onTap: () => _pickQuietHour(start: true),
                ),
                _QuietHourTile(
                  icon: Icons.wb_sunny_outlined,
                  label: context.l10n.notificationsQuietEndLabel,
                  value: _formatMinute(context, quiet.endMinute),
                  title: context.l10n.notificationsQuietUntil,
                  onTap: () => _pickQuietHour(start: false),
                ),
                SwitchListTile(
                  title: Text(context.l10n.notificationsLetMentionsThrough),
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
                  title: Text(context.l10n.notificationsDeliverSilentlyTitle),
                  subtitle: Text(
                    context.l10n.notificationsDeliverSilentlySubtitle,
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
              SettingsSectionHeader(
                title: context.l10n.notificationsMutedChatsTitle,
                subtitle: context.l10n.notificationsMutedChatsSubtitle,
              ),
              _MutedChats(policy: policy, chats: chats),
            ],

            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: context.l10n.notificationsPushTitle,
              subtitle: context.l10n.notificationsPushSubtitle,
            ),
            const _PushStatus(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: WeftSpace.md),
              child: TextField(
                controller: _gateway,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: context.l10n.notificationsGatewayField,
                  hintText: 'https://sygnal.example.org/_matrix/push/v1/notify',
                ),
                onSubmitted: (_) => _saveGateway(),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                onPressed: _saveGateway,
                child: Text(context.l10n.notificationsSaveGateway),
              ),
            ),

            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: context.l10n.notificationsTestTitle,
              subtitle: context.l10n.notificationsTestSubtitle,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: _testing ? null : () => unawaited(_sendTest()),
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: Text(context.l10n.notificationsSendTest),
              ),
            ),
            if (_test case final result?) ...[
              const SizedBox(height: WeftSpace.md),
              _TestResult(decision: result.decision, network: result.network),
            ],
          ],
        ),
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
      hint: context.l10n.notificationsChangeTimeHint,
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
                    label: context.l10n.notificationsNetworkMode(
                      network.label,
                      option.label(context.l10n),
                    ),
                    excludeSemantics: true,
                    child: Text(option.label(context.l10n)),
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
        context.l10n.notificationsNothingMuted,
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
                context.l10n,
                policy.overrideFor(id),
                onServer: serverMuted.contains(id),
                now: now,
              ),
            ),
            trailing: TextButton(
              onPressed: () => unawaited(
                _unmute(ref, id, onServer: serverMuted.contains(id)),
              ),
              child: Text(context.l10n.commonUnmute),
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
        value.message ?? _pushStatusLabel(context.l10n, value.status),
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
        child: Text(context.l10n.commonRetry),
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
      NotifyDecision() => context.l10n.notificationsTestPosted(network.label),
      SilentDecision() => context.l10n.notificationsTestSilent,
      SuppressedDecision(:final reason) =>
        context.l10n.notificationsTestSuppressed(
          _suppressionLabel(context.l10n, reason),
        ),
    };

    // This box is the whole result of pressing "Send test notification", and it
    // appears below the fold on a phone. Live, and the delivered/blocked state
    // is said in words rather than left to a green tick and a red panel — the
    // two differ only in colour otherwise.
    return Semantics(
      liveRegion: true,
      container: true,
      label: delivered
          ? context.l10n.notificationsTestDelivered(text)
          : context.l10n.notificationsTestBlocked(text),
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
  AppL10n l10n,
  ChatNotificationOverride override, {
  required bool onServer,
  required DateTime now,
}) {
  final parts = <String>[];
  if (override.muted) {
    parts.add(l10n.notificationsMutedInApp);
  } else if (override.mutedUntil case final until?) {
    parts.add(
      l10n.notificationsMutedFor(_remaining(l10n, until.difference(now))),
    );
  }
  if (onServer) parts.add(l10n.notificationsMutedOnServer);
  return parts.isEmpty ? l10n.notificationsMuted : parts.join(' · ');
}

/// Rounded up, never down: "for another 0 minutes" on a mute that is still in
/// force reads as a bug in the mute.
String _remaining(AppL10n l10n, Duration left) {
  if (left.inHours >= 1) return l10n.notificationsRemainingHours(left.inHours);
  final minutes = left.inMinutes + (left.inSeconds % 60 == 0 ? 0 : 1);
  return l10n.notificationsRemainingMinutes(minutes < 1 ? 1 : minutes);
}

String _pushStatusLabel(AppL10n l10n, PushRegistrationStatus status) =>
    switch (status) {
      PushRegistrationStatus.registered ||
      PushRegistrationStatus.unchanged => l10n.pushStatusRegistered,
      PushRegistrationStatus.unsupportedPlatform => l10n.pushStatusUnsupported,
      PushRegistrationStatus.notConfigured => l10n.pushStatusNotConfigured,
      PushRegistrationStatus.noToken => l10n.pushStatusNoToken,
      PushRegistrationStatus.failed => l10n.pushStatusFailed,
    };

/// The rule that fired, named as the setting the user would go and change.
///
/// `evaluateNotification` reports the *first* rule that matched rather than all
/// of them, which is what makes this a single actionable sentence instead of a
/// list of everything currently silencing a message.
String _suppressionLabel(
  AppL10n l10n,
  NotificationSuppression reason,
) => switch (reason) {
  NotificationSuppression.globallyDisabled => l10n.suppressionGloballyDisabled,
  NotificationSuppression.networkDisabled => l10n.suppressionNetworkDisabled,
  NotificationSuppression.networkMuted => l10n.suppressionNetworkMuted,
  NotificationSuppression.chatMuted => l10n.suppressionChatMuted,
  NotificationSuppression.sourceMuted => l10n.suppressionSourceMuted,
  NotificationSuppression.mentionsOnly => l10n.suppressionMentionsOnly,
  NotificationSuppression.quietHours => l10n.suppressionQuietHours,
  // The remaining reasons cannot fire for a synthetic message — it is not
  // yours, not redacted, not a state event, has no read marker and is not
  // deduped — so there is nothing for the user to act on if one ever does.
  _ => l10n.suppressionUnexpected(reason.name),
};

/// Background push over UnifiedPush — the self-hosted answer to "messages
/// while the app is closed". Android only; a build without a distributor
/// installed gets the sentence saying which app to install.
/// The gate for AI answer chips on message notifications.
///
/// Disabled with the reason spelled out until an LLM endpoint exists —
/// flipping a switch that silently does nothing is the failure this avoids.
class _SmartRepliesTile extends ConsumerWidget {
  const _SmartRepliesTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsRevisionProvider);
    SettingsStore? found;
    try {
      found = ref.watch(storesProvider).settings;
    } on Object {
      found = null;
    }
    final settings = found;
    final configured =
        (settings?.getString(WeftSettings.llmBaseUrl) ?? '')
            .trim()
            .isNotEmpty &&
        (settings?.getString(WeftSettings.llmModel) ?? '').trim().isNotEmpty;
    final enabled =
        settings?.getBool(WeftSettings.notifySmartReplies, fallback: true) ??
        false;

    return SwitchListTile(
      title: Text(context.l10n.notificationsSmartRepliesTitle),
      subtitle: Text(
        configured
            ? context.l10n.notificationsSmartRepliesSubtitle
            : context.l10n.notificationsSmartRepliesDisabled,
      ),
      value: enabled && configured,
      onChanged: !configured || settings == null
          ? null
          : (v) {
              settings.setBool(WeftSettings.notifySmartReplies, value: v);
              ref.read(settingsRevisionProvider.notifier).bump();
            },
      contentPadding: EdgeInsets.zero,
    );
  }
}

/// The no-extra-app answer to background messages.
///
/// A switch over the native `WeftSyncService`: Braid itself holds the one
/// connection the OS allows a reachable app (a specialUse foreground
/// service), so messages arrive with the app closed and nothing else
/// installed. The battery row appears while Doze could still cut the
/// connection's network — the exemption dialog is the system's, and refusing
/// it degrades delivery during deep sleep rather than breaking the feature.
class _BuiltInConnectionSection extends ConsumerStatefulWidget {
  const _BuiltInConnectionSection();

  @override
  ConsumerState<_BuiltInConnectionSection> createState() =>
      _BuiltInConnectionSectionState();
}

class _BuiltInConnectionSectionState
    extends ConsumerState<_BuiltInConnectionSection>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.bostrot.weft/sync_control');

  bool _enabled = false;
  bool _batteryExempt = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The battery-exemption dialog is a system activity; its answer is only
    // readable once the user comes back.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await _channel.invokeMethod<Map<Object?, Object?>>(
        'status',
      );
      if (!mounted || status == null) return;
      setState(() {
        _enabled = status['enabled'] == true;
        _batteryExempt = status['batteryExempt'] == true;
      });
    } on Object {
      // No native side — desktop, or a test. The section stays hidden via
      // the platform check in build.
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    // A connection that cannot post is worse than none: it costs battery and
    // delivers silence. So turning it on walks the two permissions in order —
    // notifications first (spending the one OS prompt only if it is still
    // unspent), then the battery exemption, each behind a sentence saying why.
    if (enabled && !await _ensureNotificationsAllowed()) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on Object catch (error) {
      debugPrint('weft: could not toggle the connection service: $error');
    }
    await _refresh();
    if (enabled && mounted && !_batteryExempt) await _walkBatteryExemption();
  }

  /// True when Braid may post notifications — asking if the one prompt is
  /// still unspent, and pointing at system settings when it is not.
  Future<bool> _ensureNotificationsAllowed() async {
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return true;
    if (await android.areNotificationsEnabled() ?? true) return true;

    final granted = await android.requestNotificationsPermission() ?? false;
    try {
      markNotificationPermissionAsked(ref.read(storesProvider).settings);
    } on Object {
      // No stores in a test; the bookkeeping is best-effort.
    }
    if (granted || !mounted) return granted;

    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.notificationsBlockedTitle),
        content: Text(context.l10n.notificationsBlockedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.notificationsOpenSettings),
          ),
        ],
      ),
    );
    if (open == true) {
      await _channel
          .invokeMethod<void>('openNotificationSettings')
          .catchError((Object e) {});
    }
    return false;
  }

  /// The one-more-step moment right after enabling: explains the battery
  /// dialog before Android shows it, so the system prompt is never the first
  /// the user hears of it. Declining costs delivery during deep sleep, and
  /// the row below the switch stays as the way back in.
  Future<void> _walkBatteryExemption() async {
    final wanted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.notificationsBatteryTitle),
        content: Text(context.l10n.notificationsBatteryBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.commonContinue),
          ),
        ],
      ),
    );
    if (wanted == true) {
      await _channel
          .invokeMethod<void>('requestBatteryExemption')
          .catchError((Object e) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!NotificationPlatform.isAndroid) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.lg),
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(
              _enabled ? Icons.sync_rounded : Icons.sync_disabled_rounded,
              color: _enabled
                  ? context.palette.online
                  : context.colors.onSurfaceVariant,
            ),
            title: Text(context.l10n.notificationsStayConnectedTitle),
            subtitle: Text(context.l10n.notificationsStayConnectedSubtitle),
            value: _enabled,
            onChanged: (v) => unawaited(_setEnabled(v)),
          ),
          if (_enabled && !_batteryExempt)
            ListTile(
              leading: Icon(
                Icons.battery_alert_rounded,
                color: context.colors.error,
              ),
              title: Text(context.l10n.notificationsBatteryToggleTitle),
              subtitle: Text(context.l10n.notificationsBatteryToggleSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(
                _channel
                    .invokeMethod<void>('requestBatteryExemption')
                    .catchError((Object e) {}),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnifiedPushSection extends ConsumerStatefulWidget {
  const _UnifiedPushSection();

  @override
  ConsumerState<_UnifiedPushSection> createState() =>
      _UnifiedPushSectionState();
}

class _UnifiedPushSectionState extends ConsumerState<_UnifiedPushSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (!NotificationPlatform.isAndroid) return const SizedBox.shrink();
    ref.watch(settingsRevisionProvider);
    final service = ref.read(unifiedPushServiceProvider);
    final configured = service.isConfigured;

    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.lg),
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  configured
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_paused_outlined,
                  size: 20,
                  color: configured
                      ? context.palette.online
                      : context.colors.onSurfaceVariant,
                ),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    context.l10n.notificationsUnifiedPushTitle,
                    style: context.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.xs),
            Text(
              configured
                  ? context.l10n.notificationsUnifiedPushOn
                  : context.l10n.notificationsUnifiedPushOff,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.md),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : configured
                  ? OutlinedButton(
                      onPressed: () async {
                        setState(() => _busy = true);
                        await service.unregister();
                        ref.read(settingsRevisionProvider.notifier).bump();
                        if (mounted) setState(() => _busy = false);
                      },
                      child: Text(context.l10n.notificationsTurnOff),
                    )
                  : FilledButton.tonal(
                      onPressed: () async {
                        setState(() => _busy = true);
                        final problem = await service.register();
                        ref.read(settingsRevisionProvider.notifier).bump();
                        if (!context.mounted) return;
                        setState(() => _busy = false);
                        if (problem != null) {
                          showWeftMessage(context, problem);
                        } else {
                          showWeftMessage(
                            context,
                            context.l10n.notificationsRegistering,
                          );
                        }
                      },
                      child: Text(context.l10n.notificationsSetUp),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
