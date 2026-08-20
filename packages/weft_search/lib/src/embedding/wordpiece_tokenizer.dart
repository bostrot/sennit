/// BERT-style WordPiece tokenisation, in pure Dart.
///
/// The on-device embedding model (MiniLM) ships as an ONNX graph that takes
/// token ids, not text — someone has to turn "the plumber's invoice" into
/// `[101, 1996, 21877, …]` exactly the way the model was trained, or the
/// vectors are garbage that still *looks* like vectors. That someone is this
/// file, kept free of Flutter and I/O so the encoding rules are directly
/// testable against known-good encodings.
library;

/// Encodes text the way `bert-base-uncased`-family models expect.
///
/// Covers what the vocabulary itself demands: lowercasing, accent stripping,
/// punctuation splitting, CJK isolation, and greedy longest-match WordPiece
/// with `##` continuations. Unknown words become `[UNK]` rather than failing.
class WordPieceTokenizer {
  WordPieceTokenizer({
    required Map<String, int> vocab,
    this.maxTokens = 256,
    String unknownToken = '[UNK]',
    String clsToken = '[CLS]',
    String sepToken = '[SEP]',
    this.maxWordChars = 100,
  }) : _vocab = vocab,
       _unknownId = vocab[unknownToken] ?? 100,
       _clsId = vocab[clsToken] ?? 101,
       _sepId = vocab[sepToken] ?? 102;

  /// Parses the `vocab.txt` that ships beside the model: one token per line,
  /// id = line number.
  factory WordPieceTokenizer.fromVocabText(
    String vocabText, {
    int maxTokens = 256,
  }) {
    final vocab = <String, int>{};
    var id = 0;
    for (final line in vocabText.split('\n')) {
      // Only trailing CR/LF: a vocabulary genuinely contains tokens that are
      // otherwise whitespace-adjacent, and trimming them would alias ids.
      final token = line.replaceAll(RegExp(r'[\r\n]+$'), '');
      if (token.isEmpty) continue;
      vocab[token] = id++;
    }
    return WordPieceTokenizer(vocab: vocab, maxTokens: maxTokens);
  }

  final Map<String, int> _vocab;
  final int _unknownId;
  final int _clsId;
  final int _sepId;

  /// Sequence budget including `[CLS]` and `[SEP]`.
  final int maxTokens;

  /// Words longer than this become `[UNK]` outright, as in the reference
  /// implementation — WordPiece on a 10k-character "word" is quadratic.
  final int maxWordChars;

  /// Token ids for [text], `[CLS] … [SEP]`, truncated to [maxTokens].
  List<int> encode(String text) {
    final ids = <int>[_clsId];
    for (final word in _basicTokenize(text)) {
      ids.addAll(_wordPiece(word));
      if (ids.length >= maxTokens - 1) break;
    }
    if (ids.length > maxTokens - 1) ids.removeRange(maxTokens - 1, ids.length);
    ids.add(_sepId);
    return ids;
  }

  // --------------------------------------------------------- basic tokenizer

  /// Lowercases, strips accents and control characters, splits on whitespace
  /// and punctuation, and isolates CJK ideographs.
  List<String> _basicTokenize(String text) {
    final words = <String>[];
    final current = StringBuffer();

    void flush() {
      if (current.isNotEmpty) {
        words.add(current.toString());
        current.clear();
      }
    }

    for (final rune in text.toLowerCase().runes) {
      if (_isControl(rune)) continue;
      if (_isWhitespace(rune)) {
        flush();
        continue;
      }
      if (_isPunctuation(rune) || _isCjk(rune)) {
        // Punctuation and ideographs are single-character words of their own.
        flush();
        words.add(String.fromCharCode(rune));
        continue;
      }
      final stripped = _stripAccent(rune);
      if (stripped != null) current.write(stripped);
    }
    flush();
    return words;
  }

  // ------------------------------------------------------ wordpiece matching

  List<int> _wordPiece(String word) {
    if (word.length > maxWordChars) return [_unknownId];

    final pieces = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      int? match;
      while (start < end) {
        final piece = (start == 0 ? '' : '##') + word.substring(start, end);
        final id = _vocab[piece];
        if (id != null) {
          match = id;
          break;
        }
        end--;
      }
      if (match == null) return [_unknownId];
      pieces.add(match);
      start = end;
    }
    return pieces;
  }

  // ------------------------------------------------------- character classes

  static bool _isWhitespace(int rune) =>
      rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;

  static bool _isControl(int rune) =>
      rune < 0x20 && !_isWhitespace(rune) || rune == 0x7F || rune == 0xFFFD;

  /// BERT's definition: ASCII symbol ranges count as punctuation even where
  /// Unicode disagrees (`$`, `+`, `<`…), plus the general punctuation blocks.
  static bool _isPunctuation(int rune) {
    if ((rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x60) ||
        (rune >= 0x7B && rune <= 0x7E)) {
      return true;
    }
    return (rune >= 0x2000 && rune <= 0x206F) || // general punctuation
        (rune >= 0x3000 && rune <= 0x303F); // CJK symbols and punctuation
  }

  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x20000 && rune <= 0x2A6DF);

  /// Maps accented Latin to its base letter; drops combining marks.
  ///
  /// A table for the Latin-1/Extended-A range rather than full Unicode NFD,
  /// which Dart's core library does not provide. It covers the European
  /// languages a chat archive plausibly contains; anything beyond passes
  /// through unchanged and simply has to be in the vocabulary as written.
  static String? _stripAccent(int rune) {
    if (rune >= 0x0300 && rune <= 0x036F) return null; // combining marks
    const table = <int, String>{
      0xE0: 'a',
      0xE1: 'a',
      0xE2: 'a',
      0xE3: 'a',
      0xE4: 'a',
      0xE5: 'a',
      0xE7: 'c',
      0xE8: 'e',
      0xE9: 'e',
      0xEA: 'e',
      0xEB: 'e',
      0xEC: 'i',
      0xED: 'i',
      0xEE: 'i',
      0xEF: 'i',
      0xF1: 'n',
      0xF2: 'o',
      0xF3: 'o',
      0xF4: 'o',
      0xF5: 'o',
      0xF6: 'o',
      0xF8: 'o',
      0xF9: 'u',
      0xFA: 'u',
      0xFB: 'u',
      0xFC: 'u',
      0xFD: 'y',
      0xFF: 'y',
      0x101: 'a',
      0x103: 'a',
      0x105: 'a',
      0x107: 'c',
      0x10D: 'c',
      0x113: 'e',
      0x117: 'e',
      0x119: 'e',
      0x11B: 'e',
      0x12B: 'i',
      0x142: 'l',
      0x144: 'n',
      0x148: 'n',
      0x14D: 'o',
      0x151: 'o',
      0x159: 'r',
      0x15B: 's',
      0x161: 's',
      0x16B: 'u',
      0x16F: 'u',
      0x171: 'u',
      0x17A: 'z',
      0x17C: 'z',
      0x17E: 'z',
    };
    return table[rune] ?? String.fromCharCode(rune);
  }
}
