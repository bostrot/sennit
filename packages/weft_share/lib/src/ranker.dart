import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'capability.dart';
import 'content.dart';
import 'slot.dart';

/// How many targets the ranker publishes unless told otherwise.
///
/// Android guarantees at least five dynamic shortcuts per activity and many
/// devices allow fifteen; the share sheet's own row shows about four. iOS has
/// no such limit — the extension's picker is a scrollable list — so the cap is
/// a per-surface argument to [ShareTargetRanker.rank] rather than a property of
/// the ranker, and eight is the number that fills an iOS list without the
/// Android publisher having to think. That publisher still clamps to
/// `ShortcutManagerCompat.getMaxShortcutCountPerActivity()`: publishing past
/// the device's real limit throws, and the device is the only thing that knows
/// what the limit is.
const int kMaxShareTargetSlots = 8;

/// How often a chat has been sent to, as far as ranking cares.
///
/// A raw count is the wrong input on its own: a work group that was the whole
/// of March and nothing since outranks the person messaged twice yesterday
/// forever. [lastSentAt] is what lets the count rot — see
/// [ShareTargetRanker.halfLife].
@immutable
class ChatShareActivity {
  const ChatShareActivity({this.sendCount = 0, this.lastSentAt});

  /// Messages the user has sent to this chat, over whatever window the caller
  /// keeps. Not read at all when [lastSentAt] is null.
  final int sendCount;

  /// When the most recent of those was sent.
  final DateTime? lastSentAt;

  /// No history. The state every chat starts in, and the one a fresh install is
  /// entirely made of — which is why recency has to be able to rank on its own.
  static const ChatShareActivity none = ChatShareActivity();

  @override
  String toString() => 'ChatShareActivity($sendCount sends, last $lastSentAt)';
}

/// Orders conversations as share targets.
///
/// Four inputs, in the order they matter:
///
/// 1. **Pinned** chats come first, as a tier rather than a bonus. A user who
///    pinned a chat has already answered the question this class is asking, and
///    no amount of accumulated recency elsewhere should overrule them.
/// 2. **Recency** — how long ago the last message landed, decayed by
///    [halfLife]. This is the signal that works on day one.
/// 3. **Frequency** — a [ChatShareActivity.sendCount] decayed by the age of the
///    last send, then saturated so a chat with five hundred sends does not
///    outrank everything for a month after it goes quiet.
/// 4. **Capability** — whether any leg of the chat can actually carry what is
///    being shared. A Signal-only chat is not a target for a 100 MB video if
///    Signal will refuse it, and offering it produces a failure the user cannot
///    act on. This is a *filter*, not a score: it removes targets, it never
///    reorders them.
///
/// Capability filtering does not replace [kMaxSharedFileBytes]. That cap is
/// about what Weft is willing to copy into its own cache and applies to every
/// share on every network; this one is about what one network will take. A file
/// has to clear both, plus the homeserver's own limit, and each of the three is
/// checked by the layer that knows the number.
@immutable
class ShareTargetRanker {
  const ShareTargetRanker({
    this.capabilities = const NetworkShareCapabilities(),
    this.halfLife = const Duration(days: 7),
    this.recencyWeight = 0.6,
    this.frequencyWeight = 0.4,
    this.frequencySaturation = 5,
  });

  /// The table the capability filter consults.
  final NetworkShareCapabilities capabilities;

  /// Age at which a signal is worth half what it was.
  ///
  /// A week: long enough that a chat quiet over a weekend does not fall off the
  /// list, short enough that a conversation finished a month ago stops
  /// occupying a slot someone is looking past.
  final Duration halfLife;

  /// Weight on the decayed recency term, in 0..1.
  final double recencyWeight;

  /// Weight on the saturated frequency term, in 0..1.
  ///
  /// Below [recencyWeight] on purpose. Frequency describes a habit and recency
  /// describes an intention, and someone reaching for a share sheet is far more
  /// often continuing the conversation they were just in.
  final double frequencyWeight;

