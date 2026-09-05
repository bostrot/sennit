import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// Why a message produced no notification.
///
/// Every value here is a rule a user can reason about — "I muted that", "I read
/// it on my laptop" — which is the point of naming them rather than returning a
/// bare bool: when someone reports a missed message, the reason is the whole
/// diagnosis.
enum NotificationSuppression {
  /// The user sent it themselves. Their own echo must never buzz.
  ownMessage,

  /// The event was redacted. `mapEvent` blanks the body of a redaction, so
  /// notifying would show an empty message for something already deleted.
  redacted,

  /// A state/membership event rather than something a person said.
  nonMessageEvent,

  /// Notifications are off globally.
  globallyDisabled,

  /// The message is not newer than the read marker, so it was already read —
  /// almost always on another device, since a push and a read racing on *this*
  /// device is the same fact arriving twice.
  alreadyRead,

  /// This event id has already been decided on. A message reaching the app by
  /// both push and sync is the normal case, not an error.
  duplicate,

  /// The whole network is switched off in the policy.
  networkDisabled,

  /// The network is muted. Unlike [networkDisabled] a mention can break through
  /// this, subject to [NotificationPolicy.mentionsBypassMute].
  networkMuted,

  /// The chat is muted, either indefinitely or until an expiry that has not
  /// passed yet.
  chatMuted,

  /// This chat is not muted as a whole, but the *leg* the message arrived on
  /// is. A merged contact muted on WhatsApp and live on Signal lands here.
  sourceMuted,

  /// Mentions-only mode is on for this chat and the body does not mention the
  /// user.
  mentionsOnly,

  /// Quiet hours are in force and nothing exempted this message from them.
  quietHours,

  /// The conversation is a pending request and this is not its first message.
  ///
  /// A stranger gets one quiet notification and then nothing. Without this,
  /// anyone who can find the user's handle can put forty rows in their shade by
  /// sending forty messages — the request would be *held out of the inbox* and
  /// still ringing the phone, which is the worst of both.
  pendingRequest,
}

/// A nightly window in which notifications do not arrive.
///
/// Held as minutes-since-midnight plus a fixed UTC offset rather than as a
/// `DateTime` pair, because the window is a *time of day* that recurs: storing
/// 22:00 as an instant means it is wrong tomorrow. The offset travels with the
/// window so a push evaluated in a background isolate — which has no reason to
/// share the UI isolate's local timezone, and on iOS may not have the user's at
/// all — reaches the same verdict as the foreground path.
@immutable
class QuietHours {
  const QuietHours({
    required this.startMinute,
    required this.endMinute,
    this.offsetMinutes = 0,
    this.allowMentions = true,
    this.deliverSilently = false,
  });

  /// Start of the window, minutes since local midnight (22:00 → 1320).
  final int startMinute;

  /// End of the window, exclusive (07:00 → 420).
  final int endMinute;

  /// The user's UTC offset in minutes. Minutes, not hours, because +05:30 and
  /// +12:45 are real places.
  final int offsetMinutes;

  /// Whether an explicit mention still gets through. On by default: the point
  /// of quiet hours is to not be woken by chatter, not to miss being paged.
  final bool allowMentions;

  /// When true a suppressed-by-quiet-hours message is posted without sound
  /// instead of dropped, so it is waiting in the shade in the morning. This is
  /// the only rule in this package that produces [SilentDecision] — everything
  /// else either notifies or suppresses.
  final bool deliverSilently;

  Duration get offset => Duration(minutes: offsetMinutes);

  /// Whether [now] — in any timezone; it is normalised to UTC first — falls
  /// inside the window.
  ///
  /// A window that wraps past midnight (22:00 → 07:00) is the common case, so
  /// it is the one spelled out. A zero-length window (start == end) is treated
  /// as "no quiet hours" rather than "always", which is the safer reading of a
  /// half-finished settings screen.
  bool isActiveAt(DateTime now) {
    final start = startMinute % _minutesPerDay;
    final end = endMinute % _minutesPerDay;
    if (start == end) return false;
    final local = now.toUtc().add(offset);
    final minute = local.hour * 60 + local.minute;
    if (start < end) return minute >= start && minute < end;
    return minute >= start || minute < end;
  }

