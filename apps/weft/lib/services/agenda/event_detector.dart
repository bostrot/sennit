/// Finds appointments in message text.
///
/// "Zahnarzt am Dienstag um 14:30", "deadline is May 12", "let's meet
/// tomorrow at 7" — the shapes people actually type. Pure Dart and entirely
/// rule-based so it costs nothing per message and works with no model at all;
/// the semantic assist (embedding similarity against prototype sentences,
/// through whatever small local model is installed) lives a layer up in
/// `AgendaService`, where a provider exists to ask.
library;

/// A concrete date (maybe time) a message appears to be about.
class AgendaCandidate {
  const AgendaCandidate({
    required this.start,
    required this.hasTime,
    required this.keywordMatched,
    required this.title,
  });

  /// When the thing happens. Date is always meaningful; the time of day only
  /// when [hasTime].
  final DateTime start;

  final bool hasTime;

  /// Whether an intent word ("Termin", "deadline", "meeting"…) appeared.
  /// Candidates without one are only worth showing when something smarter —
  /// the semantic assist — agrees the message is about an event.
  final bool keywordMatched;

  /// The message with its date and time cut out — see [agendaTitleFor].
  final String title;
}

const _keywords = [
  // EN
  'meeting', 'meet', 'appointment', 'visit', 'deadline', 'due',
  'call', 'dinner', 'lunch', 'breakfast', 'party', 'birthday',
  'flight', 'train', 'pickup', 'pick up', 'interview', 'concert',
  'cinema', 'movie', 'reminder', 'event', 'doctor', 'dentist',
  // DE
  'termin', 'treffen', 'besuch', 'arzt', 'zahnarzt', 'frist', 'abgabe',
  'fällig', 'anruf', 'abendessen', 'mittagessen', 'feier', 'geburtstag',
  'flug', 'zug', 'abholen', 'konzert', 'kino', 'erinnerung',
  'veranstaltung', 'spätestens', 'vorbeikommen', 'vorbei',
];

const _weekdaysEn = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];
const _weekdaysDe = [
  'montag',
  'dienstag',
  'mittwoch',
  'donnerstag',
  'freitag',
  'samstag',
  'sonntag',
];

const _monthsEn = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
const _monthsDe = [
  'januar',
  'februar',
  'märz',
  'april',
  'mai',
  'juni',
  'juli',
  'august',
  'september',
  'oktober',
  'november',
  'dezember',
];

/// Scans [text] for a date/time worth putting in a calendar.
///
/// [now] is injected rather than read so "tomorrow" is testable.
AgendaCandidate? detectAgendaEvent(String text, {required DateTime now}) {
  if (text.trim().length < 4) return null;
  final lower = text.toLowerCase();

  DateTime? date;
  var explicitDate = false;

  // --- relative days -------------------------------------------------------
  if (RegExp(r'\b(day after tomorrow|übermorgen)\b').hasMatch(lower)) {
    date = DateTime(now.year, now.month, now.day + 2);
  } else if (RegExp(r'\b(tomorrow|morgen)\b').hasMatch(lower)) {
    date = DateTime(now.year, now.month, now.day + 1);
  } else if (RegExp(r'\b(today|tonight|heute)\b').hasMatch(lower)) {
    date = DateTime(now.year, now.month, now.day);
  }

  // --- weekday names -------------------------------------------------------
  if (date == null) {
    for (final names in [_weekdaysEn, _weekdaysDe]) {
      for (var day = 0; day < names.length; day++) {
        if (RegExp('\\b${names[day]}\\b').hasMatch(lower)) {
          // Both lists are Monday-first; DateTime.weekday is Monday=1.
          var ahead = (day + 1 - now.weekday) % 7;
          if (ahead == 0) ahead = 7; // "Montag" on a Monday means next week.
          date = DateTime(now.year, now.month, now.day + ahead);
          break;
        }
      }
      if (date != null) break;
    }
  }

  // --- numeric dates: 12.5., 12.05.2026, 5/12 ------------------------------
  if (date == null) {
    // The year is optional and so is a boundary after the second dot —
    // "am 30.06." ends the sentence with that dot, and demanding \b there
    // (between a dot and the end) matches nothing.
    final de = RegExp(
      r'\b(\d{1,2})\.(\d{1,2})\.(?:(\d{2,4})\b)?',
    ).firstMatch(text);
    if (de != null) {
      final day = int.parse(de.group(1)!);
      final month = int.parse(de.group(2)!);
      var year = de.group(3) == null ? now.year : int.parse(de.group(3)!);
      if (year < 100) year += 2000;
      if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        date = DateTime(year, month, day);
        if (de.group(3) == null && date.isBefore(now)) {
          date = DateTime(year + 1, month, day);
        }
        explicitDate = true;
      }
    }
  }

  // --- month names: "May 12", "12 May", "12. Mai" --------------------------
  if (date == null) {
    for (final months in [_monthsEn, _monthsDe]) {
      for (var m = 0; m < months.length; m++) {
        final name = months[m];
        final match = RegExp(
          '\\b(?:(\\d{1,2})\\.?\\s+$name|$name\\s+(\\d{1,2}))\\b',
        ).firstMatch(lower);
        if (match != null) {
          final day = int.parse(match.group(1) ?? match.group(2)!);
          if (day >= 1 && day <= 31) {
            date = DateTime(now.year, m + 1, day);
            if (date.isBefore(DateTime(now.year, now.month, now.day))) {
              date = DateTime(now.year + 1, m + 1, day);
            }
            explicitDate = true;
          }
          break;
        }
      }
      if (date != null) break;
    }
  }

  // --- time of day ---------------------------------------------------------
  int? hour;
  var minute = 0;
  final clock = RegExp(r'\b(\d{1,2}):(\d{2})\b').firstMatch(lower);
  if (clock != null) {
    final h = int.parse(clock.group(1)!);
    final m = int.parse(clock.group(2)!);
    if (h <= 23 && m <= 59) {
      hour = h;
      minute = m;
    }
  }
  if (hour == null) {
    final ampm = RegExp(r'\b(\d{1,2})\s?(am|pm)\b').firstMatch(lower);
    if (ampm != null) {
      var h = int.parse(ampm.group(1)!);
      if (h >= 1 && h <= 12) {
        if (ampm.group(2) == 'pm' && h != 12) h += 12;
        if (ampm.group(2) == 'am' && h == 12) h = 0;
        hour = h;
      }
    }
  }
  if (hour == null) {
    final uhr = RegExp(r'\b(?:um\s+)?(\d{1,2})\s?uhr\b').firstMatch(lower);
    if (uhr != null) {
      final h = int.parse(uhr.group(1)!);
      if (h <= 23) hour = h;
    }
  }

  final keyword = _keywords.any(
    (k) => RegExp('\\b${RegExp.escape(k)}\\b').hasMatch(lower),
  );

  // A bare time with intent still means something — "meeting at 15:00" is
  // today's meeting.
  if (date == null && hour != null && keyword) {
    date = DateTime(now.year, now.month, now.day);
    if (hour < now.hour) date = date.add(const Duration(days: 1));
  }
  if (date == null) return null;

  // A date alone is not an event: "born on 12.05.1990" and "since May" must
  // not grow calendar chips. It takes a time, an intent word, or — decided a
  // layer up — the semantic assist agreeing.
  if (hour == null && !keyword && !explicitDate) return null;

  return AgendaCandidate(
    start: DateTime(date.year, date.month, date.day, hour ?? 9, minute),
    hasTime: hour != null,
    keywordMatched: keyword,
    title: agendaTitleFor(text),
  );
}

