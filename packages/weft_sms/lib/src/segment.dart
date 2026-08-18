import 'package:meta/meta.dart';

/// How a message body will be put on the wire.
///
/// There is no third option: a body either fits GSM 03.38 or it is sent as
/// UTF-16, and the choice is made for the whole message. One curly quote pasted
/// from a word processor drops the capacity of every segment from 160 characters
/// to 70, which is the single most common way a message the user thought was
/// free becomes three billable ones.
enum SmsEncoding {
  gsm7('GSM-7', 160, 153),
  ucs2('UCS-2', 70, 67);

  const SmsEncoding(
    this.label,
    this.singleSegmentUnits,
    this.concatenatedSegmentUnits,
  );

  /// Human-facing name, for the composer's indicator.
  final String label;

  /// Capacity of a message that fits in one segment.
  ///
  /// 160 septets for GSM-7 and 70 UTF-16 code units for UCS-2 — both are the
  /// same 140 octets of payload, counted in the units that encoding uses.
  final int singleSegmentUnits;

  /// Capacity of each segment once the message is concatenated.
  ///
  /// Lower than [singleSegmentUnits] because a concatenated segment spends six
  /// octets of its payload on the UDH that says which part of which message it
  /// is — seven septets under GSM-7, three code units under UCS-2. This is why
  /// a 161-character message costs two segments of 153 rather than 160 + 1.
  final int concatenatedSegmentUnits;
}

/// What sending one body will actually cost.
///
/// Held as a value so the composer can show it before the send and a test can
/// assert on it without a radio.
@immutable
class SegmentPlan {
  const SegmentPlan({
    required this.encoding,
    required this.units,
    required this.segments,
    required this.unitsPerSegment,
    required this.remainingInLastSegment,
  });

  final SmsEncoding encoding;

  /// Encoded length of the body: septets under GSM-7, UTF-16 code units under
  /// UCS-2. **Not** the number of characters the user typed — an escaped GSM
  /// character and an emoji each count two.
  final int units;

  /// Number of messages the carrier will bill for.
  final int segments;

  /// Capacity of each segment in this plan — [SmsEncoding.singleSegmentUnits]
  /// when [segments] is one, [SmsEncoding.concatenatedSegmentUnits] otherwise.
  final int unitsPerSegment;

  /// How many more units fit before another segment starts.
  ///
  /// This, not [units], is what the composer counts down: the number that
  /// matters to someone typing is how close they are to the next charge.
  final int remainingInLastSegment;

  bool get isMultipart => segments > 1;

  /// True when the body was pushed to UTF-16 by its contents.
  ///
  /// Worth surfacing on its own: the user can usually fix it by deleting one
  /// character, and cannot possibly guess which one without being told.
  bool get isUnicode => encoding == SmsEncoding.ucs2;

  @override
  bool operator ==(Object other) =>
      other is SegmentPlan &&
      other.encoding == encoding &&
      other.units == units &&
      other.segments == segments &&
      other.unitsPerSegment == unitsPerSegment &&
      other.remainingInLastSegment == remainingInLastSegment;

  @override
  int get hashCode => Object.hash(
    encoding,
    units,
    segments,
    unitsPerSegment,
    remainingInLastSegment,
  );

  @override
  String toString() =>
      'SegmentPlan(${encoding.label}, $units units, $segments segment'
      '${segments == 1 ? '' : 's'})';
}

/// Counts what [body] costs to send.
///
/// Total — every string produces a plan, including the empty one, which is one
/// segment because that is what an empty message would be billed as if the
/// composer let it go out.
SegmentPlan segmentMessage(String body) {
  final encoding = _encodingFor(body);
  final costs = _unitCosts(body, encoding);

  var units = 0;
  for (final cost in costs) {
    units += cost;
  }

  if (units <= encoding.singleSegmentUnits) {
    return SegmentPlan(
      encoding: encoding,
      units: units,
      segments: 1,
      unitsPerSegment: encoding.singleSegmentUnits,
      remainingInLastSegment: encoding.singleSegmentUnits - units,
    );
  }

  // Greedy fill, with the one rule that makes this more than a division: a
  // two-unit character is never split across a boundary. An escape sequence
  // whose ESC lands in segment one and whose character lands in segment two
  // renders as garbage on the receiving handset, so a real encoder leaves the
  // odd septet unused and starts the pair in the next segment. That padding is
  // why `units` can be lower than `segments * unitsPerSegment` and the count
  // still be right.
  final capacity = encoding.concatenatedSegmentUnits;
  var segments = 1;
  var used = 0;
  for (final cost in costs) {
    if (used + cost > capacity) {
      segments++;
      used = 0;
    }
    used += cost;
  }

  return SegmentPlan(
    encoding: encoding,
    units: units,
    segments: segments,
    unitsPerSegment: capacity,
    remainingInLastSegment: capacity - used,
  );
}

/// GSM-7 if every character is representable in GSM 03.38, else UCS-2.
SmsEncoding _encodingFor(String body) {
  for (final rune in body.runes) {
    if (_gsmBasic.contains(rune) || _gsmExtended.contains(rune)) continue;
    return SmsEncoding.ucs2;
  }
  return SmsEncoding.gsm7;
}

/// Per-character cost in the units of [encoding], in body order.
///
/// Returned as a list rather than a total because segment packing needs to know
/// *where* the two-unit characters are, not just how many there were.
List<int> _unitCosts(String body, SmsEncoding encoding) {
  if (encoding == SmsEncoding.gsm7) {
    return [for (final rune in body.runes) _gsmExtended.contains(rune) ? 2 : 1];
  }
  // UCS-2 counts UTF-16 code units, so anything outside the BMP — every emoji
  // worth sending — is a surrogate pair costing two, and must not be split
  // across a segment boundary either.
  return [for (final rune in body.runes) rune > 0xFFFF ? 2 : 1];
}

/// GSM 03.38 default alphabet, in table order.
///
/// Written positionally so it can be checked against the spec table by eye. Only
/// membership is used; index 27 is ESC, which introduces the extension table and
/// is therefore not a character a body can contain — it is removed below.
const String _gsmBasicTable =
    '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u001BÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
    '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';

final Set<int> _gsmBasic = _gsmBasicTable.runes.toSet()..remove(0x1B);

/// The GSM 03.38 extension table.
///
/// Each of these is sent as ESC followed by the character, so each costs **two**
/// septets rather than one. That is not a rounding error: a message of 100 left
/// braces is 200 septets and two segments, and the euro sign is the one users
/// hit constantly without any idea it is double-width.
const Set<int> _gsmExtended = {
  0x0C, // form feed
  0x5E, // ^
  0x7B, // {
  0x7D, // }
  0x5C, // \
  0x5B, // [
  0x7E, // ~
  0x5D, // ]
  0x7C, // |
  0x20AC, // €
};
