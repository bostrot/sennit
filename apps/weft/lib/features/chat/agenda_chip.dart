import 'dart:io';

import 'package:add_2_calendar/add_2_calendar.dart' as cal;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../services/agenda/agenda_service.dart';
import '../../services/agenda/event_detector.dart';

/// The "add to calendar" offer under a message that names a date.
///
/// Draws nothing until the detector has said yes — a chip that appears and
/// vanishes as an async check resolves would make the whole timeline twitch.
/// On phones the tap opens the system calendar's event editor prefilled; on
/// desktop, where no such editor is exposed, it produces an `.ics` and hands
/// it to the share sheet, which every calendar app accepts.
class AgendaChip extends ConsumerStatefulWidget {
  const AgendaChip({super.key, required this.message});

  final WeftMessage message;

  @override
  ConsumerState<AgendaChip> createState() => _AgendaChipState();
}

class _AgendaChipState extends ConsumerState<AgendaChip> {
  AgendaCandidate? _candidate;

  @override
  void initState() {
    super.initState();
    final service = ref.read(agendaServiceProvider);
    if (service.hasVerdict(widget.message.eventId)) {
      _candidate = service.cached(widget.message.eventId);
    } else {
      service.detect(widget.message).then((candidate) {
        if (mounted && candidate != null) {
          setState(() => _candidate = candidate);
        }
      });
    }
  }

  String get _when {
    final candidate = _candidate!;
    final day = DateFormat.MMMEd().format(candidate.start);
    if (!candidate.hasTime) return day;
    return '$day, ${DateFormat.Hm().format(candidate.start)}';
  }

  Future<void> _add() async {
    final candidate = _candidate!;
    final isMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (isMobile) {
      await cal.Add2Calendar.addEvent2Cal(
        cal.Event(
          title: candidate.title,
          startDate: candidate.start,
          endDate: candidate.start.add(const Duration(hours: 1)),
          allDay: !candidate.hasTime,
        ),
      );
      return;
    }

    // Desktop: a minimal VEVENT, shared. Every calendar app opens these.
    String stamp(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}T'
        '${t.hour.toString().padLeft(2, '0')}'
        '${t.minute.toString().padLeft(2, '0')}00';
    final ics =
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//Weft//EN\r\n'
        'BEGIN:VEVENT\r\n'
        'DTSTART:${stamp(candidate.start)}\r\n'
        'DTEND:${stamp(candidate.start.add(const Duration(hours: 1)))}\r\n'
        'SUMMARY:${candidate.title.replaceAll(RegExp(r'[\r\n]'), ' ')}\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'weft-event.ics'));
    await file.writeAsString(ics);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'text/calendar')]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidate = _candidate;
    if (candidate == null) return const SizedBox.shrink();

    // No `NamedButton` here, deliberately: its `excludeSemantics` replaces the
    // chip's semantics with a static node, and a static node never reports
    // keyboard focus — which made the chip Tab-focusable in fact and
    // unreachable on paper. The chip's own visible label is already the whole
    // sentence a reader needs, so the chip speaks for itself.
    // The chip draws small; `padded` is what grows its *own* hit area to the
    // 48dp minimum — a box around it would not, because the tap target the
    // audit measures is the chip's semantics node, not its neighbourhood.
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.xxs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ActionChip(
          avatar: Icon(
            Icons.event_rounded,
            size: 16,
            color: context.colors.primary,
          ),
          label: Text('$_when · Add to calendar'),
          labelStyle: context.text.labelSmall,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: _run,
        ),
      ),
    );
  }

  Future<void> _run() async {
    try {
      await _add();
    } on Exception catch (e) {
      if (mounted) {
        showWeftMessage(context, 'Could not open the calendar: $e');
      }
    }
  }
}