  QuietHours copyWith({
    int? startMinute,
    int? endMinute,
    int? offsetMinutes,
    bool? allowMentions,
    bool? deliverSilently,
  }) {
    return QuietHours(
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      offsetMinutes: offsetMinutes ?? this.offsetMinutes,
      allowMentions: allowMentions ?? this.allowMentions,
      deliverSilently: deliverSilently ?? this.deliverSilently,
    );
  }

  Map<String, Object?> toJson() => {
    'startMinute': startMinute,
    'endMinute': endMinute,
    'offsetMinutes': offsetMinutes,
    'allowMentions': allowMentions,
    'deliverSilently': deliverSilently,
  };

  /// Reads a window back, or null when the blob is not one.
  ///
  /// Lenient on purpose — see [NotificationPolicy.fromJson].
  static QuietHours? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = _asInt(json['startMinute']);
    final end = _asInt(json['endMinute']);
    if (start == null || end == null) return null;
    return QuietHours(
      startMinute: start,
      endMinute: end,
      offsetMinutes: _asInt(json['offsetMinutes']) ?? 0,
      allowMentions: _asBool(json['allowMentions']) ?? true,
      deliverSilently: _asBool(json['deliverSilently']) ?? false,
    );
  }

  static const int _minutesPerDay = 24 * 60;

  @override
  bool operator ==(Object other) =>
      other is QuietHours &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute &&
      other.offsetMinutes == offsetMinutes &&
      other.allowMentions == allowMentions &&
      other.deliverSilently == deliverSilently;

  @override
  int get hashCode => Object.hash(
    startMinute,
    endMinute,
    offsetMinutes,
    allowMentions,
    deliverSilently,
  );

  @override
  String toString() =>
      'QuietHours($startMinute→$endMinute, +${offsetMinutes}m)';
}

/// What the user changed about one specific chat.
///
/// Absent from [NotificationPolicy.chats] means "no opinion", which is not the
/// same as an override with everything at its default — the distinction matters
/// for the settings screen, which lists the chats that have an entry.
@immutable
class ChatNotificationOverride {
  const ChatNotificationOverride({
    this.muted = false,
    this.mutedUntil,
    this.mentionsOnly,
    this.bypassQuietHours = false,
  });

  /// Muted with no end date.
  final bool muted;

  /// Muted until this instant. Weft-only: Matrix push rules have no expiry, so
  /// `ChatRepository.setMuted` cannot express "for an hour" and the timer has
  /// to live on this side.
  final DateTime? mutedUntil;

  /// Overrides [NotificationPolicy.mentionsOnly] for this chat. Null defers to
  /// the global setting; false is a real "notify me for everything here" and is
  /// why this is nullable rather than a bool.
  final bool? mentionsOnly;

  /// This chat pages through quiet hours. The VIP escape hatch.
  final bool bypassQuietHours;

  /// Whether the chat is muted at [now].
  ///
  /// The boundary is exclusive: at exactly [mutedUntil] the mute has expired.
  /// A "mute for 1 hour" tapped at 09:00 notifies again for a message stamped
  /// 10:00:00.000, which is the reading a user checking their watch expects.
  bool isMutedAt(DateTime now) {
    if (muted) return true;
    final until = mutedUntil;
    return until != null && now.isBefore(until);
  }

  /// True when this override says nothing at all, so it can be dropped from
  /// the policy rather than persisted as noise.
  bool get isEmpty =>
      !muted && mutedUntil == null && mentionsOnly == null && !bypassQuietHours;

  ChatNotificationOverride copyWith({
    bool? muted,
    Object? mutedUntil = _sentinel,
    Object? mentionsOnly = _sentinel,
    bool? bypassQuietHours,
  }) {
    return ChatNotificationOverride(
      muted: muted ?? this.muted,
      mutedUntil: identical(mutedUntil, _sentinel)
          ? this.mutedUntil
          : mutedUntil as DateTime?,
      mentionsOnly: identical(mentionsOnly, _sentinel)
          ? this.mentionsOnly
          : mentionsOnly as bool?,
      bypassQuietHours: bypassQuietHours ?? this.bypassQuietHours,
    );
  }

