import 'package:weft/app/intents.dart';
import 'package:weft_domain/weft_domain.dart';

/// A fixed instant every share test ranks against: 2026-03-01 12:00 UTC.
///
/// The same one `packages/weft_share/test/support/fixtures.dart` pins, so a
/// score computed here and a score computed there are the same number — the app
/// suite and the package suite are looking at one ranker.
final DateTime shareNow = DateTime.utc(2026, 3, 1, 12);

/// [d] before [shareNow]. Reads at the call site as the age the test is about.
DateTime shareAgo(Duration d) => shareNow.subtract(d);

/// A chat carrying only what the share surfaces read.
///
/// A near-copy of the `weft_share` fixture, and deliberately a copy: the two
/// suites are in different packages and a `test/` directory is not importable
/// across one. Kept field-for-field identical so a case can be moved between
/// them without being rewritten.
Chat shareChat({
  required String id,
  String? title,
  List<ChatNetwork> networks = const [ChatNetwork.matrix],
  DateTime? lastMessageAt,
  bool pinned = false,
  bool archived = false,
  bool isGroup = false,
  String? avatarUrl,
  ChatNetwork? preferredSendNetwork,
}) {
  return Chat(
    id: id,
    title: title ?? id,
    pinned: pinned,
    archived: archived,
    isGroup: isGroup,
    avatarUrl: avatarUrl,
    // Only the sheet reads it — the shortcut publisher has no share in flight
    // and so no network to choose — but it belongs on the one chat fixture
    // rather than on a second one built beside it.
    preferredSendNetwork: preferredSendNetwork,
    sources: [
      for (final network in networks)
        ChatSource(roomId: '$id/${network.id}', network: network),
    ],
    lastMessage: lastMessageAt == null
        ? null
        : WeftMessage(
            eventId: '\$last_$id',
            roomId: '$id/${networks.first.id}',
            network: networks.first,
            senderId: '@someone:example.org',
            senderName: 'Someone',
            timestamp: lastMessageAt,
            kind: MessageKind.text,
            isOwn: false,
            body: 'hello',
          ),
  );
}

/// A [ShareTargetPublisher] that records instead of calling a launcher.
///
/// The seam that puts `ShareShortcutService` under test without a device: every
/// decision it makes — publish, do not publish, republish, clear — is visible
/// here as a call that did or did not happen.
class RecordingShareTargetPublisher implements ShareTargetPublisher {
  /// One entry per `publishShareTargets` call, in order, holding the slot maps
  /// exactly as the channel would have received them.
  final List<List<Map<String, Object?>>> publishes = [];

  int clears = 0;

  /// How many of each request to accept, standing in for
  /// `getMaxShortcutCountPerActivity`. Null publishes everything asked for.
  int? capacity;

  /// Refuse outright, the way a launcher that will not take shortcuts does.
  bool refuse = false;

  /// The slot maps of the most recent publish.
  List<Map<String, Object?>> get last => publishes.last;

  /// The chat ids of the most recent publish, in published order.
  List<String> get lastChatIds => [
    for (final slot in last) slot['chatId'] as String,
  ];

  @override
  Future<int> publishShareTargets(List<Map<String, Object?>> slots) async {
    publishes.add(slots);
    if (refuse) return 0;
    final cap = capacity;
    return cap == null ? slots.length : (cap < slots.length ? cap : slots.length);
  }

  @override
  Future<void> clearShareTargets() async => clears++;
}
