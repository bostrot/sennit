import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// How many auto-replies one conversation may receive within
/// [kAutoReplyCapWindow], whatever the rules say.
///
/// The hard stop, and deliberately not a setting. Every other limit here is the
/// user tuning a feature; this one is the feature refusing to be turned into a
/// machine that talks to another machine for ever. A cooldown a user could set
/// to zero would be a loop with a slow clock, so the cap sits underneath every
/// rule and cannot be raised from the UI.
///
/// Three rather than one because a real exchange has turns in it: someone
/// writes, the model answers, they answer back. One would make the feature
/// stop after the first sentence of every conversation it was ever used in.
const int kAutoReplyMaxPerConversation = 3;

/// The window [kAutoReplyMaxPerConversation] is counted over.
const Duration kAutoReplyCapWindow = Duration(hours: 1);

/// The cooldown a freshly-made rule starts with.
///
/// Long on purpose. The failure mode of a short cooldown is a conversation
/// where every message the user has not read yet gets its own machine answer,
/// which reads to the other person as being talked at by a wall.
const Duration kAutoReplyDefaultCooldown = Duration(minutes: 30);

/// How much of the conversation is sent to the model with the prompt.
///
/// Bounded here rather than at the call site because it is a privacy quantity,
/// not a tuning one: it is the number of messages that leave the device on
/// every auto-reply. See `docs/architecture/auto-reply.md`.
const int kAutoReplyContextMessages = 8;

/// Which conversations a rule applies to.
///
/// A sealed hierarchy rather than a bag of nullable fields because the four
/// cases are genuinely different questions — "is this person X", "did the user
/// file this chat under Y", "did this arrive on Z", "always" — and because
/// [autoReplyAudiencePrecedence] has to be able to rank them. A record with
/// four optional filters would make "a rule with everything null" a legal value
/// meaning either everyone or nobody, depending on who read it.
@immutable
sealed class AutoReplyAudience {
  const AutoReplyAudience();

  /// Whether this audience covers a message arriving in [chat] on [network].
  ///
  /// [labels] is what the app has filed the conversation under; the model
  /// cannot look it up, because labels live in app settings rather than in any
  /// Matrix state. [network] is the *message's*, not the chat's: a merged
  /// contact reaches the user on three networks and a rule scoped to SMS must
  /// fire on the SMS leg and nowhere else.
  bool matches({
    required Chat chat,
    required Set<String> labels,
    required ChatNetwork network,
  });

  Map<String, Object?> toJson();

  /// Reads an audience back, or null when the blob is not one.
  ///
  /// Lenient in the same way `NotificationPolicy.fromJson` is: an unknown kind
  /// from a newer build reads as null, and the rule carrying it is dropped
  /// rather than the whole list failing to load.
  static AutoReplyAudience? fromJson(Object? json) {
    if (json is! Map) return null;
    return switch (json['kind']) {
      'everyone' => const EveryoneAudience(),
      'network' => NetworkAudience(_networksFrom(json['networks'])),
      'label' => switch (json['label']) {
        final String label when label.trim().isNotEmpty => LabelAudience(
          label.trim(),
        ),
        _ => null,
      },
      'contacts' => switch (_stringsFrom(json['ids'])) {
        final ids when ids.isNotEmpty => ContactAudience(ids),
        _ => null,
      },
      _ => null,
    };
  }
}

/// Every conversation that is not refused outright by a guard.
@immutable
final class EveryoneAudience extends AutoReplyAudience {
  const EveryoneAudience();

  @override
  bool matches({
    required Chat chat,
    required Set<String> labels,
    required ChatNetwork network,
  }) => true;

  @override
  Map<String, Object?> toJson() => const {'kind': 'everyone'};

  @override
  bool operator ==(Object other) => other is EveryoneAudience;

  @override
  int get hashCode => (EveryoneAudience).hashCode;

  @override
  String toString() => 'EveryoneAudience()';
}

/// Messages that arrived on one of [networks].
@immutable
final class NetworkAudience extends AutoReplyAudience {
  const NetworkAudience(this.networks);

  final Set<ChatNetwork> networks;

  @override
  bool matches({
    required Chat chat,
    required Set<String> labels,
    required ChatNetwork network,
  }) => networks.contains(network);