  Map<String, Object?> toJson() => {
    if (muted) 'muted': true,
    if (mutedUntil != null)
      'mutedUntil': mutedUntil!.toUtc().millisecondsSinceEpoch,
    if (mentionsOnly != null) 'mentionsOnly': mentionsOnly,
    if (bypassQuietHours) 'bypassQuietHours': true,
  };

  static ChatNotificationOverride? fromJson(Object? json) {
    if (json is! Map) return null;
    final until = _asInt(json['mutedUntil']);
    return ChatNotificationOverride(
      muted: _asBool(json['muted']) ?? false,
      mutedUntil: until == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(until, isUtc: true),
      mentionsOnly: _asBool(json['mentionsOnly']),
      bypassQuietHours: _asBool(json['bypassQuietHours']) ?? false,
    );
  }

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) =>
      other is ChatNotificationOverride &&
      other.muted == muted &&
      other.mutedUntil == mutedUntil &&
      other.mentionsOnly == mentionsOnly &&
      other.bypassQuietHours == bypassQuietHours;

  @override
  int get hashCode =>
      Object.hash(muted, mutedUntil, mentionsOnly, bypassQuietHours);

  @override
  String toString() =>
      'ChatNotificationOverride(muted: $muted, until: $mutedUntil, '
      'mentionsOnly: $mentionsOnly, bypassQuietHours: $bypassQuietHours)';
}

/// Everything the user has said about when they want to be interrupted.
///
/// A value object with a JSON codec and no storage dependency: the app reads
/// and writes it through `weft_store`'s settings store under the `notify.`
/// keys, and a background isolate that has no Riverpod container can rebuild
/// the identical policy from the same blob.
///
/// It is deliberately a *second opinion* on mute rather than the only one. The
/// homeserver already knows about mutes — `ChatRepository.setMuted` writes
/// `setPushRuleState` on every source room — and that rule suppresses the
/// *push*. This policy suppresses the *display*. They should agree, and the
/// settings screen is responsible for keeping them agreeing; a timed mute is
/// necessarily Weft-only because Matrix push rules cannot express an expiry.
@immutable
class NotificationPolicy {
  NotificationPolicy({
    this.enabled = true,
    this.mentionsOnly = false,
    this.showPreviews = true,
    this.mentionsBypassMute = true,
    this.quietHours,
    Set<ChatNetwork> disabledNetworks = const {},
    Set<ChatNetwork> mutedNetworks = const {},
    Map<String, ChatNotificationOverride> chats = const {},
  }) : disabledNetworks = Set.unmodifiable(disabledNetworks),
       mutedNetworks = Set.unmodifiable(mutedNetworks),
       chats = Map.unmodifiable(chats);

  /// The master switch. Off means nothing is ever posted.
  final bool enabled;

  /// Only notify for messages that mention the user, everywhere. A per-chat
  /// [ChatNotificationOverride.mentionsOnly] overrides this in both directions.
  final bool mentionsOnly;

  /// Whether the message body may be rendered on the lock screen. Read by
  /// `content.dart`, not by evaluation: a preview-less notification is still a
  /// notification, and degrading the text is very different from staying quiet.
  final bool showPreviews;

  /// Whether an explicit mention breaks through a muted chat or network.
  ///
  /// True matches how people use group chats — mute the channel, still get
  /// paged. False matches Matrix's own semantics, where a room-level
  /// `dont_notify` beats everything. It is a setting because both readings have
  /// users, and because the alternative is arguing about it in a code review.
  final bool mentionsBypassMute;

  final QuietHours? quietHours;

  /// Networks switched off entirely. Not bypassable — off is off.
  final Set<ChatNetwork> disabledNetworks;

  /// Networks muted. Bypassable by a mention when [mentionsBypassMute].
  final Set<ChatNetwork> mutedNetworks;

  /// Per-chat overrides, keyed by [Chat.id] — which for a merged chat is
  /// `merged:<contactId>`, never a room id. Muting a merged contact is one
  /// entry, not one per leg.
  final Map<String, ChatNotificationOverride> chats;

