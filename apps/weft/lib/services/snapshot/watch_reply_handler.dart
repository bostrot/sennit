import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_domain/weft_domain.dart';

/// One reply, as it left a wrist.
///
/// Three fields and no more, deliberately. A watch has no session, no room list
/// and no way to know which network a conversation rides — it has a
/// [SnapshotRow] it was handed hours ago and a sentence the user dictated. Every
/// other decision (which leg, whether the conversation still exists, whether the
/// user is even signed in) belongs on this side, where the answers are.
///
/// [id] is minted by the watch rather than here, and it is the whole of the
/// duplicate protection. Both transports can deliver twice: `WCSession`'s
/// `sendMessage` fails when the phone is unreachable and the watch retries
/// through `transferUserInfo`, which is queued and *will* arrive — so a reply
/// sent at the edge of reachability arrives once by each road. Wear's
/// `MessageClient` has the same shape. Sending one message twice is the failure
/// this whole path exists to make impossible, so the id is required and a reply
/// without one is refused rather than guessed at.
@immutable
class WatchReply {
  const WatchReply({
    required this.id,
    required this.chatId,
    required this.body,
    required this.receivedAt,
  });

  /// [raw] as a reply, or null when it is not a usable one.
  ///
  /// Tolerant in the same shape `SnapshotRow.fromJson` is, and for a sharper
  /// reason: this arrives from a hand-written Swift dictionary and a
  /// hand-written Kotlin `DataMap`, neither of which any compiler checks against
  /// this class. What it will *not* tolerate is a missing id, a missing chat id
  /// or an empty body — each of those is a reply that could only be delivered by
  /// guessing, and a guess here sends a real message to a real person.
  static WatchReply? fromJson(Object? raw, {DateTime? receivedAt}) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chatId = raw['chatId'];
    final body = raw['body'];
    if (id is! String || id.isEmpty) return null;
    if (chatId is! String || chatId.isEmpty) return null;
    if (body is! String || body.trim().isEmpty) return null;
    return WatchReply(
      id: id,
      chatId: chatId,
      body: body.trim(),
      receivedAt: receivedAt ?? clock.now(),
    );
  }

  /// The watch's own idempotency key.
  final String id;

  /// `Chat.id`, exactly as the snapshot row carried it. Never re-derived.
  final String chatId;

  /// What the user dictated or tapped, already trimmed.
  final String body;

  /// When the phone accepted it, which is what [WatchReplyHandler.pendingFor]
  /// ages out against.
  final DateTime receivedAt;

  @override
  bool operator ==(Object other) =>
      other is WatchReply &&
      other.id == id &&
      other.chatId == chatId &&
      other.body == body &&
      other.receivedAt == receivedAt;

  @override
  int get hashCode => Object.hash(id, chatId, body, receivedAt);

  @override
  String toString() => 'WatchReply($id → $chatId, ${body.length} chars)';
}

/// Why a reply did not become a message.
///
/// Reported to the watch by name rather than as a sentence, because the watch is
/// the surface that has to phrase it and it is the one that knows how much room
/// it has. The names are the contract; the sentences are in `WeftWatchStrings`
/// and `res/values/strings.xml` on the wear side.
enum WatchReplyFailure {
  /// The chat id is not in the inbox.
  ///
  /// The ordinary cause is not corruption. A merged chat reverts to a bare room
  /// id when one of its legs is left, and a watch may hold a snapshot for hours
  /// afterwards — so a perfectly well-formed row can name a conversation that no
  /// longer exists under that id. Rejecting is the only safe answer: the
  /// alternative is picking some other conversation to send a private message
  /// into.
  unknownChat('unknown_chat'),

  /// Nobody is signed in, or the session went away while the reply was queued.
  notSignedIn('not_signed_in'),

  /// The conversation exists and the send failed — offline, rejected by the
  /// homeserver, a bridge that is down.
  sendFailed('send_failed'),

  /// The reply sat in the queue longer than [WatchReplyHandler.pendingFor]
  /// without the inbox ever arriving.
  ///
  /// A failure rather than a silent drop, which is the whole reason the queue
  /// reports at all: a watch showing "sending…" forever is a message the user
  /// believes they sent.
  timedOut('timed_out'),

  /// The queue was full. Only reachable by a watch replying faster than the
  /// phone can send, which in practice means the phone is not sending at all.
  overflowed('overflowed'),

  /// **Never produced here.** The platform side reports this when a reply
  /// arrived at a process with no Flutter engine in it — Android's
  /// `WearableListenerService` starting the app's process without starting the
  /// app, iOS's `WCSession` delegate firing in a background launch.
  ///
  /// Listed anyway, because the ids are one contract and two watch apps render
  /// them: a failure spelled in `WeftWearProtocol` and in `WeftWatchStrings` but
  /// not here would be an id with no definition anywhere a reader of this file
  /// would look.
  appNotRunning('app_not_running');

