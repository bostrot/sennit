/// The things an archive holds, one record at a time.
///
/// **Records, not tables.** The archive is a stream: export writes one record
/// and forgets it, import reads one record and applies it. Nothing here ever
/// holds a whole table, which is what lets a 200 000-message backup run in a
/// megabyte and what makes cancellation cheap.
///
/// Every record carries a `type` string, and a reader that meets a type it does
/// not know **skips it and counts it** rather than failing. That is the same
/// bargain `SnapshotCodec` makes, for a sharper version of the same reason: the
/// writer is whichever build the user last had, the reader is whichever build
/// they have now, and the second one is often older.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The record type names, as they appear on the wire.
///
/// String constants rather than an enum's `name`, because these are a format
/// contract: renaming a Dart identifier must not be able to silently orphan
/// every archive already written.
abstract final class BackupRecordType {
  static const String contact = 'contact';
  static const String handle = 'handle';
  static const String mergeDecision = 'merge_decision';
  static const String chatPref = 'chat_pref';
  static const String setting = 'setting';
  static const String message = 'message';
  static const String transcript = 'transcript';

  /// One media file's bytes, content-addressed. Carries a blob.
  static const String media = 'media';

  /// "This event's attachment is the media blob with this hash."
  ///
  /// Split from [media] so that the same photo forwarded into four chats is
  /// stored once and pointed at four times. Without the split, dedup would have
  /// to rewrite events, and a backup is the wrong place to be editing history.
  static const String mediaRef = 'media_ref';
}

/// One entry in the archive body.
@immutable
sealed class BackupRecord {
  const BackupRecord();

  String get type;

  /// The record's own fields, without `type`.
  Map<String, Object?> toJson();

  /// How many bytes follow this record in the stream. Only [MediaRecord] has
  /// any.
  int get blobLength => 0;

  /// Those bytes, in chunks.
  ///
  /// A stream and not a `Uint8List`, which is the difference between an export
  /// that costs a frame of memory and one that costs the size of the largest
  /// video the user was ever sent. Called at most once per record, and only
  /// after [blobLength] has been written — so an implementation that reads a
  /// file must produce exactly that many bytes or the archive it lands in is
  /// malformed. [writeArchive] checks.
  Stream<List<int>> openBlob() => const Stream<List<int>>.empty();

  /// The wire form: `type` merged with [toJson].
  Map<String, Object?> toWireJson() => {'type': type, ...toJson()};
}

/// A record whose `type` this build has never heard of.
///
/// Kept as a value rather than dropped at the parse site so that import can
/// report *how much* it skipped. "Restored 4 300 messages" and "restored 4 300
/// messages, skipped 12 entries this version cannot read" are different
/// sentences, and only the second one is honest about an archive from a newer
/// Braid.
///
/// It is also the **writer**-side escape hatch, and the reason [BackupRecord]
/// can stay `sealed` without closing the format. A source that can answer a
/// question these classes do not model — a Matrix-backed one emitting read
/// receipts, say — emits one of these with its own `type` and fields, and needs
/// no change to this file. What it cannot do is carry a blob; a new
/// bytes-carrying type is a real format addition and should be a real class
/// here, with a minor version bump.
@immutable
final class UnknownRecord extends BackupRecord {
  const UnknownRecord(this.type, this.fields);

  @override
  final String type;

  final Map<String, Object?> fields;

  @override
  Map<String, Object?> toJson() => fields;
}

/// One human, across every network they appear on. Mirrors `unified_contact`.
@immutable
final class ContactRecord extends BackupRecord {
  const ContactRecord({
    required this.id,
    this.displayName = '',
    this.avatarUrl,
    this.pinned = false,
  });

  final String id;
  final String displayName;
  final String? avatarUrl;
  final bool pinned;

  @override
  String get type => BackupRecordType.contact;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'pinned': pinned,
  };

  static ContactRecord? fromJson(Map<Object?, Object?> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return ContactRecord(
      id: id,
      displayName: _string(raw['displayName']) ?? '',
      avatarUrl: _string(raw['avatarUrl']),
      pinned: raw['pinned'] == true,
    );
  }
}

/// One person as they exist on one network. Mirrors `network_handle`.
@immutable
final class HandleRecord extends BackupRecord {
  const HandleRecord({
    required this.id,
    required this.network,
    required this.remoteId,
    required this.matrixUserId,
    this.roomId,
    this.displayName,
    this.avatarUrl,
    this.phoneE164,
    this.email,
    this.avatarDHash,
    this.unifiedContactId,
  });

  final String id;
  final String network;
  final String remoteId;
  final String matrixUserId;
  final String? roomId;
  final String? displayName;
  final String? avatarUrl;
  final String? phoneE164;
  final String? email;
  final int? avatarDHash;
  final String? unifiedContactId;

