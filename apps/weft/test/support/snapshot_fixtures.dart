import 'package:weft/services/snapshot/snapshot_writer.dart';
import 'package:weft/services/snapshot/watch_reply_handler.dart';
import 'package:weft_domain/weft_domain.dart';

/// The fixtures the three companion-surface suites share.
///
/// The chat builders are a near-copy of
/// `packages/weft_snapshot/test/support/fixtures.dart`, and deliberately a copy
/// for the reason `share_fixtures.dart` states: a `test/` directory is not
/// importable across packages. Kept field-for-field identical so a case can move
/// between the two suites without being rewritten — the package asks what a
/// policy discloses, and these three files ask what the app does with the answer.
///
/// The two recording gateways are this layer's own. Behind each is a method
/// channel and a device — an App Group directory, a paired watch — and neither
/// exists in a `flutter test` process. What is testable is every decision made
/// on this side of them, which is what a gateway that records rather than calls
/// makes visible.

/// A fixed "now" every test builds against: 2026-04-01 09:00 UTC.
///
/// The same instant the package suite pins, so a payload built here and one
/// built there are byte-identical and a fixture can be read across.
final DateTime snapshotNow = DateTime.utc(2026, 4, 1, 9);

/// [d] before [snapshotNow]. Reads at the call site as the age the test is about.
DateTime snapshotAgo(Duration d) => snapshotNow.subtract(d);

/// A message with only what a snapshot row and a watch reply read.
WeftMessage snapshotMessage({
  String eventId = r'$event_1',
  String roomId = '!room:example.org',
  ChatNetwork network = ChatNetwork.whatsapp,
  String senderId = '@whatsapp_grace:example.org',
  String senderName = 'Grace',
  DateTime? timestamp,
  MessageKind kind = MessageKind.text,
  bool isOwn = false,
  String body = 'hello',
}) {
  return WeftMessage(
    eventId: eventId,
    roomId: roomId,
    network: network,
    senderId: senderId,
    senderName: senderName,
    timestamp: timestamp ?? snapshotNow,
    kind: kind,
    isOwn: isOwn,
    body: body,
  );
}

/// A chat carrying only what the policy, the row builder and the reply path read.
///
/// [networks] becomes one [ChatSource] per network, which is what makes a
/// multi-network chat *merged* as far as [Chat.isMerged] and [Chat.networks] are
/// concerned.
Chat snapshotChat({
  String id = '!room:example.org',
  String title = 'Grace',
  List<ChatNetwork> networks = const [ChatNetwork.whatsapp],
  WeftMessage? lastMessage,
  int unreadCount = 0,
  String? avatarUrl,
  bool isGroup = false,
  ChatNetwork? preferredSendNetwork,
}) {
  return Chat(
    id: id,
    title: title,
    unreadCount: unreadCount,
    avatarUrl: avatarUrl,
    isGroup: isGroup,
    lastMessage: lastMessage,
    preferredSendNetwork: preferredSendNetwork,
    sources: [
      for (final network in networks)
        ChatSource(roomId: '$id/${network.id}', network: network),
    ],
  );
}

/// A merged chat: one contact, two legs, and the `merged:<contactId>` id the
/// repository mints — the id a row keys on and a watch replies to.
Chat mergedSnapshotChat({
  String contactId = 'contact_1',
  String title = 'Grace',
  List<ChatNetwork> networks = const [ChatNetwork.whatsapp, ChatNetwork.signal],
  WeftMessage? lastMessage,
  int unreadCount = 0,
  ChatNetwork? preferredSendNetwork,
}) {
  return Chat(
    id: 'merged:$contactId',
    title: title,
    contactId: contactId,
    unreadCount: unreadCount,
    lastMessage: lastMessage,
    preferredSendNetwork: preferredSendNetwork,
    sources: [
      for (final network in networks)
        ChatSource(
          roomId: '!${network.id}_$contactId:example.org',
          network: network,
        ),
    ],
  );
}

