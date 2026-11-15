import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import '../services/agenda/ics_calendar.dart';
import '../services/billing/entitlements.dart';
import 'billing_providers.dart';
import 'stores.dart';

/// The shared calendars the user added on the integrations screen, answering
/// as one, or null when there are none.
///
/// Rebuilt when settings are saved, which drops the copies held in memory — a
/// changed address must not keep answering from the old calendar.
final icsCalendarProvider = Provider<SharedCalendar?>((ref) {
  ref.watch(settingsRevisionProvider);
  if (!proUnlocked(ref, ProFeature.integrations)) return null;
  final uris = icsUrisFrom(storesOrNull(ref)?.calendarIcsUrl);
  if (uris.isEmpty) return null;
  final calendars = IcsCalendarGroup([
    for (final uri in uris) IcsCalendar(url: uri),
  ]);
  ref.onDispose(calendars.dispose);
  return calendars;
});

/// The calendar section for an AI prompt about [transcript], or null.
///
/// The one function auto-replies and reply suggestions both call, so the two
/// features agree on when the calendar is sent and what of it — see
/// [calendarContextFor].
///
/// Called from callbacks rather than from a build, so it reads and never
/// watches.
///
/// [timeout] bounds the wait for a calendar that is not in memory yet; the
/// notification path passes a short one, because the notification itself is
/// held until its chips are written.
Future<String?> aiCalendarContext(
  Ref ref,
  List<String> transcript, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final bool enabled;
  try {
    enabled = ref
        .read(storesProvider)
        .settings
        .getBool(WeftSettings.calendarForAi, fallback: true);
  } on Object {
    return null;
  }
  return calendarContextFor(
    calendar: ref.read(icsCalendarProvider),
    enabled: enabled,
    transcript: transcript,
    timeout: timeout,
  );
}