  @override
  String get type => BackupRecordType.handle;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'network': network,
    'remoteId': remoteId,
    'matrixUserId': matrixUserId,
    'roomId': roomId,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'phoneE164': phoneE164,
    'email': email,
    'avatarDHash': avatarDHash,
    'unifiedContactId': unifiedContactId,
  };

  static HandleRecord? fromJson(Map<Object?, Object?> raw) {
    final id = raw['id'];
    final network = raw['network'];
    if (id is! String || id.isEmpty || network is! String) return null;
    return HandleRecord(
      id: id,
      network: network,
      remoteId: _string(raw['remoteId']) ?? '',
      matrixUserId: _string(raw['matrixUserId']) ?? '',
      roomId: _string(raw['roomId']),
      displayName: _string(raw['displayName']),
      avatarUrl: _string(raw['avatarUrl']),
      phoneE164: _string(raw['phoneE164']),
      email: _string(raw['email']),
      avatarDHash: raw['avatarDHash'] is int ? raw['avatarDHash'] as int : null,
      unifiedContactId: _string(raw['unifiedContactId']),
    );
  }
}

/// A sticky merge verdict. Mirrors `merge_decision`.
///
/// The single most irreplaceable thing in the archive, and the reason this
/// phase exists at all: everything else can in principle be re-synced from a
/// homeserver, but "these two accounts are the same person, I decided" exists
/// nowhere but here.
@immutable
final class MergeDecisionRecord extends BackupRecord {
  const MergeDecisionRecord({
    required this.pair,
    required this.verdict,
    required this.source,
    required this.decidedAt,
  });

  final String pair;
  final String verdict;
  final String source;
  final DateTime decidedAt;

  @override
  String get type => BackupRecordType.mergeDecision;

  @override
  Map<String, Object?> toJson() => {
    'pair': pair,
    'verdict': verdict,
    'source': source,
    'decidedAt': decidedAt.toUtc().millisecondsSinceEpoch,
  };

  static MergeDecisionRecord? fromJson(Map<Object?, Object?> raw) {
    final pair = raw['pair'];
    final verdict = raw['verdict'];
    if (pair is! String || pair.isEmpty || verdict is! String) return null;
    return MergeDecisionRecord(
      pair: pair,
      verdict: verdict,
      source: _string(raw['source']) ?? '',
      decidedAt: _timestamp(raw['decidedAt']),
    );
  }
}

/// Which network the user chose to send on in one chat. Mirrors `chat_prefs`.
@immutable
final class ChatPrefRecord extends BackupRecord {
  const ChatPrefRecord({
    required this.chatId,
    this.sendNetwork,
    required this.updatedAt,
  });

  final String chatId;
  final String? sendNetwork;
  final DateTime updatedAt;

  @override
  String get type => BackupRecordType.chatPref;

  @override
  Map<String, Object?> toJson() => {
    'chatId': chatId,
    'sendNetwork': sendNetwork,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
  };

  static ChatPrefRecord? fromJson(Map<Object?, Object?> raw) {
    final chatId = raw['chatId'];
    if (chatId is! String || chatId.isEmpty) return null;
    return ChatPrefRecord(
      chatId: chatId,
      sendNetwork: _string(raw['sendNetwork']),
      updatedAt: _timestamp(raw['updatedAt']),
    );
  }
}

/// One row of the `settings` key/value table.
@immutable
final class SettingRecord extends BackupRecord {
  const SettingRecord({required this.key, required this.value});

  final String key;
  final String value;

  @override
  String get type => BackupRecordType.setting;

  @override
  Map<String, Object?> toJson() => {'key': key, 'value': value};

  static SettingRecord? fromJson(Map<Object?, Object?> raw) {
    final key = raw['key'];
    final value = raw['value'];
    if (key is! String || key.isEmpty || value is! String) return null;
    return SettingRecord(key: key, value: value);
  }
}

/// One message, as Braid's own store knows it.
///
/// This is the cross-network history the phase brief is about. It is
/// deliberately *Braid's* view — the unified chat id, the network the message
/// arrived on, the sender's name as Braid resolved it, the body already
/// projected to plain text by `SearchStore.indexMessage` — and not a Matrix
/// event. A Matrix event would be re-derivable from a homeserver; this view is
/// not, because it is the product of merge decisions and bridges that may be
/// gone by the time the archive is opened.
///
/// [reactions] rides along as a tally per emoji. Braid's own store does not
/// persist reactions — they are aggregated live from the Matrix timeline — so a
/// store-sourced export leaves this empty. The field exists because the record
/// is the format's message, not the store's, and a source that *can* answer the
/// question must not need a version bump to say so.
@immutable
final class MessageRecord extends BackupRecord {
  const MessageRecord({
    required this.eventId,
    required this.roomId,
    required this.chatId,
    required this.network,
    required this.senderId,
    required this.timestamp,
    required this.kind,
    required this.body,
    this.senderName = '',
    this.chatTitle = '',
    this.hasMedia = false,
    this.reactions = const <String, int>{},
  });

