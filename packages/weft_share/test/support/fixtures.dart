import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

/// A fixed "now" every test ranks against: 2026-03-01 12:00 UTC.
///
/// [ShareTargetRanker.rank] takes `now` as an argument precisely so the suite
/// can pin it. Every term in the score is an age, and a fixture that called
/// `DateTime.now()` would make each assertion below depend on the hour the test
/// happened to run.
final DateTime now = DateTime.utc(2026, 3, 1, 12);

/// [d] before [now]. Reads at the call site as the age the test is about.
DateTime ago(Duration d) => now.subtract(d);

/// A chat carrying only what the ranker reads.
///
/// [networks] becomes one [ChatSource] per network, which is what makes a
/// multi-network chat a *merged* one as far as [Chat.networks] is concerned.
/// The room ids are derived rather than passed because nothing in this package
/// reads them — only their count and their networks.
Chat chat({
  required String id,
  String? title,
  List<ChatNetwork> networks = const [ChatNetwork.matrix],
  DateTime? lastMessageAt,
  bool pinned = false,
  bool archived = false,
  bool isGroup = false,
  String? avatarUrl,
}) {
  return Chat(
    id: id,
    title: title ?? id,
    pinned: pinned,
    archived: archived,
    isGroup: isGroup,
    avatarUrl: avatarUrl,
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

/// A chat with sources stripped out — the transient state a merge rebuild
/// passes through, which the ranker must never publish.
Chat sourcelessChat({required String id, String? title}) =>
    Chat(id: id, title: title ?? id, sources: const []);

/// [count] sends, the most recent [since] ago.
ChatShareActivity sends(int count, {Duration since = Duration.zero}) =>
    ChatShareActivity(sendCount: count, lastSentAt: ago(since));

/// One shared file of [bytes], typed [mimeType].
ShareItem item(String mimeType, int bytes, {String? filename}) =>
    ShareItem(mimeType: mimeType, sizeBytes: bytes, filename: filename);

const int kib = 1024;
const int mib = 1024 * 1024;

/// A share of one file, no text.
ShareContent fileShare(String mimeType, int bytes) =>
    ShareContent.files([item(mimeType, bytes)]);

/// The chat ids [slots] point at, in published order. Every ordering assertion
/// in `ranker_test.dart` is really about this list.
List<String> chatIdsOf(List<ShareTargetSlot> slots) => [
  for (final slot in slots) slot.chatId,
];

/// A staged file with defaults for everything a test is not asking about.
StagedFile stagedFile({
  String relativePath = 'staged/abc/photo.jpg',
  String name = 'photo.jpg',
  String mimeType = 'image/jpeg',
  int sizeBytes = 4 * kib,
}) => StagedFile(
  relativePath: relativePath,
  name: name,
  mimeType: mimeType,
  sizeBytes: sizeBytes,
);

/// A staged share with defaults for everything a test is not asking about.
StagedShare stagedShare({
  String id = 'capture_1',
  DateTime? capturedAt,
  String? text = 'https://example.org/article',
  List<StagedFile>? files,
  String? targetChatId,
  Map<String, Object?> extras = const {},
}) => StagedShare(
  id: id,
  capturedAt: capturedAt ?? ago(const Duration(minutes: 5)),
  text: text,
  files: files ?? [stagedFile()],
  targetChatId: targetChatId,
  extras: extras,
);
