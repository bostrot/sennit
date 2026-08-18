import 'dart:convert';

import 'package:meta/meta.dart';

import 'weft_database.dart';

/// One cached answer to "what is behind this link?".
///
/// [preview] is deliberately nullable and the null is *meaningful*: it records
/// that the homeserver was asked and had nothing to say. A caller that treated
/// a miss as "not cached" would re-ask the same question every time the bubble
/// scrolled back into view, which is both a request the reader never made and a
/// fresh chance to tell the homeserver which links they are being sent.
@immutable
class CachedLinkPreview {
  const CachedLinkPreview({
    required this.url,
    required this.preview,
    required this.fetchedAt,
  });

  final String url;

  /// The preview as JSON, or null when the answer was "nothing".
  final Map<String, Object?>? preview;

  final DateTime fetchedAt;

  bool get isMiss => preview == null;

  /// Whether this answer is older than [ttl].
  bool isStale(Duration ttl, {required DateTime now}) =>
      now.difference(fetchedAt) > ttl;

  @override
  String toString() =>
      'CachedLinkPreview($url, ${isMiss ? 'miss' : 'hit'}, $fetchedAt)';
}

/// The link-preview cache.
///
/// Keyed by url rather than by event, because the same article shared into
/// three conversations is one page and asking about it three times tells the
/// homeserver three things instead of one. Nothing here decides *whether* to
/// ask — that gate lives with the setting, above this — but everything here
/// exists to make sure a question is asked at most once.
///
/// Deliberately holds no preview *images*: `og:image` is stored as the
/// `mxc://` uri the homeserver re-hosted, and the bytes behind it go through
/// the ordinary media path with the ordinary media cache. A second copy of
/// them here would be a second thing to invalidate.
class LinkPreviewStore {
  LinkPreviewStore(this._db);

  final WeftDatabase _db;

  /// What is known about [url], or null when it has never been asked about.
  CachedLinkPreview? read(String url) {
    final rows = _db.raw.select(
      'SELECT preview, fetched_at FROM link_preview WHERE url = ?',
      [url],
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    return CachedLinkPreview(
      url: url,
      preview: _decode(row['preview'] as String?),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(row['fetched_at'] as int),
    );
  }

  /// Records [preview] — or the absence of one — for [url].
  void write(String url, Map<String, Object?>? preview, {DateTime? at}) {
    _db.raw.execute(
      '''
      INSERT INTO link_preview (url, preview, fetched_at) VALUES (?, ?, ?)
      ON CONFLICT(url) DO UPDATE SET
        preview    = excluded.preview,
        fetched_at = excluded.fetched_at
      ''',
      [
        url,
        preview == null ? null : jsonEncode(preview),
        (at ?? DateTime.now()).millisecondsSinceEpoch,
      ],
    );
  }

  /// Drops everything fetched before [cutoff]. Returns how many rows went.
  ///
  /// Age rather than a row cap: the cost this cache exists to avoid is a
  /// *request*, and a two-year-old row for a link nobody has scrolled past
  /// since costs a few hundred bytes and saves that request if they ever do.
  int purgeBefore(DateTime cutoff) {
    _db.raw.execute('DELETE FROM link_preview WHERE fetched_at < ?', [
      cutoff.millisecondsSinceEpoch,
    ]);
    return _db.raw.updatedRows;
  }

  /// Forgets every cached preview.
  ///
  /// What "turn link previews off" has to do beyond stopping new requests:
  /// leaving the rows behind would keep drawing cards from answers the user has
  /// just withdrawn consent for.
  void clear() => _db.raw.execute('DELETE FROM link_preview');

  int get count =>
      _db.raw.select('SELECT COUNT(*) AS n FROM link_preview').first['n']
          as int;

  static Map<String, Object?>? _decode(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      // A corrupt row reads as a miss rather than crashing a scroll.
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
