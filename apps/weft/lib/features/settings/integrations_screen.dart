import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/billing_providers.dart';
import '../../app/calendar_providers.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/agenda/ics_calendar.dart';
import '../../services/billing/entitlements.dart';
import '../../services/integrations/home_assistant.dart';
import '../../services/integrations/paperless.dart';
import 'settings_section.dart';

/// The Home Assistant client as settings describe it, or null when unset.
final homeAssistantProvider = Provider<HomeAssistantClient?>((ref) {
  ref.watch(settingsRevisionProvider);
  if (!proUnlocked(ref, ProFeature.integrations)) return null;
  final stores = storesOrNull(ref);
  if (stores == null) return null;

  final url = stores.settings.getString(WeftSettings.homeAssistantUrl);
  final token = stores.homeAssistantToken;
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  final client = HomeAssistantClient(baseUrl: uri, token: token);
  ref.onDispose(client.dispose);
  return client;
});

/// Same shape for paperless-ngx.
final paperlessProvider = Provider<PaperlessClient?>((ref) {
  ref.watch(settingsRevisionProvider);
  if (!proUnlocked(ref, ProFeature.integrations)) return null;
  final stores = storesOrNull(ref);
  if (stores == null) return null;

  final url = stores.settings.getString(WeftSettings.paperlessUrl);
  final token = stores.paperlessToken;
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  final client = PaperlessClient(baseUrl: uri, token: token);
  ref.onDispose(client.dispose);
  return client;
});

/// Home Assistant, paperless-ngx and a shared calendar — all the user's own.
class IntegrationsScreen extends ConsumerStatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  ConsumerState<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends ConsumerState<IntegrationsScreen> {
  late final SettingsStore _settings = ref.read(storesProvider).settings;

  late final _haUrl = TextEditingController(
    text: _settings.getString(WeftSettings.homeAssistantUrl) ?? '',
  );
  final _haToken = TextEditingController();
  late final _paperlessUrl = TextEditingController(
    text: _settings.getString(WeftSettings.paperlessUrl) ?? '',
  );
  final _paperlessToken = TextEditingController();

  /// Shown in full rather than as a "keep the current one" blank like the
  /// tokens: an address is something people paste, check and correct, and
  /// clearing it is how the calendar is removed.
  ///
  /// One field per calendar, and always at least one to paste into.
  late final List<TextEditingController> _calendarUrls = [
    for (final line in _storedCalendarLines())
      TextEditingController(text: line),
  ];
  late bool _calendarForAi = _settings.getBool(
    WeftSettings.calendarForAi,
    fallback: true,
  );

  String? _haStatus;
  String? _paperlessStatus;

  /// The last test's verdict on each calendar field, by its controller — a
  /// field added or removed since must not inherit its neighbour's.
  final Map<TextEditingController, ({String text, bool ok})> _calendarStatus =
      {};
  bool _busy = false;