  @override
  Map<String, Object?> toJson() => {
    'kind': 'network',
    'networks': networks.map((n) => n.name).toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is NetworkAudience &&
      const SetEquality<ChatNetwork>().equals(other.networks, networks);

  @override
  int get hashCode => const SetEquality<ChatNetwork>().hash(networks);

  @override
  String toString() =>
      'NetworkAudience(${networks.map((n) => n.name).join(', ')})';
}

/// Conversations the user has filed under [label].
@immutable
final class LabelAudience extends AutoReplyAudience {
  const LabelAudience(this.label);

  final String label;

  @override
  bool matches({
    required Chat chat,
    required Set<String> labels,
    required ChatNetwork network,
  }) => labels.contains(label);

  @override
  Map<String, Object?> toJson() => {'kind': 'label', 'label': label};

  @override
  bool operator ==(Object other) =>
      other is LabelAudience && other.label == label;

  @override
  int get hashCode => Object.hash(LabelAudience, label);

  @override
  String toString() => 'LabelAudience("$label")';
}

/// Named conversations.
///
/// [ids] holds unified contact ids for a DM — the merge fold's answer, so a
/// person reachable on WhatsApp and Signal is one entry rather than two — and
/// falls back to chat ids for everything the graph has no contact for, which is
/// every group. Both are matched, because a picker offering "this conversation"
/// and "this person" as two different things would be a distinction the user
/// did not ask for.
@immutable
final class ContactAudience extends AutoReplyAudience {
  const ContactAudience(this.ids);

  final Set<String> ids;

  @override
  bool matches({
    required Chat chat,
    required Set<String> labels,
    required ChatNetwork network,
  }) {
    final contactId = chat.contactId;
    return ids.contains(chat.id) ||
        (contactId != null && ids.contains(contactId));
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'contacts',
    'ids': ids.toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is ContactAudience &&
      const SetEquality<String>().equals(other.ids, ids);

  @override
  int get hashCode => const SetEquality<String>().hash(ids);

  @override
  String toString() => 'ContactAudience(${ids.length} ids)';
}

/// How specific an audience is, for ranking two rules that both match.
///
/// Higher wins. The order is "how deliberately did the user aim this": naming a
/// person is the most deliberate thing they can do, a label is a group they
/// curated, a network is a wide sweep, and everyone is the catch-all. A rule
/// written for one person must beat the blanket holiday responder, or the
/// blanket rule makes every other rule unreachable the moment it is switched
/// on.
int autoReplyAudiencePrecedence(AutoReplyAudience audience) =>
    switch (audience) {
      ContactAudience() => 3,
      LabelAudience() => 2,
      NetworkAudience() => 1,
      EveryoneAudience() => 0,
    };

/// A recurring stretch of the week in which a rule may fire.
///
/// The same shape as `QuietHours` in `weft_notify`, and for the same reason:
/// the window is a *time of day* that recurs, so storing 09:00 as an instant
/// makes it wrong tomorrow. The UTC offset travels with the window so a reply
/// decided in a background isolate — which has no reason to share the UI
/// isolate's timezone — reaches the same verdict as the foreground path.
///
/// [weekdays] uses `DateTime.monday`…`DateTime.sunday`. Empty means every day,
/// which is what a window with no day chosen should obviously do.
@immutable
class ReplyWindow {
  const ReplyWindow({
    required this.startMinute,
    required this.endMinute,
    this.offsetMinutes = 0,
    this.weekdays = const {},
  });

  /// Start of the window, minutes since local midnight (09:00 → 540).
  final int startMinute;

  /// End of the window, exclusive (17:00 → 1020).
  final int endMinute;

  /// The user's UTC offset in minutes. Minutes, not hours, because +05:30 and
  /// +12:45 are real places.
  final int offsetMinutes;

  /// Days the window opens on, or empty for every day.
  final Set<int> weekdays;

  Duration get offset => Duration(minutes: offsetMinutes);

  /// Whether the window covers no time at all.
  ///
  /// A zero-length window reads as "always", the opposite of the same case in
  /// `QuietHours` — and the difference is not an inconsistency. There, a
  /// half-finished settings screen must not start suppressing notifications;
  /// here, it must not start *withholding* a reply the user asked for. Both
  /// readings fail towards the behaviour the user would have had with no
  /// window at all.
  bool get isAlways =>
      startMinute % _minutesPerDay == endMinute % _minutesPerDay;