  const WatchReplyFailure(this.id);

  /// The string that crosses the channel.
  final String id;
}

/// What the phone tells the watch became of a reply.
@immutable
class WatchReplyResult {
  const WatchReplyResult.sent(this.replyId, {this.network}) : failure = null;

  const WatchReplyResult.failed(this.replyId, this.failure) : network = null;

  final String replyId;

  /// Null on success.
  final WatchReplyFailure? failure;

  /// Which leg it went out on, for a merged conversation.
  ///
  /// Carried back because the watch showed one conversation and Weft may have
  /// several rooms behind it: "Sent via Signal" is the difference between a
  /// confirmation and a guess. Null for a chat with one network, where naming it
  /// would be noise.
  final ChatNetwork? network;

  bool get sent => failure == null;

  Map<String, Object?> toJson() => {
    'id': replyId,
    'sent': sent,
    if (failure != null) 'failure': failure!.id,
    if (network != null) 'network': network!.id,
  };

  @override
  String toString() => sent
      ? 'WatchReplyResult.sent($replyId${network == null ? '' : ' via ${network!.id}'})'
      : 'WatchReplyResult.failed($replyId, ${failure!.id})';
}

/// The watch transport, as the handler needs to see it.
///
/// A seam for the same reason [SnapshotGateway] is: behind it is a `WCSession`
/// on one platform and a `MessageClient` on the other, and every decision this
/// file makes — send, refuse, requeue, report — is a decision that can be wrong
/// without a paired watch being involved.
abstract interface class WatchReplyGateway {
  /// Starts delivering replies to [onReply].
  ///
  /// Called once, when the session comes up. The platform side buffers nothing:
  /// a reply that arrives before this is a reply the watch will report as
  /// unreachable, which is honest — the phone genuinely could not send it.
  void listen(void Function(WatchReply reply) onReply);

  /// Tells the watch what became of a reply.
  ///
  /// Never throws. A watch that has gone out of range is the ordinary case, and
  /// the reply has already been sent by then — failing loudly here would turn a
  /// delivered message into an error in the inbox listener.
  Future<void> report(WatchReplyResult result);

  /// Stops delivering. Called on sign-out, alongside the snapshot clear.
  void stop();
}

/// Accepts replies from a wrist and turns them into sent messages.
///
/// The phone-side half of both watch companions, and the only place either of
/// them can cause a write. A watch may *display* a snapshot and it may *ask* for
/// a message to be sent; it can do nothing else, because it holds no Matrix
/// session — see `docs/architecture/companion-surfaces.md`.
///
/// **Why there is a queue at all.** The obvious implementation sends on arrival
/// and answers with the result. It is wrong in one common case: a reply arrives
/// while the app is being started by the very act of receiving it, so
/// [WatchReplyGateway.listen] fires before the inbox has synced and there is no
/// chat list to resolve the id against yet. Sending on arrival there means
/// answering `unknownChat` for a conversation that exists — telling the user
/// their message failed and then not sending it. So a reply with no inbox to
/// check against waits, and [refresh] is what drains it.
///
/// **Why it reports at all.** Both watch surfaces show a reply as *sending*
/// until they hear back. Nothing else on the phone will ever tell them
/// otherwise, so a reply this class quietly drops is a message the user believes
/// they sent. Every path out of here therefore ends in exactly one
/// [WatchReplyResult] per accepted reply — including the paths where nothing was
/// sent.
class WatchReplyHandler {
  WatchReplyHandler({
    required WatchReplyGateway gateway,
    required WatchReplySender send,
    this.pendingFor = const Duration(minutes: 2),
    this.maxPending = 16,
  }) : _gateway = gateway,
       _send = send;

  final WatchReplyGateway _gateway;
  final WatchReplySender _send;

  /// How long a reply waits for an inbox before it is failed back.
  ///
  /// Two minutes because that is well past a cold start and a first sync on a
  /// slow connection, and well short of the user putting the phone down and
  /// forgetting. Aged on [refresh] and on [accept] rather than on a timer: a
  /// timer in a service that exists to be quiet is a wake-up every user pays for
  /// so that one stalled reply can be marked failed a little sooner.
  final Duration pendingFor;

  /// How many replies wait at once.
  ///
  /// Small on purpose. This is a queue for the seconds between a watch tap and
  /// a synced inbox, not a store-and-forward outbox — the phone is the thing
  /// with an outbox, and a reply that cannot reach it in two minutes is better
  /// reported than hoarded.
  final int maxPending;

