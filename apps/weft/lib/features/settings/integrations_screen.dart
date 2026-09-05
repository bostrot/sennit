import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/integrations/home_assistant.dart';
import '../../services/integrations/paperless.dart';
import 'settings_section.dart';

/// The Home Assistant client as settings describe it, or null when unset.
final homeAssistantProvider = Provider<HomeAssistantClient?>((ref) {
  ref.watch(settingsRevisionProvider);
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

/// Home Assistant and paperless-ngx, both the user's own instances.
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

  String? _haStatus;
  String? _paperlessStatus;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [
      _haUrl,
      _haToken,
      _paperlessUrl,
      _paperlessToken,
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
    ref.read(settingsRevisionProvider.notifier).bump();
    if (mounted) showWeftMessage(context, context.l10n.commonSaved);
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _haStatus = null;
      _paperlessStatus = null;
    });
    await _save();

    final ha = ref.read(homeAssistantProvider);
    final paperless = ref.read(paperlessProvider);
    final haOk = ha == null ? null : await ha.probe();
    final paperlessOk = paperless == null ? null : await paperless.probe();
    if (!mounted) return;
    setState(() {
      _busy = false;
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

  Widget _status(String text) => Padding(
    padding: const EdgeInsets.only(bottom: WeftSpace.sm),
    child: Text(
      text,
      style: context.text.bodySmall?.copyWith(
        color: text == 'Connected.'
            ? context.palette.online
            : context.colors.onSurfaceVariant,
      ),
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.md),
      child: TextField(
        controller: controller,
        obscureText: secret,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}
