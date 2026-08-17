import 'dart:async';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

import '../../app/intents.dart';
import '../notifications/notification_service.dart'
    show NotificationAvatarLoader;

/// Keeps the platform's share targets in step with the inbox.
///
/// The Dart half of Direct Share. `ShareTargetRanker` decides *which*
/// conversations and in what order, `ShareShortcuts.kt` does the publishing, and
/// this sits between them: it watches the chat list, ranks it, resolves each
/// slot's avatar to a file the platform can decode, and calls the channel — or,
/// far more often, decides not to.
///
/// **The diff is the whole point.** `watchChats` emits on everything: a read
/// receipt, a typing indicator, an unread count, a presence change, a message in
/// a conversation nowhere near the top eight. The published set changes on a
/// small fraction of those, and republishing on the rest costs a launcher
/// re-layout each time — visible as a share sheet that stutters while it is
/// open. [ShareTargetSlot] equality covers every field including `rank`, which
/// is what makes "nothing changed" a question this class can answer cheaply.
///
/// The diff is at the *call*, not inside it. `ShareShortcuts.publish` takes the
/// complete set because it also removes whatever fell off it — a share sheet
/// still offering a conversation archived last week is the failure it exists to
/// prevent — so there is no shape of "push slot 3 only" for it to be handed.
/// Suppressing the call entirely is the delta that matters: the set is stable
/// for minutes at a time and the stream is not.
class ShareShortcutService {
  ShareShortcutService({
    required ShareTargetPublisher publisher,
    NotificationAvatarLoader? avatarLoader,
    ShareTargetRanker ranker = const ShareTargetRanker(),
    int maxSlots = kMaxShareTargetSlots,
  }) : _publisher = publisher,
       _avatarLoader = avatarLoader,
       _ranker = ranker,
       _maxSlots = maxSlots;

  final ShareTargetPublisher _publisher;
  final NotificationAvatarLoader? _avatarLoader;
  final ShareTargetRanker _ranker;
  final int _maxSlots;

  /// What the platform was last asked to publish.
  ///
  /// "Asked", not "has": a device whose per-activity cap is below [_maxSlots]
  /// publishes a prefix of this and says so, and storing the prefix instead
  /// would make the next identical rank look like a change — which is exactly
  /// the thrash the diff exists to stop. A publish that reached *nothing*
  /// resets this to empty, because that is a refusal to retry rather than a cap
  /// to respect.
  List<ShareTargetSlot> _published = const [];

  /// The most recent chat list, held so a resume or a send can republish
  /// without the caller having to carry one.
  ///
  /// Null before the first [refresh] and again after [clear], and both mean the
  /// same thing: there is nothing this service is entitled to publish. A
  /// [noteSend] arriving in that state records the send and stops there, rather
  /// than publishing an empty set — which the platform would read as "remove
  /// everything".
  List<Chat>? _chats;

  DateTime? _now;

  /// Sends per conversation, this run.
  ///
  /// Feeds [ShareTargetRanker]'s frequency term, which is the difference
  /// between "the last five conversations that made a noise" and "the five
  /// people you actually talk to". Deliberately *not* persisted: a durable
  /// count needs a settings key, a bound and a story for what happens when a
  /// merged chat's id changes, and recency already carries the ranking on its
  /// own from the first launch — see [ChatShareActivity]. Bounded in practice
  /// by the number of conversations messaged in one run of the app.
  final Map<String, ChatShareActivity> _activity = {};

  /// A publish is in flight.
  bool _busy = false;

  /// A [refresh] arrived while one was. Its list is already in [_chats]; this
  /// only records that the pass in flight is looking at a stale one.
  bool _restale = false;

  /// The slots the platform was last asked for, in order.
  @visibleForTesting
  List<ShareTargetSlot> get published => List.unmodifiable(_published);

  /// Ranks [chats] and publishes them, unless the result is what is already up.
  ///
  /// Safe to call on every inbox tick — that is what it is for. Overlapping
  /// calls coalesce rather than queue: publishing awaits an avatar per slot, and
  /// a stream that ticks during that wait wants the *newest* list published
  /// once, not every intermediate list published in turn.
  Future<void> refresh(List<Chat> chats, {DateTime? now}) async {
    _chats = List.of(chats);
    _now = now;

    if (_busy) {
      _restale = true;
      return;
    }

    _busy = true;
    try {
      do {
        _restale = false;
        await _publishOnce();
      } while (_restale);
    } finally {
      _busy = false;
    }
  }

  /// Records a send to [chatId] and republishes.
  ///
  /// Both halves matter. The send itself moves the conversation up the ranking
  /// through the echo the repository emits — which would republish on its own —
  /// but the *count* is only knowable here, and a caller that sends without
  /// telling this service leaves the frequency term permanently zero.
  Future<void> noteSend(String chatId, {DateTime? at}) async {
    final previous = _activity[chatId] ?? ChatShareActivity.none;
    _activity[chatId] = ChatShareActivity(
      sendCount: previous.sendCount + 1,
      lastSentAt: at ?? clock.now(),
    );

    final chats = _chats;
    if (chats == null) return;
    await refresh(chats, now: _now);
  }

  /// Removes every published share target and forgets this run's activity.
  ///
  /// Called on logout. A signed-out phone that still offers "Alexandra" in
  /// every app's share sheet has handed a contact name to whoever picks it up,
  /// and a long-lived shortcut is long-lived precisely because nothing else
  /// will collect it.
  ///
  /// [_chats] is dropped first so a publish already in flight finds nothing to
  /// publish on its next pass and stops, rather than racing the removal with a
  /// set of targets it computed before the user signed out.
  Future<void> clear() async {
    _chats = null;
    _activity.clear();
    _published = const [];
    await _publisher.clearShareTargets();
  }

  Future<void> _publishOnce() async {
    final chats = _chats;
    if (chats == null) return;

    final slots = _ranker.rank(
      chats,
      now: _now ?? clock.now(),
      activity: _activity,
      maxSlots: _maxSlots,
      // No `content`: the shortcut publisher runs with no share in flight, so
      // there is nothing to capability-filter against. The filter applies in
      // the sheet, where the files are known.
    );

    if (const ListEquality<ShareTargetSlot>().equals(slots, _published)) return;

    final payload = <Map<String, Object?>>[
      for (final slot in slots)
        {
          ...slot.toJson(),
          // The one key the slot itself cannot carry: it holds an avatar *URL*,
          // and `weft_share` has no way to fetch one. Android decodes a file
          // path; resolving the URL to that file is this side's job, and iOS
          // resolves the same URL to something else entirely.
          'iconPath': await _iconFor(slot),
        },
    ];

    final count = await _publisher.publishShareTargets(payload);
    // Zero against a non-empty request is a refusal — a launcher that will not
    // take shortcuts, or a platform with no channel at all. Forgetting what was
    // asked for makes the next tick try again; remembering it would mean never
    // trying again for as long as the app runs.
    _published = count == 0 && slots.isNotEmpty ? const [] : slots;
  }

  Future<String?> _iconFor(ShareTargetSlot slot) async {
    final loader = _avatarLoader;
    final url = slot.avatarUrl;
    if (loader == null || url == null || url.isEmpty) return null;
    try {
      return await loader(url);
    } on Object catch (error) {
      // A face is not worth a share target. `ShareShortcuts` draws initials for
      // a null path, which is the same thing the inbox draws.
      debugPrint('weft: share target avatar $url could not be loaded: $error');
      return null;
    }
  }
}
