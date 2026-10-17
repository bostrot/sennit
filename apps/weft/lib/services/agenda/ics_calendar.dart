import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'event_detector.dart';

/// One stretch of time the user's calendar says is taken, in local time.
///
/// Times only, and on purpose: no title, no location, no attendees. Everything
/// this app does with the calendar — answer "are you free on Friday?", warn
/// that an invitation lands on top of something — needs to know *that* the
/// user is busy, never *with what*, and a block that does not carry the
/// dentist's name cannot leak it into a prompt.
@immutable
class BusyBlock {
  const BusyBlock({
    required this.start,
    required this.end,
    this.allDay = false,
  });

  final DateTime start;

  /// Exclusive: a block ending at 10:00 leaves 10:00 free.
  final DateTime end;

  final bool allDay;

  bool overlaps(DateTime from, DateTime to) =>
      start.isBefore(to) && end.isAfter(from);

  @override
  bool operator ==(Object other) =>
      other is BusyBlock &&
      other.start == start &&
      other.end == end &&
      other.allDay == allDay;

  @override
  int get hashCode => Object.hash(start, end, allDay);

  @override
  String toString() => 'BusyBlock($start – $end${allDay ? ', all day' : ''})';
}

/// The subscription URL as something fetchable, or null.
///
/// `webcal://` is how calendar apps hand these out — it is plain HTTP(S) with
/// a scheme that makes the browser open a calendar app instead of a download,
/// and every server behind one answers on `https://`.
Uri? icsUriFrom(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  return switch (uri.scheme.toLowerCase()) {
    'webcal' || 'webcals' => uri.replace(scheme: 'https'),
    'http' || 'https' => uri,
    _ => null,
  };
}

