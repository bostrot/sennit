import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:weft/features/inbox/inbox_shell.dart';

/// When a conversation last said something.
///
/// The bug this pins was a fixed instant inside the formatter — the one the
/// demo fixtures are dated against, put there so goldens would settle, and
/// then shipped. Every real message is newer than a date in the past, so every
/// difference came out negative, every negative is under a minute, and every
/// conversation in a real inbox was labelled "Now" regardless of age.
void main() {
  setUpAll(() => initializeDateFormatting('en'));

  final now = DateTime(2026, 8, 26, 16, 42);

  test('nothing to show for a conversation with no messages', () {
    expect(formatInboxTime(null, now: now), isNull);
  });

  test('a message from this minute is now', () {
    expect(
      formatInboxTime(now.subtract(const Duration(seconds: 20)), now: now),
      'Now',
    );
  });

  test('a message from earlier today shows the clock', () {
    expect(
      formatInboxTime(now.subtract(const Duration(hours: 2)), now: now),
      isNot('Now'),
      reason: 'the bug: two hours ago read as "Now"',
    );
    expect(formatInboxTime(DateTime(2026, 8, 26, 9, 5), now: now), '09:05');
  });

  test('a message from this week shows the weekday', () {
    expect(formatInboxTime(DateTime(2026, 8, 24, 9, 5), now: now), 'Mon');
  });

  test('anything older shows a date', () {
    expect(
      formatInboxTime(DateTime(2026, 7, 1, 9, 5), now: now),
      contains('2026'),
    );
  });

  test('a message stamped in the future is now, not a date from next week', () {
    // Bridges stamp `origin_server_ts` from the remote network, and a remote
    // clock running fast is common enough to be worth being explicit about.
    expect(
      formatInboxTime(now.add(const Duration(minutes: 5)), now: now),
      'Now',
    );
  });
}