  final String eventId;
  final String roomId;
  final String chatId;
  final String network;
  final String senderId;
  final DateTime timestamp;

  /// `MessageKind.name`. A string for the reason [ArchiveManifest.networks] is:
  /// an archive that names a kind this build removed should still restore the
  /// message, with the kind degraded at the seam rather than the row dropped.
  final String kind;

  final String body;
  final String senderName;
  final String chatTitle;
  final bool hasMedia;

  /// Emoji to count.
  final Map<String, int> reactions;

  @override
  String get type => BackupRecordType.message;

  @override
  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'roomId': roomId,
    'chatId': chatId,
    'network': network,
    'senderId': senderId,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
    'kind': kind,
    'body': body,
    'senderName': senderName,
    'chatTitle': chatTitle,
    'hasMedia': hasMedia,
    if (reactions.isNotEmpty) 'reactions': reactions,
  };

  /// The identity a merge import keys on.
  ///
  /// `(eventId, roomId)` and not `eventId` alone, because that is the pair the
  /// `search_message` unique index uses and the pair a bridge can repeat: the
  /// same remote message backfilled into two rooms is two rows, and collapsing
  /// them here would delete one of them on every restore.
  String get identity => '$roomId $eventId';

  static MessageRecord? fromJson(Map<Object?, Object?> raw) {
    final eventId = raw['eventId'];
    final roomId = raw['roomId'];
    if (eventId is! String || eventId.isEmpty) return null;
    if (roomId is! String || roomId.isEmpty) return null;

    final reactions = <String, int>{};
    final rawReactions = raw['reactions'];
    if (rawReactions is Map) {
      for (final entry in rawReactions.entries) {
        final key = entry.key;
        final count = entry.value;
        if (key is String && count is int && count > 0) reactions[key] = count;
      }
    }

    return MessageRecord(
      eventId: eventId,
      roomId: roomId,
      // Falls back to the room rather than to empty: a chat id is what the
      // inbox groups on, and a blank one would pile every such message into a
      // single nameless conversation.
      chatId: _string(raw['chatId']) ?? roomId,
      network: _string(raw['network']) ?? '',
      senderId: _string(raw['senderId']) ?? '',
      timestamp: _timestamp(raw['timestamp']),
      kind: _string(raw['kind']) ?? 'text',
      body: _string(raw['body']) ?? '',
      senderName: _string(raw['senderName']) ?? '',
      chatTitle: _string(raw['chatTitle']) ?? '',
      hasMedia: raw['hasMedia'] == true,
      reactions: reactions,
    );
  }
}

/// A finished voice transcription. Mirrors `transcript`.
@immutable
final class TranscriptRecord extends BackupRecord {
  const TranscriptRecord({
    required this.eventId,
    required this.roomId,
    required this.text,
    this.provider = '',
    this.language,
    required this.createdAt,
  });

  final String eventId;
  final String roomId;
  final String text;
  final String provider;
  final String? language;
  final DateTime createdAt;

  @override
  String get type => BackupRecordType.transcript;

  @override
  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'roomId': roomId,
    'text': text,
    'provider': provider,
    'language': language,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
  };

  static TranscriptRecord? fromJson(Map<Object?, Object?> raw) {
    final eventId = raw['eventId'];
    final roomId = raw['roomId'];
    final text = raw['text'];
    if (eventId is! String || eventId.isEmpty) return null;
    if (roomId is! String || roomId.isEmpty) return null;
    if (text is! String) return null;
    return TranscriptRecord(
      eventId: eventId,
      roomId: roomId,
      text: text,
      provider: _string(raw['provider']) ?? '',
      language: _string(raw['language']),
      createdAt: _timestamp(raw['createdAt']),
    );
  }
}

/// One media file's bytes, addressed by the SHA-256 of its content.
///
/// **Import never builds one of these with usable bytes.** The record's job on
/// the way in is to name a hash and a length; the bytes themselves go from the
/// decrypted frame stream to the sink a chunk at a time without ever being a
/// value. See `BackupSink.beginMedia`.
@immutable
final class MediaRecord extends BackupRecord {
  const MediaRecord({
    required this.sha256,
    required this.sizeBytes,
    required Stream<List<int>> Function() openBytes,
  }) : _openBytes = openBytes;