  /// Whether [now] — in any timezone; it is normalised to UTC first — falls
  /// inside the window.
  ///
  /// A window that wraps past midnight (22:00 → 07:00) is spelled out because
  /// it is common and because [weekdays] means something subtle for it: the day
  /// checked is the day the window **opened**, not the day the message arrived.
  /// A Friday-evening window running to 07:00 is still the Friday window at two
  /// in the morning, which is what anyone setting it would expect and what
  /// checking Saturday instead would get wrong every week.
  bool isActiveAt(DateTime now) {
    if (isAlways) return _allowsWeekday(_localOf(now).weekday);

    final start = startMinute % _minutesPerDay;
    final end = endMinute % _minutesPerDay;
    final local = _localOf(now);
    final minute = local.hour * 60 + local.minute;

    if (start < end) {
      if (minute < start || minute >= end) return false;
      return _allowsWeekday(local.weekday);
    }

    // Wrapping. The evening half belongs to today, the morning half to
    // yesterday — which is the day the window opened.
    if (minute >= start) return _allowsWeekday(local.weekday);
    if (minute < end) {
      return _allowsWeekday(local.subtract(const Duration(days: 1)).weekday);
    }
    return false;
  }

  /// [now] moved into the window's own timezone, as a UTC-tagged instant whose
  /// wall-clock fields read as local ones. Never handed out — only its `hour`,
  /// `minute` and `weekday` are used.
  DateTime _localOf(DateTime now) => now.toUtc().add(offset);

  bool _allowsWeekday(int weekday) =>
      weekdays.isEmpty || weekdays.contains(weekday);

  ReplyWindow copyWith({
    int? startMinute,
    int? endMinute,
    int? offsetMinutes,
    Set<int>? weekdays,
  }) {
    return ReplyWindow(
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      offsetMinutes: offsetMinutes ?? this.offsetMinutes,
      weekdays: weekdays ?? this.weekdays,
    );
  }

  Map<String, Object?> toJson() => {
    'startMinute': startMinute,
    'endMinute': endMinute,
    'offsetMinutes': offsetMinutes,
    'weekdays': weekdays.toList()..sort(),
  };

  static ReplyWindow? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = _asInt(json['startMinute']);
    final end = _asInt(json['endMinute']);
    if (start == null || end == null) return null;
    return ReplyWindow(
      startMinute: start,
      endMinute: end,
      offsetMinutes: _asInt(json['offsetMinutes']) ?? 0,
      weekdays: {
        for (final day
            in json['weekdays'] is List ? json['weekdays'] as List : const [])
          ?switch (_asInt(day)) {
            final int d when d >= DateTime.monday && d <= DateTime.sunday => d,
            _ => null,
          },
      },
    );
  }

  static const int _minutesPerDay = 24 * 60;

  @override
  bool operator ==(Object other) =>
      other is ReplyWindow &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute &&
      other.offsetMinutes == offsetMinutes &&
      const SetEquality<int>().equals(other.weekdays, weekdays);

  @override
  int get hashCode => Object.hash(
    startMinute,
    endMinute,
    offsetMinutes,
    const SetEquality<int>().hash(weekdays),
  );

  @override
  String toString() =>
      'ReplyWindow($startMinute→$endMinute, +${offsetMinutes}m, '
      'days: ${weekdays.isEmpty ? 'all' : (weekdays.toList()..sort()).join(',')})';
}

/// One user-authored auto-reply rule.
@immutable
class AutoReplyRule {
  const AutoReplyRule({
    required this.id,
    required this.name,
    required this.prompt,
    this.audience = const EveryoneAudience(),
    this.enabled = false,
    this.window,
    this.cooldown = kAutoReplyDefaultCooldown,
  });

  /// Stable across edits, so the reply ledger keeps its history when a user
  /// rewrites a prompt. A rule the editor recreated under a new id would come
  /// off cooldown instantly, which is precisely the moment someone is
  /// experimenting and least wants a surprise message sent.
  final String id;

  /// What the user calls it, for the list. May be empty — the screen falls back
  /// to describing the audience — because forcing a name on someone who wants
  /// one holiday responder is a field they will fill with "asdf".
  final String name;