  bool isNetworkEnabled(ChatNetwork network) =>
      !disabledNetworks.contains(network);

  bool isNetworkMuted(ChatNetwork network) => mutedNetworks.contains(network);

  /// The override for [chatId], or an empty one so callers never null-check.
  ChatNotificationOverride overrideFor(String chatId) =>
      chats[chatId] ?? const ChatNotificationOverride();

  /// A copy with one chat's override replaced. Passing null — or an override
  /// that [ChatNotificationOverride.isEmpty] — removes the entry, so unmuting
  /// does not leave a tombstone behind for the settings screen to list.
  NotificationPolicy withChatOverride(
    String chatId,
    ChatNotificationOverride? override,
  ) {
    final next = Map<String, ChatNotificationOverride>.from(chats);
    if (override == null || override.isEmpty) {
      next.remove(chatId);
    } else {
      next[chatId] = override;
    }
    return copyWith(chats: next);
  }

  /// A copy with [chatId] muted until [until], or indefinitely when it is null.
  NotificationPolicy muteChat(String chatId, {DateTime? until}) =>
      withChatOverride(
        chatId,
        overrideFor(
          chatId,
        ).copyWith(muted: until == null, mutedUntil: until?.toUtc()),
      );

  /// A copy with any mute on [chatId] lifted, timed or not.
  NotificationPolicy unmuteChat(String chatId) => withChatOverride(
    chatId,
    overrideFor(chatId).copyWith(muted: false, mutedUntil: null),
  );

  /// A copy with every *lapsed* timed mute cleared.
  ///
  /// A "mute for 1 hour" leaves an entry behind once its hour is up. It stops
  /// suppressing anything — [ChatNotificationOverride.isMutedAt] is false past
  /// the boundary — but it is still a key in a blob rewritten on every policy
  /// change, and still a row the settings screen has to filter out of a list
  /// whose whole promise is "chats that are muted *now*". Neither is a bug on
  /// its own; both compound, because nothing else ever removes them.
  ///
  /// Only the mute fields are cleared, so an override that also carries
  /// [ChatNotificationOverride.mentionsOnly] or `bypassQuietHours` keeps them
  /// and only an override left saying nothing at all is dropped — which is
  /// [withChatOverride]'s existing rule rather than a second one.
  ///
  /// Returns `this` when nothing has lapsed, so a caller can persist on a real
  /// change instead of rewriting the settings row every time a screen opens.
  NotificationPolicy pruneExpiredMutes(DateTime now) {
    final lapsed = [
      for (final entry in chats.entries)
        if (entry.value.mutedUntil != null && !entry.value.isMutedAt(now))
          entry.key,
    ];
    if (lapsed.isEmpty) return this;

    var next = this;
    for (final chatId in lapsed) {
      next = next.unmuteChat(chatId);
    }
    return next;
  }