  /// The inbox, or null when there is none this process may see.
  ///
  /// Null before the first [refresh] and again after [clear], and the two mean
  /// the same thing: nobody is signed in. Deliberately the same shape
  /// [SnapshotWriter] uses for the same signal, and fed by the same subscription.
  List<Chat>? _chats;

  final Queue<WatchReply> _pending = Queue<WatchReply>();

  /// Ids already accepted, newest last.
  ///
  /// The duplicate guard. Bounded rather than a growing `Set`: this runs for the
  /// life of the process and the only thing it protects against is a redelivery
  /// of a reply the transport sent moments ago, so remembering the last few
  /// dozen is remembering all of them that matter.
  final Queue<String> _handled = Queue<String>();

  static const int _handledMemory = 64;

  bool _draining = false;

  /// What is still waiting, oldest first. For tests and for a debug screen.
  @visibleForTesting
  List<WatchReply> get pending => List.unmodifiable(_pending);

  /// Starts accepting replies.
  ///
  /// Idempotent at the gateway rather than here, because the session state
  /// stream re-emits `ready` on every reconnection and this is wired to it.
  void start() => _gateway.listen(_accept);

  /// Takes a reply from the watch.
  ///
  /// Public because the platform gateway is not the only caller worth having —
  /// a test drives this directly, and so does the debug menu.
  @visibleForTesting
  void accept(WatchReply reply) => _accept(reply);

  void _accept(WatchReply reply) {
    // A redelivery. Answered rather than ignored: the watch retried because it
    // did not hear the first answer, so silence is the one response guaranteed
    // to make it retry again.
    if (_handled.contains(reply.id)) {
      unawaited(_report(WatchReplyResult.sent(reply.id)));
      return;
    }
    _remember(reply.id);

    if (_pending.length >= maxPending) {
      unawaited(
        _report(
          WatchReplyResult.failed(reply.id, WatchReplyFailure.overflowed),
        ),
      );
      return;
    }

    _pending.add(reply);
    unawaited(_drain());
  }

  /// Feeds the handler the current inbox and drains anything waiting on one.
  ///
  /// Called from the same chat-list listener that feeds [SnapshotWriter], and
  /// cheap on every tick: with an empty queue it assigns a list and returns.
  Future<void> refresh(List<Chat> chats) async {
    _chats = chats;
    if (_pending.isEmpty) return;
    await _drain();
  }

  /// Drops the inbox and fails everything still waiting.
  ///
  /// Sign-out, and the one place a pending reply is failed rather than retried.
  /// A reply queued against a session that has gone away cannot be sent by the
  /// next one — it would be sent from a different account, into a room this
  /// device may no longer be in — and the watch is still showing it as sending.
  Future<void> clear() async {
    _chats = null;
    final orphans = _pending.toList(growable: false);
    _pending.clear();
    _gateway.stop();
    for (final reply in orphans) {
      await _report(
        WatchReplyResult.failed(reply.id, WatchReplyFailure.notSignedIn),
      );
    }
  }

