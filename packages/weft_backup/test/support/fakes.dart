/// A source and a sink built out of maps, so every test in this package runs
/// without a database, a device or a disk.
///
/// The sink models the two things a real one has to get right and that are easy
/// to get wrong in SQL: **merge is keyed and idempotent**, and **rollback puts
/// everything back**. Both are checked here against an implementation simple
/// enough to read in one sitting, which is what makes a failure in the SQLite
/// adapter attributable to the SQL rather than to the format.
library;

import 'dart:typed_data';

import 'package:weft_backup/weft_backup.dart';

/// Cheap Argon2id parameters, for tests only.
///
/// 8 KiB and one pass, against the 64 MiB and three passes a real archive uses.
/// Every case here is about framing, merging and failure typing; paying the
/// real KDF for each would turn a two-second suite into a five-minute one and
/// buy nothing, because the *parameters* are what the header carries and
/// `crypto_test.dart` covers that separately.
KdfParameters cheapKdf({int seed = 1}) => KdfParameters(
  salt: Uint8List.fromList(List<int>.generate(16, (i) => (i + seed) & 0xFF)),
  memoryKiB: 8,
  iterations: 1,
  parallelism: 1,
);

/// A source over a fixed list of records.
class FakeSource implements BackupSource {
  FakeSource(this.all, {this.summary = const BackupSummary()});

  final List<BackupRecord> all;
  final BackupSummary summary;

  @override
  Future<BackupSummary> summarise({required bool includeMedia}) async =>
      summary;

  @override
  Stream<BackupRecord> records({required bool includeMedia}) =>
      Stream<BackupRecord>.fromIterable(
        includeMedia
            ? all
            : all.where((r) => r is! MediaRecord && r is! MediaRefRecord),
      );
}

/// A source whose records come from a callback, so a test can generate more
/// than it wants to hold.
class GeneratedSource implements BackupSource {
  GeneratedSource({required this.summary, required this.generate});

  final BackupSummary summary;
  final Stream<BackupRecord> Function({required bool includeMedia}) generate;

  @override
  Future<BackupSummary> summarise({required bool includeMedia}) async =>
      summary;

  @override
  Stream<BackupRecord> records({required bool includeMedia}) =>
      generate(includeMedia: includeMedia);
}

/// The state a [MapSink] holds, as plain maps keyed the way the real store is.
class SinkState {
  final Map<String, ContactRecord> contacts = {};
  final Map<String, HandleRecord> handles = {};
  final Map<String, MergeDecisionRecord> merges = {};
  final Map<String, ChatPrefRecord> chatPrefs = {};
  final Map<String, String> settings = {};
  final Map<String, MessageRecord> messages = {};
  final Map<String, TranscriptRecord> transcripts = {};

  /// Content hash to bytes.
  final Map<String, Uint8List> media = {};

  /// Event id to (hash, file name).
  final Map<String, MediaRefRecord> mediaRefs = {};

  int get totalRows =>
      contacts.length +
      handles.length +
      merges.length +
      chatPrefs.length +
      settings.length +
      messages.length +
      transcripts.length;

  SinkState copy() {
    return SinkState()
      ..contacts.addAll(contacts)
      ..handles.addAll(handles)
      ..merges.addAll(merges)
      ..chatPrefs.addAll(chatPrefs)
      ..settings.addAll(settings)
      ..messages.addAll(messages)
      ..transcripts.addAll(transcripts)
      ..media.addAll(media)
      ..mediaRefs.addAll(mediaRefs);
  }

  void restoreFrom(SinkState other) {
    contacts
      ..clear()
      ..addAll(other.contacts);
    handles
      ..clear()
      ..addAll(other.handles);
    merges
      ..clear()
      ..addAll(other.merges);
    chatPrefs
      ..clear()
      ..addAll(other.chatPrefs);
    settings
      ..clear()
      ..addAll(other.settings);
    messages
      ..clear()
      ..addAll(other.messages);
    transcripts
      ..clear()
      ..addAll(other.transcripts);
    media
      ..clear()
      ..addAll(other.media);
    mediaRefs
      ..clear()
      ..addAll(other.mediaRefs);
  }

  void clear() => restoreFrom(SinkState());
}

/// An in-memory [BackupSink] with real merge and rollback semantics.
class MapSink implements BackupSink {
  MapSink([SinkState? state]) : state = state ?? SinkState();

  final SinkState state;

  SinkState? _snapshot;
  bool committed = false;
  bool rolledBack = false;

  /// Media the sink refuses to write again, by hash — what a real sink answers
  /// from the files already on disk.
  final Set<String> refuseMedia = {};

  @override
  Future<void> begin(ImportMode mode) async {
    _snapshot = state.copy();
    if (mode == ImportMode.replace) state.clear();
  }

  @override
  Future<bool> apply(BackupRecord record) async {
    return switch (record) {
      final ContactRecord r => _put(state.contacts, r.id, r),
      final HandleRecord r => _put(state.handles, r.id, r),
      final MergeDecisionRecord r => _put(state.merges, r.pair, r),
      final ChatPrefRecord r => _put(state.chatPrefs, r.chatId, r),
      final SettingRecord r => _putSetting(r.key, r.value),
      final MessageRecord r => _put(state.messages, r.identity, r),
      final TranscriptRecord r => _put(
        state.transcripts,
        '${r.roomId} ${r.eventId}',
        r,
      ),
      final MediaRefRecord r => _put(state.mediaRefs, r.eventId, r),
      // Media never arrives here — `importArchive` routes it to [beginMedia].
      _ => false,
    };
  }

  @override
  Future<MediaWriter?> beginMedia(String sha256, int sizeBytes) async {
    if (refuseMedia.contains(sha256) || state.media.containsKey(sha256)) {
      return null;
    }
    return _MapMediaWriter(this, sha256);
  }

  @override
  Future<void> commit() async {
    committed = true;
    _snapshot = null;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
    final snapshot = _snapshot;
    if (snapshot != null) state.restoreFrom(snapshot);
    _snapshot = null;
  }

  /// Merge semantics: an existing key is left exactly as it was.
  bool _put<T>(Map<String, T> into, String key, T value) {
    if (into.containsKey(key)) return false;
    into[key] = value;
    return true;
  }

  bool _putSetting(String key, String value) {
    if (state.settings.containsKey(key)) return false;
    state.settings[key] = value;
    return true;
  }
}

class _MapMediaWriter implements MediaWriter {
  _MapMediaWriter(this._sink, this._hash);

  final MapSink _sink;
  final String _hash;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  bool _aborted = false;

  @override
  Future<void> add(List<int> bytes) async {
    if (_aborted) return;
    _bytes.add(bytes);
  }

  /// Only on [finish] does the content become visible, which is the in-memory
  /// stand-in for the `.part`-then-rename a file writer does.
  @override
  Future<void> finish() async {
    if (_aborted) return;
    _sink.state.media[_hash] = _bytes.toBytes();
  }

  @override
  Future<void> abort() async {
    _aborted = true;
    _bytes.clear();
  }
}
