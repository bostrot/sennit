import 'package:meta/meta.dart';
import 'package:weft_merge/weft_merge.dart' show normalizePhone;

/// Fewest digits that can be a short code.
///
/// Three is the floor in practice — emergency and operator codes below that are
/// not SMS-addressable.
const int kShortCodeMinDigits = 3;

/// Most digits that can be a short code.
///
/// Six covers every commercial range in use (US and Canada 5–6, UK 5, most of
/// Europe 4–5). Seven digits is already a subscriber number somewhere.
const int kShortCodeMaxDigits = 6;

/// A phone number, or a short code, in the one form everything downstream
/// compares on.
///
/// The whole reason this is a type rather than a `String?` is equality. The same
/// human is written `+441234567890` by a bridge, `01234 567890` by the SMS
/// provider and `+44 1234 567890` by the contacts app, and an SMS thread only
/// folds into the WhatsApp chat for that person if all three land on one value.
/// [PhoneNumberParser] does the folding; this holds the result so nothing
/// downstream can compare two numbers that were normalised under different
/// rules.
///
/// Construction goes through [PhoneNumberParser.parse] and cannot fail here: an
/// instance of this type is by definition already normalised.
@immutable
final class PhoneNumber {
  const PhoneNumber._(this.value);

  /// E.164 with the leading `+` (`+441234567890`), or the bare digits of a
  /// short code (`20202`).
  ///
  /// The two forms are told apart by that `+`, which is why [isShortCode] is
  /// derived rather than stored — a second field saying the same thing could
  /// disagree with the string it describes.
  final String value;

  /// Whether this is a short code rather than a subscriber number.
  ///
  /// Short codes are not people. Two banks can share one aggregator's code, one
  /// bank can send from several, and the same five digits mean different things
  /// in different countries — so a short code must never become merge evidence.
  /// [linkSmsIdentity] refuses them for exactly that reason.
  bool get isShortCode => !value.startsWith('+');

  @override
  bool operator ==(Object other) =>
      other is PhoneNumber && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Turns whatever the SMS provider, a contacts row or a bridge hands over into a
/// [PhoneNumber], interpreting national-format numbers against one region.
///
/// The region is constructor state rather than a per-call argument on purpose. A
/// device has exactly one home region at a time, and the failure mode of passing
/// it per call is that one call site forgets: `01234 567890` then normalises to
/// nothing in the repository and to `+441234567890` in the merge scorer, and the
/// thread that should have merged simply doesn't, with no error anywhere.
@immutable
class PhoneNumberParser {
  const PhoneNumberParser({this.defaultCountryCode});

  /// Country calling code without the `+` (`'44'`, `'1'`, `'49'`), used to
  /// interpret a number written in national format.
  ///
  /// Null means no region is known — which is not a fallback to a guess. A
  /// national number with no region to anchor it parses to null, because a
  /// wrong country code merges two different people.
  final String? defaultCountryCode;

  /// Parses [raw], or returns null when it cannot be done confidently.
  ///
  /// Null is a normal outcome, not an error: alphanumeric sender ids
  /// (`Vodafone`, `AMAZON`), MMS group rows with an empty address, and national
  /// numbers with no [defaultCountryCode] all land here. Callers show the raw
  /// string and skip the identity work.
  PhoneNumber? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Checked before normalisation, not after. With a [defaultCountryCode] set,
    // `normalizePhone` would happily read the five digits of a short code as a
    // national number and prefix it into a plausible-looking E.164 — turning
    // every bank alert into a "person" who can be merged.
    final short = _shortCode(trimmed);
    if (short != null) return PhoneNumber._(short);

    final e164 = normalizePhone(
      trimmed,
      defaultCountryCode: defaultCountryCode,
    );
    if (e164 == null) return null;
    return PhoneNumber._(e164);
  }

  /// The bare digits of [s] when it is a short code, else null.
  ///
  /// Deliberately strict about formatting: a short code is always written as
  /// bare adjacent digits, so anything carrying a space, a dash or brackets is
  /// treated as a (badly formatted, probably national) real number instead.
  static String? _shortCode(String s) {
    if (s.startsWith('+')) return null;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return null;
    }
    if (s.length < kShortCodeMinDigits || s.length > kShortCodeMaxDigits) {
      return null;
    }
    // A leading zero is a national trunk prefix, and `00` an international one.
    // Neither starts a short code, and both are `normalizePhone`'s business.
    if (s.startsWith('0')) return null;
    return s;
  }
}
