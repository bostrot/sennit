import 'dart:io';

import 'package:add_2_calendar/add_2_calendar.dart' as cal;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Puts one event into the device's calendar, however this platform does that.
///
/// Phones open the system calendar's event editor prefilled; desktop produces
/// an `.ics` and hands it to the share sheet, which every calendar app takes.
Future<void> addToDeviceCalendar({
  required String title,
  required DateTime start,
  DateTime? end,
  bool allDay = false,
}) async {
  final isMobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final until = end ?? start.add(const Duration(hours: 1));

  // Android goes through Weft's own channel: it *starts* the editor intent
  // rather than asking whether one is visible first — package visibility
  // restricts querying, never starting, and the query is exactly what kept
  // answering "no calendar" on devices that plainly have one.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      final opened = await const MethodChannel('com.bostrot.weft/calendar')
          .invokeMethod<bool>('insertEvent', {
            'title': title,
            'startMs': start.millisecondsSinceEpoch,
            'endMs': until.millisecondsSinceEpoch,
            'allDay': allDay,
          });
      if (opened == true) return;
    } on Object catch (error) {
      debugPrint('weft: calendar editor did not open: $error');
    }
    // No calendar app at all: fall through to the .ics share sheet.
  } else if (isMobile) {
    final opened = await cal.Add2Calendar.addEvent2Cal(
      cal.Event(title: title, startDate: start, endDate: until, allDay: allDay),
    );
    if (opened) return;
  }

  String stamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}T'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}00';
  final ics =
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Sennit//EN\r\n'
      'BEGIN:VEVENT\r\n'
      'DTSTART:${stamp(start)}\r\nDTEND:${stamp(until)}\r\n'
      'SUMMARY:${title.replaceAll(RegExp(r'[\r\n]'), ' ')}\r\n'
      'END:VEVENT\r\nEND:VCALENDAR\r\n';
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'weft-event.ics'));
  await file.writeAsString(ics);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: 'text/calendar')]),
  );
}