/// A shared calendar, fetched from its ICS address and held for a while.
///
/// Read-only, and only ever the one URL the user typed: Braid never writes to
/// this calendar and never asks anything else about it. Fetched on demand
/// rather than polled, because the questions arrive rarely — an auto-reply
/// about meeting up, an invitation being composed — and a calendar refreshed
/// every few minutes for nobody is traffic on someone's phone plan.
class IcsCalendar {
  IcsCalendar({
    required this.url,
    http.Client? client,
    this.maxAge = const Duration(minutes: 15),
    this.timeout = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now;

  final Uri url;

  /// How long a fetched calendar is answered from memory.
  final Duration maxAge;

  final Duration timeout;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  IcsEventSet? _events;
  DateTime? _fetchedAt;
  Future<IcsEventSet>? _loading;

  /// The parsed calendar, fetched when the copy in memory is missing or old.
  ///
  /// A failed refresh answers from the last good copy when there is one: a
  /// server that hiccups should not make the user look free all afternoon.
  /// Without one, the failure is thrown — see [IcsFetchException].
  Future<IcsEventSet> load({bool force = false}) {
    final fetchedAt = _fetchedAt;
    if (!force &&
        _events != null &&
        fetchedAt != null &&
        _now().difference(fetchedAt) < maxAge) {
      return Future.value(_events);
    }
    // Two callers asking at once share one request.
    return _loading ??= _fetch().whenComplete(() => _loading = null);
  }

  Future<IcsEventSet> _fetch() async {
    try {
      final response = await _client.get(url).timeout(timeout);
      if (response.statusCode != 200) {
        throw IcsFetchException('The server answered ${response.statusCode}');
      }
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (!text.contains('BEGIN:VCALENDAR')) {
        throw const IcsFetchException('That address is not a calendar');
      }
      final events = parseIcs(text);
      _events = events;
      _fetchedAt = _now();
      return events;
    } on Object catch (error) {
      final stale = _events;
      if (stale != null) {
        debugPrint(
          'weft: calendar refresh failed, using the last copy: $error',
        );
        return stale;
      }
      if (error is IcsFetchException) rethrow;
      throw IcsFetchException('Could not reach the calendar: $error');
    }
  }

  /// Busy blocks overlapping [from]…[to], merged where they touch.
  Future<List<BusyBlock>> busyBetween(DateTime from, DateTime to) async =>
      mergeBusy((await load()).busyBetween(from, to));

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// Why a calendar could not be read. The message is for a status line.
class IcsFetchException implements Exception {
  const IcsFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [blocks] sorted, with overlapping and touching blocks joined into one.
///
/// What a person — or a model — wants to know is "busy 9 to 12", not that it
/// was three meetings back to back.
List<BusyBlock> mergeBusy(Iterable<BusyBlock> blocks) {
  final sorted = [...blocks]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <BusyBlock>[];
  for (final block in sorted) {
    final last = merged.lastOrNull;
    if (last != null && !block.start.isAfter(last.end)) {
      merged[merged.length - 1] = BusyBlock(
        start: last.start,
        end: block.end.isAfter(last.end) ? block.end : last.end,
        allDay: last.allDay && block.allDay,
      );
    } else {
      merged.add(block);
    }
  }
  return merged;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// The events of one calendar, ready to be asked about any window.
///
/// Kept unexpanded: a weekly meeting is one entry here and as many blocks as a
/// window asks for, so a calendar with a daily stand-up since 2019 costs the
/// same to hold as one without.
class IcsEventSet {
  IcsEventSet._(this._events, this._overridden);

  final List<_IcsEvent> _events;

  /// Recurrence instances replaced by an event of their own, by UID, as local
  /// epoch milliseconds of the instance they replace.
  final Map<String, Set<int>> _overridden;

  /// How many events the calendar holds — recurring ones counted once. For
  /// the settings screen's "found N events".
  int get length => _events.length;

  /// Every block overlapping [from]…[to], unmerged and unsorted.
  List<BusyBlock> busyBetween(DateTime from, DateTime to) {
    final out = <BusyBlock>[];
    for (final event in _events) {
      event.occurrences(
        from: from,
        to: to,
        skip: event.recurrenceId == null
            ? _overridden[event.uid] ?? const {}
            : const {},
        into: out,
      );
    }
    return out;
  }
}

/// Parses an iCalendar document into the events that block time.
///
/// Forgiving rather than strict, because calendars in the wild are: an event
/// this cannot understand is dropped and the rest are kept. Cancelled events
/// and ones marked "free" (`TRANSP:TRANSPARENT`) block nothing and are left
/// out here.
IcsEventSet parseIcs(String text) {
  final lines = text
      // RFC 5545 §3.1: a line break followed by one space or tab is a fold.
      .replaceAll(RegExp(r'\r?\n[ \t]'), '')
      .split(RegExp(r'\r?\n'));

  final events = <_IcsEvent>[];
  final overridden = <String, Set<int>>{};
  Map<String, List<_IcsProperty>>? current;
  var nested = 0;

  for (final line in lines) {
    if (line.isEmpty) continue;
    final property = _IcsProperty.parse(line);
    if (property == null) continue;

    if (property.name == 'BEGIN') {
      if (property.value.toUpperCase() == 'VEVENT' && current == null) {
        current = {};
      } else if (current != null) {
        // VALARM and friends: their DTSTART-looking lines are not the event's.
        nested++;
      }
      continue;
    }
    if (property.name == 'END') {
      if (current == null) continue;
      if (nested > 0) {
        nested--;
        continue;
      }
      if (property.value.toUpperCase() == 'VEVENT') {
        // Recorded before the event is judged: an override that cancels one
        // instance blocks nothing itself, and must still take that instance
        // out of the series.
        final recurrence = current['RECURRENCE-ID']?.first;
        final recurrenceId = recurrence == null
            ? null
            : _IcsTime.parse(recurrence.value, tzid: recurrence.params['TZID']);
        if (recurrenceId != null) {
          (overridden[current['UID']?.first.value ?? ''] ??= {}).add(
            recurrenceId.toLocal().millisecondsSinceEpoch,
          );
        }
        final event = _IcsEvent.from(current);
        if (event != null) events.add(event);
        current = null;
      }
      continue;
    }
    if (current != null && nested == 0) {
      (current[property.name] ??= []).add(property);
    }
  }
  return IcsEventSet._(events, overridden);
}

class _IcsProperty {
  _IcsProperty(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;

  /// `NAME;PARAM=a;OTHER="b:c":value` — the first colon outside quotes ends
  /// the name and its parameters.
  static _IcsProperty? parse(String line) {
    var inQuotes = false;
    var colon = -1;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') inQuotes = !inQuotes;
      if (char == ':' && !inQuotes) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;
    final head = line.substring(0, colon).split(';');
    final params = <String, String>{};
    for (final param in head.skip(1)) {
      final eq = param.indexOf('=');
      if (eq <= 0) continue;
      params[param.substring(0, eq).toUpperCase()] = param
          .substring(eq + 1)
          .replaceAll('"', '');
    }
    return _IcsProperty(
      head.first.toUpperCase(),
      params,
      line.substring(colon + 1).trim(),
    );
  }
}

/// A DATE or DATE-TIME as written, before it is placed on the timeline.
///
/// Held as wall-clock fields plus how to read them, because recurrence is
/// wall-clock arithmetic: a 09:00 meeting in Berlin stays at 09:00 across the
/// change to summer time, which adding seven days of hours would not do.
@immutable
class _IcsTime {
  const _IcsTime(
    this.wall, {
    this.dateOnly = false,
    this.utc = false,
    this.zone,
  });

  /// The written fields, in a UTC `DateTime` only so arithmetic on it has no
  /// daylight saving in it. It is not a UTC instant unless [utc] says so.
  final DateTime wall;
  final bool dateOnly;
  final bool utc;

  /// The resolved `TZID`, or null for UTC and for floating time.
  final tz.Location? zone;

  static final _pattern = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
  );

  static _IcsTime? parse(String value, {String? tzid}) {
    final match = _pattern.firstMatch(value.trim().toUpperCase());
    if (match == null) return null;
    final wall = DateTime.utc(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      int.parse(match[4] ?? '0'),
      int.parse(match[5] ?? '0'),
      int.parse(match[6] ?? '0'),
    );
    if (match[4] == null) return _IcsTime(wall, dateOnly: true);
    if (match[7] != null) return _IcsTime(wall, utc: true);
    return _IcsTime(wall, zone: _zone(tzid));
  }

  _IcsTime withWall(DateTime wall) =>
      _IcsTime(wall, dateOnly: dateOnly, utc: utc, zone: zone);

  /// The instant, as a local `DateTime`.
  ///
  /// A TZID the database does not know — Outlook writes Windows zone names
  /// like "W. Europe Standard Time" — is read as floating local time, which is
  /// right for the common case of a calendar kept in the zone its owner lives
  /// in, and off by the difference otherwise.
  DateTime toLocal() {
    if (dateOnly) return DateTime(wall.year, wall.month, wall.day);
    if (utc) return wall.toLocal();
    final zone = this.zone;
    if (zone != null) {
      final instant = tz.TZDateTime(
        zone,
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
        wall.second,
      );
      return DateTime.fromMillisecondsSinceEpoch(
        instant.millisecondsSinceEpoch,
      );
    }
    return DateTime(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    );
  }

  static var _zonesReady = false;

  static tz.Location? _zone(String? tzid) {
    if (tzid == null || tzid.isEmpty) return null;
    if (!_zonesReady) {
      tzdata.initializeTimeZones();
      _zonesReady = true;
    }
    try {
      return tz.getLocation(tzid);
    } on Object {
      return null;
    }
  }
}

/// How far a recurrence is followed past the window's start before giving up,
/// in periods. Ten years of a daily event, which is far past any window anyone
/// asks about; the cap is for the rule that would otherwise never end.
const int _maxPeriods = 4000;

class _IcsEvent {
  _IcsEvent({
    required this.uid,
    required this.start,
    required this.length,
    this.rule,
    this.exdates = const {},
    this.recurrenceId,
  });

  final String uid;
  final _IcsTime start;

  /// Wall-clock length, so an all-day event stays one calendar day long on the
  /// day the clocks change.
  final Duration length;
  final _RecurrenceRule? rule;

  /// Excluded instances, as local epoch milliseconds.
  final Set<int> exdates;

  /// Set on an event that replaces one instance of a recurring one.
  final _IcsTime? recurrenceId;

  static _IcsEvent? from(Map<String, List<_IcsProperty>> props) {
    _IcsProperty? one(String name) => props[name]?.first;

    if (one('STATUS')?.value.toUpperCase() == 'CANCELLED') return null;
    if (one('TRANSP')?.value.toUpperCase() == 'TRANSPARENT') return null;

    final dtstart = one('DTSTART');
    if (dtstart == null) return null;
    final start = _IcsTime.parse(dtstart.value, tzid: dtstart.params['TZID']);
    if (start == null) return null;

    final dtend = one('DTEND');
    final end = dtend == null
        ? null
        : _IcsTime.parse(dtend.value, tzid: dtend.params['TZID']);
    final Duration length;
    if (end != null) {
      // Different zones on the two ends is legal and rare; the instants are
      // then the only thing that agrees.
      length = identical(end.zone, start.zone) && end.utc == start.utc
          ? end.wall.difference(start.wall)
          : end.toLocal().difference(start.toLocal());
    } else if (one('DURATION') case final duration?) {
      length = _parseDuration(duration.value) ?? Duration.zero;
    } else {
      // RFC 5545: a DATE start with no end is one day; a DATE-TIME start with
      // no end is a moment.
      length = start.dateOnly ? const Duration(days: 1) : Duration.zero;
    }
    // A moment blocks nothing — a reminder, not an appointment.
    if (length <= Duration.zero) return null;

    final exdates = <int>{};
    for (final exdate in props['EXDATE'] ?? const <_IcsProperty>[]) {
      for (final value in exdate.value.split(',')) {
        final time = _IcsTime.parse(value, tzid: exdate.params['TZID']);
        if (time != null) exdates.add(time.toLocal().millisecondsSinceEpoch);
      }
    }

    final recurrence = one('RECURRENCE-ID');
    return _IcsEvent(
      uid: one('UID')?.value ?? '',
      start: start,
      length: length,
      rule: recurrence == null
          ? _RecurrenceRule.parse(one('RRULE')?.value)
          : null,
      exdates: exdates,
      recurrenceId: recurrence == null
          ? null
          : _IcsTime.parse(recurrence.value, tzid: recurrence.params['TZID']),
    );
  }

  void occurrences({
    required DateTime from,
    required DateTime to,
    required Set<int> skip,
    required List<BusyBlock> into,
  }) {
    void emit(DateTime wall) {
      final at = start.withWall(wall);
      final local = at.toLocal();
      final key = local.millisecondsSinceEpoch;
      if (exdates.contains(key) || skip.contains(key)) return;
      final block = BusyBlock(
        start: local,
        end: start.withWall(wall.add(length)).toLocal(),
        allDay: start.dateOnly,
      );
      if (block.overlaps(from, to)) into.add(block);
    }

    final rule = this.rule;
    if (rule == null) {
      emit(start.wall);
      return;
    }
    // The window's start as a wall-clock date, pulled back by the event's own
    // length and a day either side for zone offsets: an instance starting
    // before that cannot reach into the window.
    final reach = from.subtract(length + const Duration(days: 2));
    rule.expand(
      start.wall,
      notBefore: DateTime.utc(reach.year, reach.month, reach.day),
      // Anything starting after the window cannot reach into it.
      isPast: (wall) => start.withWall(wall).toLocal().isAfter(to),
      isAfterUntil: (wall) {
        final until = rule.until;
        if (until == null) return false;
        final at = start.withWall(wall).toLocal();
        // A DATE until includes its whole day.
        if (until.dateOnly) {
          final limit = until.toLocal();
          return !at.isBefore(DateTime(limit.year, limit.month, limit.day + 1));
        }
        return at.isAfter(until.toLocal());
      },
      emit: emit,
    );
  }
}

Duration? _parseDuration(String value) {
  final match = RegExp(
    r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(value.trim().toUpperCase());
  if (match == null) return null;
  int n(int group) => int.parse(match[group] ?? '0');
  final duration = Duration(
    days: n(2) * 7 + n(3),
    hours: n(4),
    minutes: n(5),
    seconds: n(6),
  );
  return match[1] == '-' ? -duration : duration;
}

enum _Frequency { daily, weekly, monthly, yearly }

/// The part of RRULE that real calendars use: a frequency with an interval,
/// ended by COUNT or UNTIL, narrowed by BYDAY or BYMONTHDAY. Anything rarer —
/// BYSETPOS, BYWEEKNO, hourly rules — is read as the plain frequency, which
/// over-reports busy time rather than hiding it.
class _RecurrenceRule {
  _RecurrenceRule({
    required this.frequency,
    this.interval = 1,
    this.count,
    this.until,
    this.byDay = const [],
    this.byMonthDay = const [],
  });

  final _Frequency frequency;
  final int interval;
  final int? count;
  final _IcsTime? until;

  /// (ordinal, weekday) — ordinal 0 means every such weekday; `2TU` is the
  /// second Tuesday, `-1FR` the last Friday.
  final List<(int, int)> byDay;
  final List<int> byMonthDay;

  static const _weekdays = {
    'MO': DateTime.monday,
    'TU': DateTime.tuesday,
    'WE': DateTime.wednesday,
    'TH': DateTime.thursday,
    'FR': DateTime.friday,
    'SA': DateTime.saturday,
    'SU': DateTime.sunday,
  };

  static _RecurrenceRule? parse(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = <String, String>{};
    for (final part in value.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        parts[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1);
      }
    }
    final frequency = switch (parts['FREQ']?.toUpperCase()) {
      'DAILY' => _Frequency.daily,
      'WEEKLY' => _Frequency.weekly,
      'MONTHLY' => _Frequency.monthly,
      'YEARLY' => _Frequency.yearly,
      _ => null,
    };
    if (frequency == null) return null;

    final byDay = <(int, int)>[];
    for (final day in (parts['BYDAY'] ?? '').split(',')) {
      final match = RegExp(
        r'^([+-]?\d{1,2})?([A-Z]{2})$',
      ).firstMatch(day.trim().toUpperCase());
      final weekday = match == null ? null : _weekdays[match[2]];
      if (weekday != null) {
        byDay.add((int.parse(match![1] ?? '0'), weekday));
      }
    }
    return _RecurrenceRule(
      frequency: frequency,
      interval: int.tryParse(parts['INTERVAL'] ?? '')?.clamp(1, 1000) ?? 1,
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: parts['UNTIL'] == null ? null : _IcsTime.parse(parts['UNTIL']!),
      byDay: byDay,
      byMonthDay: [
        for (final day in (parts['BYMONTHDAY'] ?? '').split(','))
          ?int.tryParse(day.trim()),
      ],
    );
  }

  /// Calls [emit] with every instance's wall-clock start, in order, until the
  /// rule ends or [isPast] says the rest are beyond the window.
  ///
  /// [notBefore] lets an open-ended rule start near the window instead of at
  /// [first]: a daily stand-up since 2014 is then a few steps, not four
  /// thousand, and is never cut off before it reaches today. A COUNT rule is
  /// still walked from the start, since its end depends on every instance
  /// before it.
  void expand(
    DateTime first, {
    required DateTime notBefore,
    required bool Function(DateTime wall) isPast,
    required bool Function(DateTime wall) isAfterUntil,
    required void Function(DateTime wall) emit,
  }) {
    final skip = count == null ? _periodsBefore(first, notBefore) : 0;
    var produced = 0;
    for (var period = skip; period < skip + _maxPeriods; period++) {
      final candidates = _candidates(first, period * interval);
      for (final wall in candidates) {
        if (wall.isBefore(first)) continue;
        if (isAfterUntil(wall) || isPast(wall)) return;
        if (count != null && produced >= count!) return;
        produced++;
        emit(wall);
      }
    }
  }

  /// How many whole periods lie between [first] and [notBefore], less one for
  /// safety — the first period that can hold an instance at or after
  /// [notBefore].
  int _periodsBefore(DateTime first, DateTime notBefore) {
    if (!notBefore.isAfter(first)) return 0;
    final units = switch (frequency) {
      _Frequency.daily => notBefore.difference(first).inDays,
      _Frequency.weekly => notBefore.difference(first).inDays ~/ 7,
      _Frequency.monthly =>
        (notBefore.year - first.year) * 12 + notBefore.month - first.month,
      _Frequency.yearly => notBefore.year - first.year,
    };
    final periods = units ~/ interval - 1;
    return periods < 0 ? 0 : periods;
  }

  /// The instances in the period [steps] frequency-units after [first].
  List<DateTime> _candidates(DateTime first, int steps) {
    DateTime at(int year, int month, int day) =>
        DateTime.utc(year, month, day, first.hour, first.minute, first.second);

    switch (frequency) {
      case _Frequency.daily:
        final day = at(first.year, first.month, first.day + steps);
        if (byDay.isNotEmpty && !byDay.any((d) => d.$2 == day.weekday)) {
          return const [];
        }
        return [day];
      case _Frequency.weekly:
        if (byDay.isEmpty) {
          return [at(first.year, first.month, first.day + steps * 7)];
        }
        // Weeks start on Monday (WKST's default).
        final monday = first.day - (first.weekday - DateTime.monday);
        return [
          for (final weekday
              in (byDay.map((d) => d.$2).toSet().toList()..sort()))
            at(first.year, first.month, monday + steps * 7 + weekday - 1),
        ];
      case _Frequency.monthly:
        final month = DateTime.utc(first.year, first.month + steps);
        return _inMonth(month.year, month.month, at, defaultDay: first.day);
      case _Frequency.yearly:
        final year = first.year + steps;
        if (byDay.isEmpty && byMonthDay.isEmpty) {
          final day = at(year, first.month, first.day);
          // The 29th of February happens in leap years only.
          return day.month == first.month ? [day] : const [];
        }
        return _inMonth(year, first.month, at, defaultDay: first.day);
    }
  }

  List<DateTime> _inMonth(
    int year,
    int month,
    DateTime Function(int, int, int) at, {
    required int defaultDay,
  }) {
    final length = DateTime.utc(year, month + 1, 0).day;
    final days = <int>{};
    for (final day in byMonthDay) {
      final resolved = day < 0 ? length + day + 1 : day;
      if (resolved >= 1 && resolved <= length) days.add(resolved);
    }
    for (final (ordinal, weekday) in byDay) {
      final matching = [
        for (var day = 1; day <= length; day++)
          if (DateTime.utc(year, month, day).weekday == weekday) day,
      ];
      if (ordinal == 0) {
        days.addAll(matching);
      } else {
        final index = ordinal > 0 ? ordinal - 1 : matching.length + ordinal;
        if (index >= 0 && index < matching.length) days.add(matching[index]);
      }
    }
    if (byMonthDay.isEmpty && byDay.isEmpty) {
      // The 31st of a 30-day month is skipped, not moved.
      if (defaultDay <= length) days.add(defaultDay);
    }
    return [for (final day in days.toList()..sort()) at(year, month, day)];
  }
}

// ---------------------------------------------------------------------------
// What the AI features are told
// ---------------------------------------------------------------------------

/// How far ahead the AI features are told about.
///
/// Two weeks covers "are you free on Friday?" and "next weekend?", which is
/// nearly every question a chat asks; past that the busy list grows longer than
/// the conversation it is attached to.
const int kCalendarAiHorizonDays = 14;

/// [now] plus [kCalendarAiHorizonDays] calendar days at the same wall-clock
/// time — not fourteen times twenty-four hours, which lands an hour off
/// whenever the clocks change in between.
DateTime calendarAiHorizon(DateTime now) => DateTime(
  now.year,
  now.month,
  now.day + kCalendarAiHorizonDays,
  now.hour,
  now.minute,
);

/// The most blocks a prompt carries. A calendar busier than this has its
/// horizon cut short rather than its list, so "everything else is free" stays
/// true of the window it is said about.
const int kCalendarAiMaxBlocks = 40;

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _two(int n) => n.toString().padLeft(2, '0');

String _day(DateTime t) =>
    '${_weekdayNames[t.weekday - 1]} ${t.year}-${_two(t.month)}-${_two(t.day)}';

String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "09:00–10:30", "all day", or "22:00 – Thu 2026-10-22 01:00" — the span of
/// [block] as it reads under the heading of its first day.
String describeBusySpan(BusyBlock block) {
  if (block.allDay) {
    final lastDay = block.end.subtract(const Duration(minutes: 1));
    return _sameDay(block.start, lastDay)
        ? 'all day'
        : 'all day until ${_day(lastDay)}';
  }
  if (_sameDay(block.start, block.end) ||
      block.end ==
          DateTime(block.start.year, block.start.month, block.start.day + 1)) {
    return '${_clock(block.start)}–${_clock(block.end)}';
  }
  return '${_clock(block.start)} – ${_day(block.end)} ${_clock(block.end)}';
}

/// The calendar as a prompt section: the current time, then the busy blocks
/// between [now] and [calendarAiHorizon], one per line.
///
/// English and ISO dates whatever the conversation's language, the way the
/// rest of every prompt in `services/ai` is English: it is read by a model,
/// not a person, and an unambiguous date is worth more to it than a familiar
/// one.
String calendarPromptSection(List<BusyBlock> busy, {required DateTime now}) {
  var until = calendarAiHorizon(now);
  var blocks = mergeBusy(busy.where((b) => b.overlaps(now, until)));
  if (blocks.length > kCalendarAiMaxBlocks) {
    until = blocks[kCalendarAiMaxBlocks].start;
    blocks = blocks.take(kCalendarAiMaxBlocks).toList();
  }
  final buffer = StringBuffer()
    ..writeln('It is now ${_day(now)} ${_clock(now)}.')
    ..write(
      blocks.isEmpty
          ? 'The calendar has nothing until ${_day(until)} ${_clock(until)}: '
                'the user is free all of that time.'
          : 'The user is busy at these times, and free at every other time '
                'until ${_day(until)} ${_clock(until)}:',
    );
  for (final block in blocks) {
    buffer.write('\n- ${_day(block.start)} ${describeBusySpan(block)}');
  }
  return buffer.toString();
}

/// Whether the end of a conversation is about when someone is free.
///
/// The gate in front of the calendar for every AI feature: the calendar is
/// attached to a prompt only when the conversation could need it, so a "lol"
/// does not send the user's week along with it. Looks at the newest few lines
/// only — a plan made an hour ago and settled is not what the next reply is
/// about.
///
/// Errs towards yes. A false positive sends busy times to the user's own
/// model; a false negative is an assistant answering "are you free?" without
/// knowing.
bool mentionsScheduling(List<String> transcript, {required DateTime now}) {
  for (final line in transcript.reversed.take(3)) {
    // The speaker prefix is not part of what was said.
    final colon = line.indexOf(': ');
    final said = colon >= 0 ? line.substring(colon + 2) : line;
    if (_schedulingWords.hasMatch(said) || _schedulingCjk.hasMatch(said)) {
      return true;
    }
    if (detectAgendaEvent(said, now: now) != null) return true;
  }
  return false;
}

final _schedulingWords = RegExp(
  r'(?<!\p{L})(?:'
  // English
  r'free|available|availability|busy|when|what time|meet|meeting|appointment|'
  r'schedule|calendar|today|tonight|tomorrow|weekend|monday|tuesday|'
  r'wednesday|thursday|friday|saturday|sunday|lunch|dinner|breakfast|coffee|'
  r'drinks|call|hang out|catch up|'
  // German
  r'frei|zeit|wann|um wie viel uhr|treffen|termin|kalender|heute|morgen|'
  r'übermorgen|wochenende|montag|dienstag|mittwoch|donnerstag|freitag|'
  r'samstag|sonntag|verfügbar|mittagessen|abendessen|frühstück|kaffee|'
  r'telefonieren|'
  // French
  r'libre|dispo|disponible|quand|rendez-vous|rdv|demain|ce soir|'
  r'aujourd.hui|week-end|lundi|mardi|mercredi|jeudi|vendredi|samedi|'
  r'dimanche|déjeuner|dîner|'
  // Spanish and Portuguese
  r'disponível|cuándo|cuando|quando|quedar|cita|encontro|mañana|amanhã|hoy|'
  r'hoje|lunes|martes|miércoles|jueves|viernes|sábado|domingo|segunda|terça|'
  r'quarta|quinta|sexta|almuerzo|cena|almoço|jantar|livre'
  r')(?!\p{L})',
  caseSensitive: false,
  unicode: true,
);

final _schedulingCjk = RegExp(
  r'有空|空闲|没空|什么时候|几点|今天|明天|后天|周末|星期|礼拜|见面|约|日程|日历|开会',
);

/// The calendar section for an AI prompt, or null when there should be none.
///
/// Null when no calendar is configured, when the user turned the calendar off
/// for AI, when the conversation is not about time, and when the calendar
/// cannot be read — every AI feature must still answer without it, and none
/// of them may wait on a slow calendar server for long.
Future<String?> calendarContextFor({
  required IcsCalendar? calendar,
  required bool enabled,
  required List<String> transcript,
  DateTime Function()? clock,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (calendar == null || !enabled || transcript.isEmpty) return null;
  final now = (clock ?? DateTime.now)();
  if (!mentionsScheduling(transcript, now: now)) return null;
  try {
    final busy = await calendar
        .busyBetween(now, calendarAiHorizon(now))
        .timeout(timeout);
    return calendarPromptSection(busy, now: now);
  } on Object catch (error) {
    debugPrint('weft: calendar not available to the AI: $error');
    return null;
  }
}
