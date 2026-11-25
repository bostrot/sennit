import 'network.dart';

/// The longest text message [network] accepts, in UTF-16 code units, or null
/// when it takes anything a homeserver will.
///
/// What the bridge would otherwise do with a longer one varies — refuse it,
/// cut it off, or drop it with an error notice the user may never see — and
/// none of those is what was typed. Counted in UTF-16 code units because that
/// is what the strictest of them counts, and a character is never more than
/// two of them, so a body that fits here fits everywhere it is counted in
/// characters too.
int? textLimitFor(ChatNetwork network) => switch (network) {
  ChatNetwork.telegram => 4096,
  ChatNetwork.discord => 2000,
  ChatNetwork.instagram => 1000,
  ChatNetwork.bluesky => 1000,
  ChatNetwork.twitter => 10000,
  ChatNetwork.googlechat => 4096,
  ChatNetwork.mattermost => 16383,
  ChatNetwork.messenger => 20000,
  ChatNetwork.linkedin => 8000,
  ChatNetwork.slack => 40000,
  // SMS splits into segments on its own path; Matrix, WhatsApp, Signal and
  // the rest take more than anyone types.
  _ => null,
};

/// [body] cut into pieces of at most [limit] UTF-16 code units, in order.
///
/// Each cut is made at the most natural place the piece allows — a blank line,
/// then a line break, then the end of a sentence, then a space — as long as
/// that keeps at least half the piece, so a paragraph break near the start
/// does not leave a sliver of a message. Only a run with no space in it at all
/// is cut mid-word, and never through a surrogate pair. Whitespace at a cut
/// is dropped from both sides; nothing else is changed or lost.
List<String> splitForLimit(String body, int limit) {
  if (limit < 2) throw ArgumentError.value(limit, 'limit', 'Too small');
  if (body.length <= limit) return [body];
  final pieces = <String>[];
  var rest = body;
  while (rest.length > limit) {
    final cut = _cutPoint(rest, limit);
    final piece = rest.substring(0, cut).trimRight();
    if (piece.isNotEmpty) pieces.add(piece);
    rest = rest.substring(cut).trimLeft();
  }
  if (rest.isNotEmpty) pieces.add(rest);
  return pieces;
}

// Chinese and Japanese full stops need no space after them to end a sentence.
final RegExp _sentenceEnd = RegExp(r'[.!?…](?=\s)|[。！？]');

int _cutPoint(String text, int limit) {
  final window = text.substring(
    0,
    limit + 1 > text.length ? text.length : limit + 1,
  );
  final floor = limit ~/ 2;

  final paragraph = window.lastIndexOf('\n\n');
  if (paragraph >= floor) return paragraph;
  final line = window.lastIndexOf('\n');
  if (line >= floor) return line;
  final sentences = _sentenceEnd
      .allMatches(window)
      .where((m) => m.end <= limit);
  final sentence = sentences.isEmpty ? -1 : sentences.last.end;
  if (sentence >= floor) return sentence;
  final space = window.lastIndexOf(RegExp(r'\s'));
  if (space >= floor) return space;

  // A high surrogate at the edge would leave half a character on each side.
  final unit = text.codeUnitAt(limit - 1);
  return unit >= 0xD800 && unit <= 0xDBFF ? limit - 1 : limit;
}