  List<String> _storedCalendarLines() {
    final lines = [
      for (final line in (ref.read(storesProvider).calendarIcsUrl ?? '').split(
        '\n',
      ))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return lines.isEmpty ? [''] : lines;
  }

  @override
  void dispose() {
    for (final controller in [
      _haUrl,
      _haToken,
      _paperlessUrl,
      _paperlessToken,
      ..._calendarUrls,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final stores = ref.read(storesProvider);
    _settings.setString(WeftSettings.homeAssistantUrl, _haUrl.text.trim());
    _settings.setString(WeftSettings.paperlessUrl, _paperlessUrl.text.trim());
    if (_haToken.text.isNotEmpty) {
      await stores.setHomeAssistantToken(_haToken.text.trim());
    }
    if (_paperlessToken.text.isNotEmpty) {
      await stores.setPaperlessToken(_paperlessToken.text.trim());
    }
    // As typed, one per line, so an address that is not one yet is still
    // there to be corrected; only the fetchable ones are ever asked.
    final calendarUrls = [
      for (final field in _calendarUrls)
        if (field.text.trim().isNotEmpty) field.text.trim(),
    ].join('\n');
    if (calendarUrls != (stores.calendarIcsUrl ?? '')) {
      await stores.setCalendarIcsUrl(
        calendarUrls.isEmpty ? null : calendarUrls,
      );
    }
    _settings.setBool(WeftSettings.calendarForAi, value: _calendarForAi);
    ref.read(settingsRevisionProvider.notifier).bump();
    if (mounted) showWeftMessage(context, context.l10n.commonSaved);
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _haStatus = null;
      _paperlessStatus = null;
      _calendarStatus.clear();
    });
    await _save();

    final ha = ref.read(homeAssistantProvider);
    final paperless = ref.read(paperlessProvider);
    final shared = ref.read(icsCalendarProvider);
    final haOk = ha == null ? null : await ha.probe();
    final paperlessOk = paperless == null ? null : await paperless.probe();

    // Each address on its own, through the very calendars the app will ask —
    // so the copy this test fetched is the one the next reply is written
    // from, and a dead link is named rather than failing all of them.
    final calendars = {
      if (shared is IcsCalendarGroup)
        for (final calendar in shared.calendars) calendar.url: calendar,
    };
    final events = <TextEditingController, int?>{};
    await Future.wait([
      for (final field in _calendarUrls)
        if (calendars[icsUriFrom(field.text)] case final calendar?)
          () async {
            try {
              events[field] = (await calendar.load(force: true)).length;
            } on IcsFetchException catch (error) {
              debugPrint('weft: calendar test failed: $error');
              events[field] = null;
            }
          }(),
    ]);
    if (!mounted) return;
    final l10n = context.l10n;
    setState(() {
      _busy = false;
      for (final field in _calendarUrls) {
        if (field.text.trim().isEmpty) continue;
        final count = events[field];
        _calendarStatus[field] = !events.containsKey(field)
            ? (text: l10n.integrationsCalendarInvalid, ok: false)
            : count == null
            ? (text: l10n.integrationsCalendarFailed, ok: false)
            : (text: l10n.integrationsCalendarRead(count), ok: true);
      }
      _haStatus = switch (haOk) {
        null => 'Not configured.',
        true => 'Connected.',
        false => 'Could not reach it — check the URL and token.',
      };
      _paperlessStatus = switch (paperlessOk) {
        null => 'Not configured.',
        true => 'Connected.',
        false => 'Could not reach it — check the URL and token.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.integrationsTitle),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: Text(context.l10n.commonSave),
          ),
          const SizedBox(width: WeftSpace.sm),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            SettingsSectionHeader(
              title: context.l10n.integrationsHomeAssistantTitle,
              subtitle: context.l10n.integrationsHomeAssistantSubtitle,
            ),
            _field(
              _haUrl,
              context.l10n.settingsBaseUrlField,
              hint: 'http://homeassistant.local:8123',
            ),
            _field(
              _haToken,
              context.l10n.integrationsTokenField,
              secret: true,
              hint: context.l10n.settingsKeepCurrentTokenHint,
            ),
            if (_haStatus != null) _status(_haStatus!),
            const SizedBox(height: WeftSpace.xl),

            SettingsSectionHeader(
              title: context.l10n.integrationsPaperlessTitle,
              subtitle: context.l10n.integrationsPaperlessSubtitle,
            ),
            _field(
              _paperlessUrl,
              context.l10n.settingsBaseUrlField,
              hint: 'https://paperless.example',
            ),
            _field(
              _paperlessToken,
              context.l10n.integrationsApiTokenField,
              secret: true,
              hint: context.l10n.settingsKeepCurrentTokenHint,
            ),
            if (_paperlessStatus != null) _status(_paperlessStatus!),
            const SizedBox(height: WeftSpace.xl),

            SettingsSectionHeader(
              title: context.l10n.integrationsCalendarTitle,
              subtitle: context.l10n.integrationsCalendarSubtitle,
            ),
            for (final field in _calendarUrls) ...[
              _field(
                field,
                context.l10n.integrationsCalendarUrlField,
                hint: 'webcal://calendar.example/basic.ics',
                // The last field stays: clearing it is how the last calendar
                // is removed, and there must be somewhere to paste the next.
                onRemove: _calendarUrls.length > 1
                    ? () => _removeCalendar(field)
                    : null,
              ),
              if (_calendarStatus[field] case final status?)
                _status(status.text, ok: status.ok),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _busy ? null : _addCalendar,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(context.l10n.integrationsCalendarAdd),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _calendarForAi,
              onChanged: (value) => setState(() => _calendarForAi = value),
              title: PrivacyGatedTitle(
                title: context.l10n.integrationsCalendarForAiTitle,
                warning: context.l10n.integrationsCalendarForAiWarning,
              ),
              subtitle: Text(context.l10n.integrationsCalendarForAiSubtitle),
            ),
            const SizedBox(height: WeftSpace.xl),

            FilledButton.tonalIcon(
              onPressed: _busy ? null : _test,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_rounded, size: 18),
              label: Text(context.l10n.integrationsSaveAndTest),
            ),
          ],
        ),
      ),
    );
  }

  Widget _status(String text, {bool? ok}) => Padding(
    padding: const EdgeInsets.only(bottom: WeftSpace.sm),
    child: Text(
      text,
      style: context.text.bodySmall?.copyWith(
        color: (ok ?? text == 'Connected.')
            ? context.palette.online
            : context.colors.onSurfaceVariant,
      ),
    ),
  );

  void _addCalendar() =>
      setState(() => _calendarUrls.add(TextEditingController()));

  void _removeCalendar(TextEditingController field) {
    setState(() {
      _calendarUrls.remove(field);
      _calendarStatus.remove(field);
    });
    // After the frame that stops showing it — a controller disposed while its
    // field is still mounted throws.
    WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    VoidCallback? onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.md),
      child: TextField(
        controller: controller,
        obscureText: secret,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: onRemove == null
              ? null
              : IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded),
                  tooltip: context.l10n.integrationsCalendarRemove,
                ),
        ),
      ),
    );
  }
}
