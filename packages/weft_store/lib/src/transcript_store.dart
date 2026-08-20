import 'weft_database.dart';

/// A stored transcription of one voice message.
class StoredTranscript {
  const StoredTranscript({
    required this.eventId,
    required this.roomId,
    required this.text,
    this.provider = '',
    this.language,
  });

  final String eventId;
  final String roomId;
  final String text;
  final String provider;
  final String? language;
}

/// Keeps finished transcriptions.
///
/// Written once per transcription, read on every chat open — so a voice note
/// transcribed last week still shows its words, and never has to be paid for
/// twice.
class TranscriptStore {
  TranscriptStore(this._db);

  final WeftDatabase _db;

  void save(StoredTranscript transcript) {
    _db.raw.execute(
      '''
      INSERT INTO transcript (event_id, room_id, text, provider, language, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id, room_id) DO UPDATE SET
        text     = excluded.text,
        provider = excluded.provider,
        language = excluded.language
      ''',
      [
        transcript.eventId,
        transcript.roomId,
        transcript.text,
        transcript.provider,
        transcript.language,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  StoredTranscript? byEvent(String eventId, String roomId) {
    final rows = _db.raw.select(
      'SELECT * FROM transcript WHERE event_id = ? AND room_id = ?',
      [eventId, roomId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return StoredTranscript(
      eventId: row['event_id'] as String,
      roomId: row['room_id'] as String,
      text: row['text'] as String,
      provider: (row['provider'] as String?) ?? '',
      language: row['language'] as String?,
    );
  }

  /// Every stored transcript, for re-planting into the search index.
  List<StoredTranscript> all() {
    return _db.raw
        .select('SELECT * FROM transcript')
        .map(
          (row) => StoredTranscript(
            eventId: row['event_id'] as String,
            roomId: row['room_id'] as String,
            text: row['text'] as String,
            provider: (row['provider'] as String?) ?? '',
            language: row['language'] as String?,
          ),
        )
        .toList(growable: false);
  }
}
