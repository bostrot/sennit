import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../app/calendar_providers.dart';
import '../../app/localisation.dart';
import '../../services/agenda/ics_calendar.dart';

/// How long an invitation is assumed to last when checking it against the
/// calendar. The invitation itself carries no end; an hour is what the device
/// calendar is handed for it too (`addToDeviceCalendar`).
const Duration kInviteAssumedLength = Duration(hours: 1);

/// How many busy spans the time picker's header names before it stops.
const int _maxSpansShown = 4;

/// Date then time for a calendar invitation, with the user's own calendar in
/// view.
///
/// The plain date-and-time pair, plus two things when a shared calendar is set
/// up on the integrations screen: the time picker's header lists the day's
/// busy times, and a time that lands on one of them is questioned before it is
/// used. Without a calendar — or with one that does not answer in time — it is
/// exactly the plain pair, because a slow calendar server must never stand
/// between the user and sending an invitation.
Future<DateTime?> pickInviteTime(
  BuildContext context,
  WidgetRef ref, {
  required DateTime from,
}) async {
  final calendar = ref.read(icsCalendarProvider);
  // Started before the date picker opens, so the fetch is usually done by the
  // time a day has been chosen.
  final loading = calendar?.load().then<IcsEventSet?>(
    (events) => events,
    onError: (Object _) => null,
  );

  final date = await showDatePicker(
    context: context,
    initialDate: from,
    firstDate: from,
    lastDate: from.add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;

  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = DateTime(date.year, date.month, date.day + 1);
  final events = await loading?.timeout(
    const Duration(seconds: 5),
    onTimeout: () => null,
  );
  if (!context.mounted) return null;
  final busy = events == null
      ? null
      : mergeBusy(events.busyBetween(dayStart, dayEnd));

  final l10n = context.l10n;
  String? help;
  if (busy != null) {
    final spans = [
      for (final block in busy.take(_maxSpansShown))
        describeBusyOnDay(block, dayStart, l10n.chatInviteBusyAllDay),
    ];
    help = busy.isEmpty
        ? l10n.chatInviteFreeAllDay
        : l10n.chatInviteBusyHeader(
            busy.length > _maxSpansShown
                ? '${spans.join(', ')}, …'
                : spans.join(', '),
          );
  }

  var initial = TimeOfDay.fromDateTime(from.add(const Duration(hours: 1)));
  while (true) {
    final time = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: help,
    );
    if (time == null || !context.mounted) return null;
    final start = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final clash = busy
        ?.where((b) => b.overlaps(start, start.add(kInviteAssumedLength)))
        .firstOrNull;
    if (clash == null) return start;

    final span = describeBusyOnDay(clash, dayStart, l10n.chatInviteBusyAllDay);
    final sendAnyway = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.chatInviteClashTitle),
        content: Text(context.l10n.chatInviteClashBody(span)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.chatInviteClashPickAgain),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.chatInviteClashKeep),
          ),
        ],
      ),
    );
    if (sendAnyway == null || !context.mounted) return null;
    if (sendAnyway) return start;
    initial = time;
  }
}

/// [block] as it reads on the day starting at [dayStart]: "14:00–15:30", or
/// [allDay] when it covers the whole day. A block that runs over midnight is
/// cut at the day's edges — on this day it is busy from 22:00 to midnight.
String describeBusyOnDay(BusyBlock block, DateTime dayStart, String allDay) {
  final dayEnd = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
  final from = block.start.isBefore(dayStart) ? dayStart : block.start;
  final to = block.end.isAfter(dayEnd) ? dayEnd : block.end;
  if (!from.isAfter(dayStart) && !to.isBefore(dayEnd)) return allDay;
  final clock = DateFormat.Hm();
  // Midnight at the end reads as 24:00 in a span, not as the start of a day.
  final end = to == dayEnd ? '24:00' : clock.format(to);
  return '${clock.format(from)}–$end';
}