  NotificationPolicy copyWith({
    bool? enabled,
    bool? mentionsOnly,
    bool? showPreviews,
    bool? mentionsBypassMute,
    Object? quietHours = _sentinel,
    Set<ChatNetwork>? disabledNetworks,
    Set<ChatNetwork>? mutedNetworks,
    Map<String, ChatNotificationOverride>? chats,
  }) {
    return NotificationPolicy(
      enabled: enabled ?? this.enabled,
      mentionsOnly: mentionsOnly ?? this.mentionsOnly,
      showPreviews: showPreviews ?? this.showPreviews,
      mentionsBypassMute: mentionsBypassMute ?? this.mentionsBypassMute,
      quietHours: identical(quietHours, _sentinel)
          ? this.quietHours
          : quietHours as QuietHours?,
      disabledNetworks: disabledNetworks ?? this.disabledNetworks,
      mutedNetworks: mutedNetworks ?? this.mutedNetworks,
      chats: chats ?? this.chats,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'mentionsOnly': mentionsOnly,
    'showPreviews': showPreviews,
    'mentionsBypassMute': mentionsBypassMute,
    'quietHours': quietHours?.toJson(),
    'disabledNetworks': _networkIds(disabledNetworks),
    'mutedNetworks': _networkIds(mutedNetworks),
    'chats': {
      for (final entry in chats.entries)
        if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
    },
  };

  /// Rebuilds a policy from [json], falling back to the default for anything
  /// missing or malformed.
  ///
  /// Nothing in here throws. `SettingsStore.getJson` already turns an
  /// unparseable blob into null, and this handles the other half — a blob that
  /// parses but was written by a different version. A policy that fails to load
  /// must degrade to "notify normally", because the failure mode of the
  /// alternative is a user who silently stops hearing from anyone.
  static NotificationPolicy fromJson(Object? json) {
    if (json is! Map) return NotificationPolicy();
    return NotificationPolicy(
      enabled: _asBool(json['enabled']) ?? true,
      mentionsOnly: _asBool(json['mentionsOnly']) ?? false,
      showPreviews: _asBool(json['showPreviews']) ?? true,
      mentionsBypassMute: _asBool(json['mentionsBypassMute']) ?? true,
      quietHours: QuietHours.fromJson(json['quietHours']),
      disabledNetworks: _networks(json['disabledNetworks']),
      mutedNetworks: _networks(json['mutedNetworks']),
      chats: _chats(json['chats']),
    );
  }

  static List<String> _networkIds(Set<ChatNetwork> networks) => [
    // Stable enum order, so two equal policies serialise byte-identically and
    // a settings write does not look like a change when it is not.
    for (final network in ChatNetwork.values)
      if (networks.contains(network)) network.id,
  ];

  static Set<ChatNetwork> _networks(Object? json) {
    if (json is! List) return const {};
    return {
      for (final raw in json)
        if (raw is String) ChatNetwork.fromId(raw),
    };
  }

  static Map<String, ChatNotificationOverride> _chats(Object? json) {
    if (json is! Map) return const {};
    final out = <String, ChatNotificationOverride>{};
    for (final entry in json.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final override = ChatNotificationOverride.fromJson(entry.value);
      if (override != null && !override.isEmpty) out[key] = override;
    }
    return out;
  }

  static const Object _sentinel = Object();
  static const SetEquality<ChatNetwork> _networkSetEquality = SetEquality();
  static const MapEquality<String, ChatNotificationOverride> _chatMapEquality =
      MapEquality();

  @override
  bool operator ==(Object other) =>
      other is NotificationPolicy &&
      other.enabled == enabled &&
      other.mentionsOnly == mentionsOnly &&
      other.showPreviews == showPreviews &&
      other.mentionsBypassMute == mentionsBypassMute &&
      other.quietHours == quietHours &&
      _networkSetEquality.equals(other.disabledNetworks, disabledNetworks) &&
      _networkSetEquality.equals(other.mutedNetworks, mutedNetworks) &&
      _chatMapEquality.equals(other.chats, chats);

  @override
  int get hashCode => Object.hash(
    enabled,
    mentionsOnly,
    showPreviews,
    mentionsBypassMute,
    quietHours,
    _networkSetEquality.hash(disabledNetworks),
    _networkSetEquality.hash(mutedNetworks),
    _chatMapEquality.hash(chats),
  );

  @override
  String toString() =>
      'NotificationPolicy(enabled: $enabled, mentionsOnly: $mentionsOnly, '
      'muted: ${mutedNetworks.length} networks, ${chats.length} chats)';
}

/// What should happen to one message.
///
/// Sealed so a platform layer that forgets the suppressed branch fails to
/// compile rather than posting everything.
@immutable
sealed class NotificationDecision {
  const NotificationDecision();

  const factory NotificationDecision.suppress(NotificationSuppression reason) =
      SuppressedDecision;

  const factory NotificationDecision.silent({bool mentioned}) = SilentDecision;

  const factory NotificationDecision.notify({bool mentioned}) = NotifyDecision;

  /// True when the platform layer should post something — with or without
  /// sound.
  bool get delivers => this is DeliveredDecision;

  /// Why nothing is posted, or null when this decision delivers.
  NotificationSuppression? get suppression => switch (this) {
    SuppressedDecision(:final reason) => reason,
    DeliveredDecision() => null,
  };