  /// Sends everything that can be sent, and reports on everything that cannot.
  ///
  /// Serial rather than concurrent, and that is a decision rather than an
  /// accident: two replies to the same conversation sent in parallel arrive in
  /// whichever order the homeserver accepts them, and a watch's two-tap "yes" /
  /// "on my way" is exactly the case where the order is the meaning.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      // The queue is re-examined from the front on every pass rather than
      // iterated once, because an `await` below is a place a new reply can
      // arrive and a sign-out can empty the queue underneath us.
      while (_pending.isNotEmpty) {
        final reply = _pending.first;

        // Aged before the inbox is consulted rather than only when there is
        // none. A reply that waited out [pendingFor] is one the user has been
        // watching a "sending…" spinner over for two minutes, and an inbox
        // arriving after that — a sign-in, a sync that finally completed — must
        // not turn it into a message sent long after the moment it was about.
        // Sending it late is the failure `pendingFor` names, and it is worse
        // than reporting it: the wrist has already given up on it.
        if (_expired(reply)) {
          _pending.removeFirst();
          await _report(
            WatchReplyResult.failed(reply.id, WatchReplyFailure.timedOut),
          );
          continue;
        }

        final chats = _chats;
        // No inbox yet. Stop — every remaining reply is waiting on the same
        // thing this one is, and none of them is older than it.
        if (chats == null) return;

        _pending.removeFirst();
        await _send1(reply, chats);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _send1(WatchReply reply, List<Chat> chats) async {
    final chat = chats.firstWhereOrNull((chat) => chat.id == reply.chatId);
    if (chat == null) {
      await _report(
        WatchReplyResult.failed(reply.id, WatchReplyFailure.unknownChat),
      );
      return;
    }

    // Resolved here and passed explicitly rather than left to the repository to
    // work out for itself. `send` would reach the same answer — `sendSourceFor`
    // falls back to `Chat.sendNetwork` — but the watch is told which leg its
    // message went out on, and "sent via Signal" has to name the leg that was
    // actually chosen rather than the one this side would have chosen again a
    // moment later.
    final network = chat.sendNetwork;

    try {
      await _send(reply.chatId, reply.body, via: network);
    } catch (error) {
      // Every failure mode of a send is one fact to a wrist: it did not go. The
      // phone keeps the detail — the repository has already logged it, and the
      // conversation shows the failed message when the user opens it.
      debugPrint('weft: watch reply ${reply.id} failed to send: $error');
      await _report(
        WatchReplyResult.failed(reply.id, WatchReplyFailure.sendFailed),
      );
      return;
    }

    await _report(
      WatchReplyResult.sent(
        reply.id,
        // Named only when there is a choice to have made. A one-network
        // conversation reporting "via WhatsApp" is a watch spending a line of a
        // very small screen on something the user could not have changed.
        network: chat.isMerged ? network : null,
      ),
    );
  }

  bool _expired(WatchReply reply) =>
      clock.now().difference(reply.receivedAt) >= pendingFor;

  void _remember(String id) {
    _handled.add(id);
    while (_handled.length > _handledMemory) {
      _handled.removeFirst();
    }
  }

  Future<void> _report(WatchReplyResult result) async {
    try {
      await _gateway.report(result);
    } catch (error) {
      // A watch out of range, an unpaired device, a platform with no watch at
      // all. The message is already sent; there is nothing here worth throwing
      // into a chat-list listener.
      debugPrint('weft: could not report ${result.replyId} to the watch');
    }
  }
}

/// How a reply reaches Matrix.
///
/// A function rather than the whole [ChatRepository], so this file depends on
/// the one call it makes. Wired to `ChatRepository.send` in
/// `snapshot_providers.dart`; a test's is a recorder.
typedef WatchReplySender =
    Future<void> Function(String chatId, String body, {ChatNetwork? via});

/// The watch transport over `com.bostrot.weft/watch`.
///
/// Two implementations behind one channel name, and a third platform where
/// there is none: iOS keeps a `WCSession` alive in `Runner` and talks to
/// `WeftWatch`; Android keeps a `MessageClient` and talks to the `:wear`
/// module; macOS, Linux and Windows have no handler at all, which surfaces as
/// [MissingPluginException] and is answered here as "there is no watch" — the
/// reason [WatchReplyHandler] can be wired up unconditionally.
///
/// ## Why a channel of its own, beside `/snapshot`
///
/// They travel in opposite directions and have different lifetimes. `/snapshot`
/// is the app pushing a payload out and never hearing back; this is a watch
/// pushing a request *in*, at a moment the app did not choose, and it needs a
/// method-call handler installed on the Dart side rather than only a caller.
/// Folding an incoming direction onto a channel whose whole contract is
/// "fire-and-forget writes" is how the write path acquires a reason to be
/// stateful.
///
/// ## What crosses it
///
/// * `onWatchReply(id:chatId:body:)` — **platform → Dart**. One reply.
/// * `reportReply(id:sent:failure:network:)` — Dart → platform. Exactly one per
///   accepted reply.
/// * `stopWatch()` — Dart → platform, on sign-out. Tears the session's reply
///   handling down; the snapshot clear is a separate call on the other channel
///   and deliberately so.
class WeftWatchBridge implements WatchReplyGateway {
  WeftWatchBridge({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.bostrot.weft/watch');

  final MethodChannel _channel;

  void Function(WatchReply reply)? _onReply;

  @override
  void listen(void Function(WatchReply reply) onReply) {
    _onReply = onReply;
    _channel.setMethodCallHandler(_handle);
  }

  @override
  void stop() {
    _onReply = null;
    _channel.setMethodCallHandler(null);
    unawaited(_invoke('stopWatch'));
  }

  @override
  Future<void> report(WatchReplyResult result) =>
      _invoke('reportReply', result.toJson());

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'onWatchReply') return null;
    final reply = WatchReply.fromJson(call.arguments);
    // A malformed reply is dropped rather than reported on, because the id is
    // one of the things that can be missing and there is nothing to report
    // *about*. The watch's own timeout is what surfaces it, which is the only
    // mechanism that works for a message the phone never understood.
    if (reply == null) return null;
    _onReply?.call(reply);
    return null;
  }

  /// [method], or null for every way the platform can decline to answer.
  ///
  /// Both branches are ordinary. [MissingPluginException] is every platform
  /// with no watch companion, and a widget test. [PlatformException] is a
  /// `WCSession` with no paired watch, or a Wear node that has gone out of
  /// range between the reply and the answer.
  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('weft: watch bridge refused $method: ${error.message}');
      return null;
    }
  }
}
