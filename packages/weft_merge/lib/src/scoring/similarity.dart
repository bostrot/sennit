/// String, phone and image-hash similarity primitives used by the merge scorer.
///
/// All pure functions, all cheap, all directly unit-tested — the merge
/// suggestions a user sees are only as trustworthy as these.
library;

/// Jaro similarity of [a] and [b], in `[0, 1]`.
double jaro(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;

  final matchWindow = (a.length > b.length ? a.length : b.length) ~/ 2 - 1;
  final window = matchWindow < 0 ? 0 : matchWindow;

  final aMatched = List<bool>.filled(a.length, false);
  final bMatched = List<bool>.filled(b.length, false);

  var matches = 0;
  for (var i = 0; i < a.length; i++) {
    final start = i - window < 0 ? 0 : i - window;
    final end = i + window + 1 > b.length ? b.length : i + window + 1;
    for (var j = start; j < end; j++) {
      if (bMatched[j] || a.codeUnitAt(i) != b.codeUnitAt(j)) continue;
      aMatched[i] = true;
      bMatched[j] = true;
      matches++;
      break;
    }
  }
  if (matches == 0) return 0;

  // Half the number of matched characters that appear out of order.
  var transpositions = 0;
  var k = 0;
  for (var i = 0; i < a.length; i++) {
    if (!aMatched[i]) continue;
    while (!bMatched[k]) {
      k++;
    }
    if (a.codeUnitAt(i) != b.codeUnitAt(k)) transpositions++;
    k++;
  }

  final m = matches.toDouble();
  return (m / a.length + m / b.length + (m - transpositions / 2) / m) / 3;
}

/// Jaro-Winkler similarity: [jaro] with a bonus for a shared prefix, which
/// suits personal names — "Jon Smith" and "Jonathan Smith" should score high.
double jaroWinkler(String a, String b, {double scalingFactor = 0.1}) {
  final j = jaro(a, b);
  if (j <= 0) return 0;

  var prefix = 0;
  final maxPrefix = a.length < b.length
      ? (a.length < 4 ? a.length : 4)
      : (b.length < 4 ? b.length : 4);
  for (var i = 0; i < maxPrefix; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) break;
    prefix++;
  }
  return j + prefix * scalingFactor * (1 - j);
}

/// Folds a display name to a comparable form: lowercase, accent-stripped,
/// punctuation-free, single-spaced.
///
/// Bridges hand back wildly inconsistent names — "Anna Maven", "anna maven",
/// "Anna  Maven 💼", "Änna Maven" — and all should compare as equal.
String normalizeName(String raw) {
  final folded = StringBuffer();
  for (final rune in raw.toLowerCase().runes) {
    final replacement = _accentFolding[rune];
    if (replacement != null) {
      folded.write(replacement);
    } else if (_isLetterOrDigit(rune)) {
      folded.writeCharCode(rune);
    } else {
      folded.write(' ');
    }
  }
  return folded.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _isLetterOrDigit(int rune) =>
    (rune >= 0x61 && rune <= 0x7A) || // a-z
    (rune >= 0x30 && rune <= 0x39); // 0-9

const Map<int, String> _accentFolding = {
  0xE0: 'a',
  0xE1: 'a',
  0xE2: 'a',
  0xE3: 'a',
  0xE4: 'ae',
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
  0xF6: 'oe',
  0xF8: 'o',
  0xF9: 'u',
  0xFA: 'u',
  0xFB: 'u',
  0xFC: 'ue',
  0xFD: 'y',
  0xFF: 'y',
  0xDF: 'ss',
};

/// Normalises a phone number to E.164 (`+4915112345678`), or returns null when
/// that cannot be done confidently.
///
/// This is deliberately conservative rather than a libphonenumber
/// reimplementation: a wrong normalisation merges two different people, which
/// is far worse than failing to merge. When no country code is present and no
/// [defaultCountryCode] is supplied, it gives up.
String? normalizePhone(String? raw, {String? defaultCountryCode}) {
  if (raw == null) return null;

  var s = raw.trim();
  if (s.isEmpty) return null;

  // Bridges often hand back the number as the localpart of a ghost user id.
  if (s.startsWith('@')) {
    s = s.substring(1).split(':').first;
    final lastUnderscore = s.lastIndexOf('_');
    if (lastUnderscore >= 0) s = s.substring(lastUnderscore + 1);
  }

  final hadPlus = s.startsWith('+');
  var digits = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;

  if (!hadPlus && digits.startsWith('00')) {
    digits = digits.substring(2);
  } else if (!hadPlus) {
    if (digits.startsWith('0') && defaultCountryCode != null) {
      // National trunk prefix: 0151… in DE becomes +49151…
      digits = defaultCountryCode + digits.substring(1);
    } else if (defaultCountryCode != null && digits.length <= 11) {
      digits = defaultCountryCode + digits;
    } else if (digits.length < 11) {
      // Too short to be international and no region to anchor it.
      return null;
    }
  }

  // No country calling code begins with 0 — E.164 reserves it as the trunk and
  // international escape prefix. A leading zero here therefore means a national
  // number that reached the end with no region to anchor it (`01234 567890`
  // with no [defaultCountryCode]), and `+01234567890` is not a number at all.
  // Worse, it *compares*: the same national digits dialled in two countries
  // would fold to one string and merge two strangers.
  if (digits.startsWith('0')) return null;

  // E.164 allows at most 15 digits, and fewer than 7 is not a real number.
  if (digits.length < 7 || digits.length > 15) return null;
  return '+$digits';
}

/// Lowercases and trims an email, returning null when it isn't one.
String? normalizeEmail(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s)) return null;
  return s;
}

/// Hamming distance between two 64-bit perceptual hashes — the number of
/// differing bits. `0` is identical; `<= 6` is the usual "same image,
/// re-encoded" threshold.
int hammingDistance64(int a, int b) {
  var x = a ^ b;
  var count = 0;
  // Dart ints are 64-bit two's complement on native targets; masking each
  // nibble keeps this correct for negative values too.
  for (var i = 0; i < 64; i++) {
    count += x & 1;
    x = x >>> 1;
  }
  return count;
}