  /// A record over bytes already in memory — a small file, or a test fixture.
  MediaRecord.ofBytes({required this.sha256, required Uint8List bytes})
    : sizeBytes = bytes.length,
      _openBytes = (() => Stream<List<int>>.value(bytes));

  /// Lowercase hex, as [mediaContentHash] produces it.
  final String sha256;
  final int sizeBytes;
  final Stream<List<int>> Function() _openBytes;

  @override
  int get blobLength => sizeBytes;

  @override
  Stream<List<int>> openBlob() => _openBytes();

  @override
  String get type => BackupRecordType.media;

  @override
  Map<String, Object?> toJson() => {'sha256': sha256, 'sizeBytes': sizeBytes};

  /// The record's *header*, with no bytes behind it.
  ///
  /// The declared `sizeBytes` here is a courtesy: the authoritative length is
  /// the blob length the frame stream carries alongside the record, which is
  /// what import reads. Trusting this one instead would let a record and its
  /// blob disagree about where the next record starts.
  static MediaRecord? fromJson(Map<Object?, Object?> raw) {
    final hash = raw['sha256'];
    if (hash is! String || hash.isEmpty) return null;
    final size = raw['sizeBytes'];
    return MediaRecord(
      sha256: hash,
      sizeBytes: size is int && size >= 0 ? size : 0,
      openBytes: () => const Stream<List<int>>.empty(),
    );
  }
}

/// Where a [MediaRecord]'s bytes belong once restored.
@immutable
final class MediaRefRecord extends BackupRecord {
  const MediaRefRecord({
    required this.eventId,
    required this.sha256,
    required this.fileName,
  });

  final String eventId;
  final String sha256;

  /// The name the file sat under, already sanitised by the writer — this is
  /// `attachmentFileName`'s output, not a sender-supplied string. The reader
  /// sanitises again anyway: an archive is an untrusted file, and `../../` in
  /// here would otherwise decide where a restore writes.
  final String fileName;

  @override
  String get type => BackupRecordType.mediaRef;

  @override
  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'sha256': sha256,
    'fileName': fileName,
  };

  static MediaRefRecord? fromJson(Map<Object?, Object?> raw) {
    final eventId = raw['eventId'];
    final hash = raw['sha256'];
    final name = raw['fileName'];
    if (eventId is! String || eventId.isEmpty) return null;
    if (hash is! String || hash.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    return MediaRefRecord(eventId: eventId, sha256: hash, fileName: name);
  }
}

// ---------------------------------------------------------------- decoding

/// [json] as a record, or null when it is not usable at all.
///
/// Three outcomes, and the middle one is the one this format is built around:
///
/// * a known type that parses — the record;
/// * an **unknown** type — an [UnknownRecord], which import counts and skips;
/// * a known type whose required fields are missing — null, the one case where
///   a record is genuinely dropped, because a message with no event id cannot
///   be merged against anything.
BackupRecord? decodeBackupRecord(Object? json) {
  if (json is! Map) return null;
  final type = json['type'];
  if (type is! String || type.isEmpty) return null;

  return switch (type) {
    BackupRecordType.contact => ContactRecord.fromJson(json),
    BackupRecordType.handle => HandleRecord.fromJson(json),
    BackupRecordType.mergeDecision => MergeDecisionRecord.fromJson(json),
    BackupRecordType.chatPref => ChatPrefRecord.fromJson(json),
    BackupRecordType.setting => SettingRecord.fromJson(json),
    BackupRecordType.message => MessageRecord.fromJson(json),
    BackupRecordType.transcript => TranscriptRecord.fromJson(json),
    BackupRecordType.media => MediaRecord.fromJson(json),
    BackupRecordType.mediaRef => MediaRefRecord.fromJson(json),
    _ => UnknownRecord(type, {
      for (final entry in json.entries)
        if (entry.key is String && entry.key != 'type')
          entry.key as String: entry.value,
    }),
  };
}

/// [record] as the bytes that go into the payload stream.
Uint8List encodeBackupRecord(BackupRecord record) =>
    utf8.encode(jsonEncode(record.toWireJson()));

String? _string(Object? raw) => raw is String ? raw : null;

/// Milliseconds since the epoch, in UTC, degrading to the epoch itself.
///
/// Always UTC for the reason `IdentityStore.loadDecisions` gives: the stored
/// value carries no zone, and handing back local time makes a restored decision
/// compare unequal to the one that was written on a machine in another zone —
/// which in a *merge* import is the difference between recognising a row and
/// duplicating it.
DateTime _timestamp(Object? raw) =>
    DateTime.fromMillisecondsSinceEpoch(raw is int ? raw : 0, isUtc: true);