  /// Whether the message mentioned the user. False for a suppressed decision
  /// even when the body does mention them — a suppressed mention is still
  /// suppressed, and this flag exists to raise a delivered notification's
  /// priority.
  bool get mentioned => false;
}

/// Nothing is posted, for [reason].
@immutable
final class SuppressedDecision extends NotificationDecision {
  const SuppressedDecision(this.reason);

  final NotificationSuppression reason;

  @override
  bool operator ==(Object other) =>
      other is SuppressedDecision && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'SuppressedDecision(${reason.name})';
}

/// Something is posted. `content.dart` turns this plus the message and chat
/// into the `NotificationContent` the platform renders — rendering is not a
/// branch of this decision, because a silent notification shows exactly the
/// same text as a loud one.
@immutable
sealed class DeliveredDecision extends NotificationDecision {
  const DeliveredDecision({this.mentioned = false});

  @override
  final bool mentioned;
}

/// Posted, but without sound or vibration. Reached only through
/// [QuietHours.deliverSilently].
@immutable
final class SilentDecision extends DeliveredDecision {
  const SilentDecision({super.mentioned});

  @override
  bool operator ==(Object other) =>
      other is SilentDecision && other.mentioned == mentioned;

  @override
  int get hashCode => Object.hash(SilentDecision, mentioned);

  @override
  String toString() => 'SilentDecision(mentioned: $mentioned)';
}

/// Posted normally: sound, vibration, whatever the channel says.
@immutable
final class NotifyDecision extends DeliveredDecision {
  const NotifyDecision({super.mentioned});

  @override
  bool operator ==(Object other) =>
      other is NotifyDecision && other.mentioned == mentioned;

  @override
  int get hashCode => Object.hash(NotifyDecision, mentioned);

  @override
  String toString() => 'NotifyDecision(mentioned: $mentioned)';
}

/// Remembers which event ids have already been decided on.
///
/// A message reaching Weft twice is the normal case, not a bug: the push
/// arrives, and then the same event comes down `/sync` a second later — or the
/// other way round on a slow network. Both paths call
/// [evaluateNotification], and without this the user's phone buzzes twice for
/// one message.
///
/// Keyed on the Matrix event id alone, which is globally unique, so the same
/// event seen through two legs of a merged chat is still one decision. Eviction
/// is FIFO rather than LRU — re-seeing an id does not refresh it — because the
/// only thing that matters is covering the window between the two deliveries of
/// one message, and [capacity] is far larger than that window.
class NotificationDedupe {
  NotificationDedupe({this.capacity = 512}) : assert(capacity > 0, 'capacity');

  /// How many event ids to remember. Bounded because a background isolate
  /// running for days must not grow without limit.
  final int capacity;

  // A LinkedHashSet: iteration order is insertion order, which is what makes
  // `_seen.first` the oldest entry.
  final Set<String> _seen = <String>{};

  bool contains(String eventId) => _seen.contains(eventId);