// Letter-aware word edges: `\b` is ASCII-only, so it sees no boundary in
// front of "übermorgen" and one in the middle of "März".
const _edgeBefore = r'(?<![\p{L}\p{N}])';
const _edgeAfter = r'(?![\p{L}\p{N}])';

/// The little words that lead into a date or a time and mean nothing once it
/// is gone: "on", "next", "am", "um", "bis zum"…
const _leadIns =
    '(?:(?:on|at|by|until|till|this|next|around|the|am|um|ab|bis|gegen|'
    'diesen|nächsten|kommenden|den|vom|zum)\\s+)*';

final _whenPatterns =
    [
          // 14:30, 14:30 Uhr, 5 pm, 14 Uhr
          '\\d{1,2}:\\d{2}(?:\\s?(?:uhr|am|pm|h))?',
          '\\d{1,2}\\s?(?:am|pm|uhr)',
          // 12.5., 12.05.2026
          '\\d{1,2}\\.\\d{1,2}\\.(?:\\d{2,4})?',
          // 12 May, 12. Mai 2026, May 12th
          for (final months in [_monthsEn, _monthsDe]) ...[
            '\\d{1,2}\\.?\\s+(?:${months.join('|')})(?:,?\\s+\\d{4})?',
            '(?:${months.join('|')})\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+\\d{4})?',
          ],
          // tomorrow, heute Abend, next friday morning
          '(?:day after tomorrow|übermorgen|tomorrow|morgen|today|tonight|heute|'
              '${_weekdaysEn.join('|')}|${_weekdaysDe.join('|')})'
              '(?:\\s+(?:morning|afternoon|evening|night|früh|vormittag|nachmittag|'
              'abend|nacht))?',
        ]
        .map(
          (when) => RegExp(
            '$_edgeBefore$_leadIns(?:$when)$_edgeAfter',
            caseSensitive: false,
            unicode: true,
          ),
        )
        .toList(growable: false);

/// What is left dangling at either end once the date is cut out of a
/// sentence: "Abgabe ist", "and dinner", "the deadline is on".
final _danglingStart = RegExp(
  '^(?:and|und|oder|or|but|aber|also|then|dann|so)\\s+',
  caseSensitive: false,
);
final _danglingEnd = RegExp(
  '\\s+(?:is|are|will be|ist|sind|wird|wäre|on|at|by|am|um|bis|for|für|'
  'and|und|or|oder|the|der|die|das|dann|then)\$',
  caseSensitive: false,
);

/// A calendar title for the message [text]: what it says with the "when"
/// taken out, since the event's own date already carries that.
///
/// "Zahnarzt am Dienstag um 14:30" is "Zahnarzt". Rules only, so it is the
/// title when no model is configured and the fallback when one fails; a
/// message that is nothing *but* a date keeps its own words, because any
/// title beats an empty one.
String agendaTitleFor(String text) {
  final whole = text.trim().replaceAll(RegExp(r'\s+'), ' ');

  var title = whole;
  for (final when in _whenPatterns) {
    title = title.replaceAll(when, ' ');
  }
  title = title
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s+(?=[,.;:!?])'), '');
  final edges = RegExp(r'^[\s,.;:!?–—-]+|[\s,.;:!?–—-]+$');
  while (true) {
    final trimmed = title
        .replaceAll(edges, '')
        .replaceFirst(_danglingStart, '')
        .replaceFirst(_danglingEnd, '');
    if (trimmed == title) break;
    title = trimmed;
  }

  // Too little survived to name anything — "Morgen um 9?" is all date.
  if (RegExp(r'\p{L}', unicode: true).allMatches(title).length < 3) {
    title = whole;
  } else {
    title = title[0].toUpperCase() + title.substring(1);
  }
  if (title.length > 80) title = '${title.substring(0, 77)}…';
  return title;
}