  /// Sends at which the frequency term reaches half its maximum.
  ///
  /// The term is `n / (n + k)`, which rises fast over the first few sends and
  /// then flattens — the difference between never and five times is worth
  /// ranking on, the difference between two hundred and four hundred is not.
  final int frequencySaturation;

  /// [chats], ranked and cut to [maxSlots].
  ///
  /// [now] is required rather than defaulted to `DateTime.now()` because every
  /// term here is an age, and a ranker that reads the clock itself cannot be
  /// tested against one.
  ///
  /// [activity] is keyed by [Chat.id]. A chat missing from it is ranked on
  /// recency alone, which is correct for a chat the user has only ever read.
  ///
  /// [content] defaults to empty, which disables capability filtering: the
  /// Android shortcut publisher ranks with no share in flight and must offer
  /// every conversation, because the file it will eventually be handed is not
  /// knowable when the shortcut is published.
  List<ShareTargetSlot> rank(
    Iterable<Chat> chats, {
    required DateTime now,
    ShareContent content = const ShareContent(),
    Map<String, ChatShareActivity> activity = const {},
    int maxSlots = kMaxShareTargetSlots,
  }) {
    if (maxSlots <= 0) return const [];

    final eligible = [
      for (final chat in chats)
        if (_isEligible(chat, content)) chat,
    ];

    final scores = {
      for (final chat in eligible)
        chat.id: scoreFor(
          chat,
          now: now,
          activity: activity[chat.id] ?? ChatShareActivity.none,
        ),
    };

    eligible.sort((a, b) => _compare(a, b, scores));

    final capped = eligible.take(maxSlots).toList(growable: false);
    return [
      for (var i = 0; i < capped.length; i++)
        ShareTargetSlot.forChat(capped[i], rank: i),
    ];
  }

  /// The 0..1 score [chat] ranks on, ignoring the pinned tier.
  ///
  /// Public so a surface can explain an order, and so the weights can be tuned
  /// against real inboxes without reaching through [rank].
  double scoreFor(
    Chat chat, {
    required DateTime now,
    ChatShareActivity activity = ChatShareActivity.none,
  }) {
    final recency = _decay(chat.lastMessage?.timestamp, now);

    final sends = activity.sendCount <= 0
        ? 0.0
        : activity.sendCount * _decay(activity.lastSentAt, now);
    final frequency = sends <= 0 ? 0.0 : sends / (sends + frequencySaturation);

    return recencyWeight * recency + frequencyWeight * frequency;
  }

  bool _isEligible(Chat chat, ShareContent content) {
    if (chat.archived) return false;
    // A chat with no source has nowhere to send to. It exists transiently while
    // a merge is being rebuilt, and publishing it produces a shortcut whose tap
    // opens a conversation that cannot be written to.
    if (chat.sources.isEmpty) return false;
    return capabilities.canReach(chat, content);
  }

  /// Pinned first, then score, then a stable tie-break.
  ///
  /// The tie-break is not decoration. A fresh account has no last message and
  /// no send history, so *every* chat scores exactly zero — and an unstable
  /// sort there means the published shortcut set changes on every inbox tick
  /// for no reason the user can see, which is precisely the launcher thrash the
  /// publish diff exists to avoid. Title before id so the fallback order is one
  /// a person could have predicted.
  int _compare(Chat a, Chat b, Map<String, double> scores) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;

    final byScore = scores[b.id]!.compareTo(scores[a.id]!);
    if (byScore != 0) return byScore;

    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (byTitle != 0) return byTitle;

    return a.id.compareTo(b.id);
  }

  /// `0.5 ^ (age / halfLife)`, clamped to 1 for anything not in the past.
  ///
  /// A future timestamp is not an error to reject: a bridged message carries the
  /// remote network's own send time, and a phone whose clock is a minute behind
  /// the homeserver's produces one routinely.
  double _decay(DateTime? at, DateTime now) {
    if (at == null) return 0;
    final ageMs = now.difference(at).inMilliseconds;
    if (ageMs <= 0) return 1;
    final halfLifeMs = halfLife.inMilliseconds;
    if (halfLifeMs <= 0) return 0;
    return math.pow(0.5, ageMs / halfLifeMs).toDouble();
  }
}
