import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// How the two retrieval methods are balanced.
enum SearchMode {
  /// Both, fused. The default, and the only one that finds a message you can
  /// describe but not quote.
  hybrid,

  /// Keywords only. Fast, exact, and works before any embedding endpoint is
  /// configured — which is why it is also the automatic fallback.
  keyword,

  /// Meaning only. Useful when the user knows the gist and none of the words.
  semantic,
}

/// A search request, including its filters.
@immutable
class SearchQuery {
  const SearchQuery({
    required this.text,
    this.mode = SearchMode.hybrid,
    this.networks = const {},
    this.chatIds = const {},
    this.senderIds = const {},
    this.after,
    this.before,
    this.hasMedia,
    this.limit = 50,
  });

  final String text;
  final SearchMode mode;

  /// Empty means "any".
  final Set<ChatNetwork> networks;
  final Set<String> chatIds;
  final Set<String> senderIds;

  final DateTime? after;
  final DateTime? before;

  /// When set, restricts to messages that do (or do not) carry an attachment.
  final bool? hasMedia;

  final int limit;

  bool get hasFilters =>
      networks.isNotEmpty ||
      chatIds.isNotEmpty ||
      senderIds.isNotEmpty ||
      after != null ||
      before != null ||
      hasMedia != null;

  bool get isEmpty => text.trim().isEmpty && !hasFilters;

  SearchQuery copyWith({
    String? text,
    SearchMode? mode,
    Set<ChatNetwork>? networks,
    Set<String>? chatIds,
    Set<String>? senderIds,
    Object? after = _sentinel,
    Object? before = _sentinel,
    Object? hasMedia = _sentinel,
    int? limit,
  }) {
    return SearchQuery(
      text: text ?? this.text,
      mode: mode ?? this.mode,
      networks: networks ?? this.networks,
      chatIds: chatIds ?? this.chatIds,
      senderIds: senderIds ?? this.senderIds,
      after: identical(after, _sentinel) ? this.after : after as DateTime?,
      before: identical(before, _sentinel) ? this.before : before as DateTime?,
      hasMedia: identical(hasMedia, _sentinel)
          ? this.hasMedia
          : hasMedia as bool?,
      limit: limit ?? this.limit,
    );
  }

  static const Object _sentinel = Object();
}

/// One result, with enough context to render a row without a second lookup.
@immutable
class SearchResult {
  const SearchResult({
    required this.eventId,
    required this.roomId,
    required this.chatId,
    required this.network,
    required this.senderId,
    required this.timestamp,
    required this.kind,
    required this.body,
    required this.score,
    this.senderName = '',
    this.chatTitle = '',
    this.snippet,
    this.matchedKeyword = false,
    this.matchedSemantic = false,
  });

  final String eventId;
  final String roomId;
  final String chatId;
  final ChatNetwork network;
  final String senderId;
  final DateTime timestamp;
  final MessageKind kind;
  final String body;

  /// Who said it and where, in the words the user already knows them by.
  ///
  /// Both have been stored on the index row since it was written, and neither
  /// was ever read back: a result row therefore showed a message with no
  /// statement of which conversation it came from or who said it, and announced
  /// the same nothing to a screen reader. Blank for a row indexed before the
  /// writer supplied them, which the caller must treat as "unknown" rather than
  /// rendering an empty clause.
  final String senderName;
  final String chatTitle;

  /// Fused score. Comparable within one result set only.
  final double score;

  /// Body with the matched terms marked, when the keyword side contributed.
  final String? snippet;

  /// Which methods found this. Shown in the UI so a semantic-only hit — one
  /// containing none of the typed words — doesn't look like a bug.
  final bool matchedKeyword;
  final bool matchedSemantic;

  @override
  String toString() => 'SearchResult($eventId, ${score.toStringAsFixed(4)})';
}