  /// Records [eventId], returning false when it had already been recorded.
  bool remember(String eventId) {
    if (!_seen.add(eventId)) return false;
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  /// Drops [eventId], so the next delivery decides afresh. Used when a
  /// notification is dismissed and the event may legitimately re-notify.
  void forget(String eventId) => _seen.remove(eventId);

  void clear() => _seen.clear();

  int get length => _seen.length;
}

/// Decides what to do about [message] arriving in [chat].
///
/// Every input that could be looked up is passed in instead. [chat] carries the
/// merge resolution the app already performed — this package never re-derives a
/// conversation from a room id, because a second answer to that question drifts
/// from the first and splits a merged contact into two notification threads.
/// [now] is a parameter so quiet hours and mute expiry are testable at their
/// boundaries, and [lastReadAt] is a parameter because the read marker lives in
/// the Matrix room state, which a pure package cannot reach.
///
/// [ownUserIds] is a set rather than a string: the user is `@me:example.org` on
/// their homeserver *and* a bridge ghost id on every network they use, and a
/// mention of any of them is a mention. [ownDisplayNames] carries the textual
/// forms — their Matrix display name plus the name each bridge gives them,
/// since `mapEvent` drops `formatted_body` and `m.mentions` and leaves nothing
/// but plain text to match on.
///
/// Pass a [dedupe] to make repeat deliveries of one event id decide once. It is
/// optional so a caller with no long-lived state — a test, or a one-shot
/// re-evaluation — gets a pure function.
///
/// [isFirstFromSender] only matters for a pending request, where it is the
/// difference between one silent notification and none at all. It defaults to
/// true because for every other conversation it is unread, and a caller that
/// cannot cheaply answer it — a background push isolate with no timeline —
/// should not be forced to invent an answer that changes ordinary behaviour.
///
/// Order matters. Cheap and unarguable rules come first (own message, redacted,
/// already read), then the switches the user set, then the ones a mention can
/// break through. The first rule that fires wins and is reported as *the*
/// reason, so a muted chat during quiet hours reads as muted — the setting the
/// user would go and change.
NotificationDecision evaluateNotification({
  required WeftMessage message,
  required Chat chat,
  required NotificationPolicy policy,
  required DateTime now,
  required DateTime? lastReadAt,
  required Set<String> ownUserIds,
  Set<String> ownDisplayNames = const {},
  NotificationDedupe? dedupe,
  bool isFirstFromSender = true,
}) {
  // Before anything else, so that a second delivery of an event already
  // decided on is reported as a duplicate whatever the first verdict was.
  if (dedupe != null && !dedupe.remember(message.eventId)) {
    return const NotificationDecision.suppress(
      NotificationSuppression.duplicate,
    );
  }

  if (message.isOwn || ownUserIds.contains(message.senderId)) {
    return const NotificationDecision.suppress(
      NotificationSuppression.ownMessage,
    );
  }
  if (message.redacted) {
    return const NotificationDecision.suppress(
      NotificationSuppression.redacted,
    );
  }
  if (message.kind == MessageKind.event) {
    return const NotificationDecision.suppress(
      NotificationSuppression.nonMessageEvent,
    );
  }
  if (!policy.enabled) {
    return const NotificationDecision.suppress(
      NotificationSuppression.globallyDisabled,
    );
  }

  // Read elsewhere. `!isAfter` rather than `isBefore` so a message stamped
  // exactly at the read marker — the message that *was* read — does not
  // re-notify.
  if (lastReadAt != null && !message.timestamp.isAfter(lastReadAt)) {
    return const NotificationDecision.suppress(
      NotificationSuppression.alreadyRead,
    );
  }

  final mentioned = mentionsUser(
    message,
    ownUserIds: ownUserIds,
    ownDisplayNames: ownDisplayNames,
  );
  final bypassesMute = mentioned && policy.mentionsBypassMute;

  if (!policy.isNetworkEnabled(message.network)) {
    return const NotificationDecision.suppress(
      NotificationSuppression.networkDisabled,
    );
  }
  if (policy.isNetworkMuted(message.network) && !bypassesMute) {
    return const NotificationDecision.suppress(
      NotificationSuppression.networkMuted,
    );
  }

  final override = policy.overrideFor(chat.id);
  if ((override.isMutedAt(now) || chat.muted) && !bypassesMute) {
    return const NotificationDecision.suppress(
      NotificationSuppression.chatMuted,
    );
  }

  // Per-leg mute. `Chat.muted` is all-legs-muted for a merged chat, so a
  // contact muted on WhatsApp and live on Signal reads as unmuted above and
  // has to be caught here, against the source the message actually arrived on.
  if ((chat.sourceFor(message.network)?.muted ?? false) && !bypassesMute) {
    return const NotificationDecision.suppress(
      NotificationSuppression.sourceMuted,
    );
  }

  if ((override.mentionsOnly ?? policy.mentionsOnly) && !mentioned) {
    return const NotificationDecision.suppress(
      NotificationSuppression.mentionsOnly,
    );
  }

  final quiet = policy.quietHours;
  if (quiet != null &&
      quiet.isActiveAt(now) &&
      !override.bypassQuietHours &&
      !(mentioned && quiet.allowMentions)) {
    return quiet.deliverSilently
        ? NotificationDecision.silent(mentioned: mentioned)
        : const NotificationDecision.suppress(
            NotificationSuppression.quietHours,
          );
  }

  // Last, and after the mute rules rather than before them, so a request the
  // user has *also* muted reads as muted — the setting they would go and
  // change. A stranger gets one silent notification and nothing after it.
  //
  // Silent rather than suppressed for the first message, because a request the
  // user is never told about is a request they never answer: it sits in a
  // section they have no reason to open, and the message may be the one they
  // were waiting for. Silent rather than loud because a stranger must not be
  // able to make the phone ring — a handle that anyone can find is otherwise a
  // way to buzz a person at three in the morning.
  //
  // Deliberately ignores `mentioned`. A mention breaks through a mute because
  // the user chose to mute a conversation they are in; it must not break
  // through this, because writing the user's name is free and is exactly what
  // someone trying to get past the hold would do.
  if (chat.isPendingRequest) {
    return isFirstFromSender
        ? const NotificationDecision.silent()
        : const NotificationDecision.suppress(
            NotificationSuppression.pendingRequest,
          );
  }

  return NotificationDecision.notify(mentioned: mentioned);
}

/// Whether [message] mentions the user.
///
/// Textual, and necessarily so. Matrix's intentional mentions (`m.mentions`)
/// and the pill markup in `formatted_body` are both dropped at mapping time,
/// and a bridged message never had them: a WhatsApp mention arrives as the
/// literal characters of a name. So this matches user ids, display names, the
/// display name each bridge gives the user, and `@room`, over the plain body
/// and any transcript — a voice note that says your name is a mention too.
///
/// Matching is case-insensitive and bounded by non-word characters, so `Al`
/// does not fire on "Also". Names shorter than two characters are ignored
/// outright: a one-letter display name matches half the language, and the cost
/// of a false mention is a notification that broke through a mute.
///
/// Deliberately the *raw* [WeftMessage.searchableText] and not the projection
/// [renderNotificationBody] uses, even though the two now differ. The
/// projection strips a reply's `> <@alice:example.org>` fallback, and that
/// fallback is the only trace a reply to *you* leaves in a body Weft can read —
/// `m.mentions` is dropped at mapping time and a bridged reply never had it. A
/// notification should not repeat the message being answered, which is why the
/// body is projected; but someone replying to you is someone addressing you,
/// and losing that would silence replies inside a muted conversation.
bool mentionsUser(
  WeftMessage message, {
  required Set<String> ownUserIds,
  Set<String> ownDisplayNames = const {},
}) {
  final text = message.searchableText;
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  if (_containsToken(lower, '@room')) return true;
  for (final id in ownUserIds) {
    if (_containsToken(lower, id.toLowerCase())) return true;
  }
  for (final name in ownDisplayNames) {
    if (_containsToken(lower, name.trim().toLowerCase())) return true;
  }
  return false;
}

/// Whether [needle] — already lower-cased — appears in [haystack] as a whole
/// token rather than inside a longer word.
bool _containsToken(String haystack, String needle) {
  if (needle.length < 2) return false;
  var index = haystack.indexOf(needle);
  while (index >= 0) {
    final endIndex = index + needle.length;
    final before = index == 0 ? null : haystack.codeUnitAt(index - 1);
    final after = endIndex >= haystack.length
        ? null
        : haystack.codeUnitAt(endIndex);
    if (!_isWordChar(before) && !_isWordChar(after)) return true;
    index = haystack.indexOf(needle, index + 1);
  }
  return false;
}

/// Word characters for boundary purposes: ASCII letters, digits, underscore,
/// and everything non-ASCII — treating "é" as a letter costs nothing and stops
/// a name matching inside a word in every language that has accents.
bool _isWordChar(int? codeUnit) {
  if (codeUnit == null) return false;
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return true; // 0-9
  if (codeUnit >= 0x41 && codeUnit <= 0x5A) return true; // A-Z
  if (codeUnit >= 0x61 && codeUnit <= 0x7A) return true; // a-z
  if (codeUnit == 0x5F) return true; // _
  return codeUnit > 0x7F;
}

bool? _asBool(Object? value) => value is bool ? value : null;

int? _asInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.round(),
  _ => null,
};
