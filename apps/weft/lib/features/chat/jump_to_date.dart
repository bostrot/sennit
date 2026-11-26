import 'package:flutter/material.dart' show DateUtils;
import 'package:weft_domain/weft_domain.dart';

/// The message a jump to [day] lands on: the oldest of [messages] sent on
/// that day or later, in local time.
///
/// "Or later" because a day nobody wrote on is still a place in the
/// conversation — the reader asked for the 3rd, and the 5th is where the
/// conversation picks up again. Null only when everything is older than
/// [day]. [messages] may be in any order.
WeftMessage? firstMessageOnOrAfter(
  Iterable<WeftMessage> messages,
  DateTime day,
) {
  final start = DateUtils.dateOnly(day);
  WeftMessage? best;
  for (final message in messages) {
    final at = message.timestamp.toLocal();
    if (at.isBefore(start)) continue;
    if (best == null || at.isBefore(best.timestamp.toLocal())) best = message;
  }
  return best;
}

/// Whether [messages] already reach back before [day], so the history that
/// holds it is loaded and backfilling can stop.
bool reachesBefore(Iterable<WeftMessage> messages, DateTime day) {
  final start = DateUtils.dateOnly(day);
  return messages.any((m) => m.timestamp.toLocal().isBefore(start));
}