  /// The user's own instruction to their model. The whole feature, really;
  /// everything else here decides when it is allowed to run.
  final String prompt;

  final AutoReplyAudience audience;

  /// **False unless explicitly set.** A rule that started replying to people
  /// the moment it was saved would be a message sent by a half-finished form.
  final bool enabled;

  /// When the rule may fire, or null for any time.
  final ReplyWindow? window;

  /// How long after an auto-reply in a conversation before another may be sent
  /// there. Counted against *any* auto-reply in that conversation, not just
  /// this rule's — two rules taking turns would otherwise halve the interval
  /// the user asked for.
  final Duration cooldown;

  /// Whether this rule could ever produce a message.
  ///
  /// A disabled rule and a rule with a blank prompt are the same thing from the
  /// engine's point of view: there is nothing to send. Keeping them together
  /// means a half-written rule left enabled does not silently shadow a working
  /// one of lower precedence.
  bool get isUsable => enabled && prompt.trim().isNotEmpty;

  AutoReplyRule copyWith({
    String? name,
    String? prompt,
    AutoReplyAudience? audience,
    bool? enabled,
    Object? window = _sentinel,
    Duration? cooldown,
  }) {
    return AutoReplyRule(
      id: id,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      audience: audience ?? this.audience,
      enabled: enabled ?? this.enabled,
      // A sentinel, because clearing the window is a thing the editor does and
      // `??` would make "any time" unreachable once a window had been set.
      window: identical(window, _sentinel)
          ? this.window
          : window as ReplyWindow?,
      cooldown: cooldown ?? this.cooldown,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'audience': audience.toJson(),
    'enabled': enabled,
    if (window != null) 'window': window!.toJson(),
    'cooldownMinutes': cooldown.inMinutes,
  };

  /// Reads a rule back, or null when the blob is not one.
  ///
  /// Degrades field by field rather than refusing: a rule written by a newer
  /// build loses what this one does not understand and keeps the rest. The two
  /// exceptions are an id and an audience it cannot read at all — a rule with
  /// no id has no ledger and a rule with no audience has no meaning, and both
  /// would be worse kept than dropped.
  static AutoReplyRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final audience = AutoReplyAudience.fromJson(json['audience']);
    if (audience == null) return null;

    return AutoReplyRule(
      id: id,
      name: json['name'] is String ? json['name'] as String : '',
      prompt: json['prompt'] is String ? json['prompt'] as String : '',
      audience: audience,
      enabled: json['enabled'] is bool && json['enabled'] as bool,
      window: ReplyWindow.fromJson(json['window']),
      cooldown: switch (_asInt(json['cooldownMinutes'])) {
        final int minutes when minutes >= 0 => Duration(minutes: minutes),
        _ => kAutoReplyDefaultCooldown,
      },
    );
  }

  /// The whole list, as it is stored: one JSON blob, like `notify.policy`.
  static List<AutoReplyRule> listFromJson(Object? json) {
    final rules = json is Map ? json['rules'] : null;
    if (rules is! List) return const [];
    return [for (final rule in rules) ?AutoReplyRule.fromJson(rule)];
  }

  static Map<String, Object?> listToJson(List<AutoReplyRule> rules) => {
    'rules': [for (final rule in rules) rule.toJson()],
  };

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) =>
      other is AutoReplyRule &&
      other.id == id &&
      other.name == name &&
      other.prompt == prompt &&
      other.audience == audience &&
      other.enabled == enabled &&
      other.window == window &&
      other.cooldown == cooldown;

  @override
  int get hashCode =>
      Object.hash(id, name, prompt, audience, enabled, window, cooldown);

  @override
  String toString() =>
      'AutoReplyRule($id, "$name", $audience, enabled: $enabled)';
}

Set<ChatNetwork> _networksFrom(Object? value) {
  if (value is! List) return const {};
  return {
    for (final entry in value)
      ?ChatNetwork.values.firstWhereOrNull((n) => n.name == entry),
  };
}

Set<String> _stringsFrom(Object? value) {
  if (value is! List) return const {};
  return {
    for (final entry in value)
      if (entry is String && entry.trim().isNotEmpty) entry.trim(),
  };
}

int? _asInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.round(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};