/// One call to [SnapshotGateway.writeSnapshot], exactly as the channel saw it.
class SnapshotWrite {
  const SnapshotWrite({
    required this.json,
    required this.widgets,
    required this.watch,
  });

  /// The encoded payload, unparsed — which is how it crosses the channel.
  final String json;

  final bool widgets;
  final bool watch;

  @override
  String toString() =>
      'SnapshotWrite(${json.length} bytes, widgets: $widgets, watch: $watch)';
}

/// A shared container that records instead of writing one.
///
/// The seam that puts [SnapshotWriter] under test without a device: every
/// decision it makes — write, do not write, rewrite, delete — is visible here as
/// a call that did or did not happen.
class RecordingSnapshotGateway implements SnapshotGateway {
  /// Every write, in order.
  final List<SnapshotWrite> writes = [];

  int clears = 0;

  /// Refuse to store anything, the way an unentitled build or a platform with
  /// no handler does. The call is still recorded — it happened, it just stored
  /// nothing.
  bool refuse = false;

  SnapshotWrite get last => writes.last;

  @override
  Future<bool> writeSnapshot(
    String json, {
    required bool widgets,
    required bool watch,
  }) async {
    writes.add(SnapshotWrite(json: json, widgets: widgets, watch: watch));
    return !refuse;
  }

  @override
  Future<void> clearSnapshot() async => clears++;
}

/// A watch transport that records instead of reaching a wrist.
///
/// [deliver] is the watch tapping send; [reported] is what the phone told it
/// became of that. The pair is the whole of what
/// `watch_reply_test.dart` asserts: exactly one report per accepted reply,
/// including the replies where nothing was sent.
class RecordingWatchGateway implements WatchReplyGateway {
  final List<WatchReplyResult> reported = [];

  int listens = 0;
  int stops = 0;

  /// Report the way a watch that has gone out of range does. The reply has
  /// already been sent by then, so this must not surface as an error.
  bool throwOnReport = false;

  void Function(WatchReply reply)? _onReply;

  /// Whether anything is listening, which is what [WatchReplyHandler.start] and
  /// `clear` move between.
  bool get listening => _onReply != null;

  /// The failure ids reported, in order. What both watch string tables switch on.
  List<String?> get failures => [
    for (final result in reported) result.failure?.id,
  ];

  /// One reply arriving from the watch.
  void deliver(WatchReply reply) {
    final onReply = _onReply;
    if (onReply == null) {
      throw StateError('a reply arrived with nothing listening for it');
    }
    onReply(reply);
  }

  @override
  void listen(void Function(WatchReply reply) onReply) {
    listens++;
    _onReply = onReply;
  }

  @override
  Future<void> report(WatchReplyResult result) async {
    if (throwOnReport) throw StateError('the watch is out of range');
    reported.add(result);
  }

  @override
  void stop() {
    stops++;
    _onReply = null;
  }
}

/// A [WatchReplySender] that records what it was asked to send.
///
/// Records the arguments rather than the fact of a call, for the reason
/// `RecordedCall` does: the whole question on this path is *which conversation*
/// and *which leg*, and a spy that counted calls could not tell a reply sent on
/// the chat's own network from one sent on whichever network was first.
class RecordingWatchSender {
  RecordingWatchSender({this.onSend});

  /// Throw from here to fail a send the way an offline homeserver does.
  final void Function(String chatId)? onSend;

  final List<({String chatId, String body, ChatNetwork? via})> sent = [];

  List<String> get bodies => [for (final call in sent) call.body];

  Future<void> call(String chatId, String body, {ChatNetwork? via}) async {
    // Yielding before recording is what makes a serial drain distinguishable
    // from a concurrent one: with two sends in flight, an implementation that
    // did not await the first would record them interleaved.
    await Future<void>.delayed(Duration.zero);
    onSend?.call(chatId);
    sent.add((chatId: chatId, body: body, via: via));
  }
}
