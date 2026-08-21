import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';
import 'models_screen.dart';
import 'settings_section.dart';

/// Configuration for the user's own transcription and embedding endpoints.
///
/// Both are off by default and gated behind an explicit warning: enabling them
/// sends decrypted message content to whatever endpoint is configured, which
/// undoes E2EE for that content. The warning states this plainly rather than
/// hiding it in a tooltip.
class EndpointsScreen extends ConsumerStatefulWidget {
  const EndpointsScreen({super.key});

  @override
  ConsumerState<EndpointsScreen> createState() => _EndpointsScreenState();
}

class _EndpointsScreenState extends ConsumerState<EndpointsScreen> {
  late final SettingsStore _settings = ref.read(storesProvider).settings;

  late bool _embeddingEnabled = _settings.getBool(
    WeftSettings.embeddingEnabled,
  );
  late final _embeddingUrl = TextEditingController(
    text: _settings.getString(WeftSettings.embeddingBaseUrl) ?? '',
  );
  late final _embeddingModel = TextEditingController(
    text: _settings.getString(WeftSettings.embeddingModel) ?? '',
  );
  late final _embeddingDims = TextEditingController(
    text: '${_settings.getInt('search.embedding_dimensions') ?? 1536}',
  );
  final _embeddingKey = TextEditingController();

  late bool _sttEnabled = _settings.getBool(WeftSettings.transcriptionEnabled);
  late bool _sttAuto = _settings.getBool(WeftSettings.transcriptionAutoRun);
  late final _sttUrl = TextEditingController(
    text: _settings.getString(WeftSettings.transcriptionBaseUrl) ?? '',
  );
  late final _sttModel = TextEditingController(
    text: _settings.getString(WeftSettings.transcriptionModel) ?? 'whisper-1',
  );
  final _sttKey = TextEditingController();

  late final _llmUrl = TextEditingController(
    text: _settings.getString(WeftSettings.llmBaseUrl) ?? '',
  );
  late final _llmModel = TextEditingController(
    text: _settings.getString(WeftSettings.llmModel) ?? '',
  );
  final _llmKey = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _embeddingUrl,
      _embeddingModel,
      _embeddingDims,
      _embeddingKey,
      _sttUrl,
      _sttModel,
      _sttKey,
      _llmUrl,
      _llmModel,
      _llmKey,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final stores = ref.read(storesProvider);
    final oldModel = _settings.getString(WeftSettings.embeddingModel);

    _settings.setBool(WeftSettings.embeddingEnabled, value: _embeddingEnabled);
    _settings.setString(
      WeftSettings.embeddingBaseUrl,
      _embeddingUrl.text.trim(),
    );
    _settings.setString(
      WeftSettings.embeddingModel,
      _embeddingModel.text.trim(),
    );
    _settings.setInt(
      'search.embedding_dimensions',
      int.tryParse(_embeddingDims.text) ?? 1536,
    );
    if (_embeddingKey.text.isNotEmpty) {
      await stores.setEmbeddingApiKey(_embeddingKey.text);
    }

    _settings.setBool(WeftSettings.transcriptionEnabled, value: _sttEnabled);
    _settings.setBool(WeftSettings.transcriptionAutoRun, value: _sttAuto);
    _settings.setString(WeftSettings.transcriptionBaseUrl, _sttUrl.text.trim());
    _settings.setString(WeftSettings.transcriptionModel, _sttModel.text.trim());
    if (_sttKey.text.isNotEmpty) {
      await stores.setTranscriptionApiKey(_sttKey.text);
    }

    _settings.setString(WeftSettings.llmBaseUrl, _llmUrl.text.trim());
    _settings.setString(WeftSettings.llmModel, _llmModel.text.trim());
    if (_llmKey.text.isNotEmpty) {
      await stores.setLlmApiKey(_llmKey.text);
    }

    // A model change invalidates every stored vector: different models share
    // no coordinate space, and mixing them silently corrupts ranking.
    final newModel = _embeddingModel.text.trim();
    if (oldModel != null && oldModel.isNotEmpty && oldModel != newModel) {
      stores.search.reindexEmbeddings();
    }

    ref.read(settingsRevisionProvider.notifier).bump();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Endpoints'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: WeftSpace.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          const PrivacyNotice(
            message:
                'These endpoints receive decrypted message text or audio. For '
                'a remote endpoint, that undoes end-to-end encryption for '
                'whatever is sent to it. Point them at software you run '
                'yourself to keep everything local.',
          ),
          const SizedBox(height: WeftSpace.lg),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Local models'),
              subtitle: const Text(
                'Run search and transcription on this device instead of an '
                'endpoint. If you use these, the settings below can stay off.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ModelsScreen()),
              ),
            ),
          ),
          const SizedBox(height: WeftSpace.xl),

          SettingsSectionHeader(
            title: 'Semantic search embeddings',
            subtitle:
                'Only needed if you are NOT using an on-device model. With a '
                'local model installed and switched on, leave this off — the '
                'device does the work and nothing is sent anywhere.',
          ),
          SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Enable embeddings',
              warning:
                  'Turning this on sends the text of your messages to the '
                  'endpoint below.',
            ),
            value: _embeddingEnabled,
            onChanged: (v) => setState(() => _embeddingEnabled = v),
            contentPadding: EdgeInsets.zero,
          ),
          if (_embeddingEnabled) ...[
            _field(_embeddingUrl, 'Base URL', hint: 'http://localhost:8080/v1'),
            _field(_embeddingModel, 'Model', hint: 'text-embedding-3-small'),
            _field(_embeddingDims, 'Dimensions', hint: '1536', number: true),
            _field(
              _embeddingKey,
              'API key (stored in the system keychain)',
              secret: true,
              hint: 'leave blank to keep the current key',
            ),
          ],
          const SizedBox(height: WeftSpace.xl),

          SettingsSectionHeader(
            title: 'Voice transcription',
            subtitle:
                'Only needed if you are NOT using an on-device model. A local '
                'Whisper model switched on for voice always takes precedence '
                'over anything configured here.',
          ),
          SwitchListTile(
            title: const PrivacyGatedTitle(
              title: 'Enable transcription',
              warning:
                  'Turning this on sends the audio of your voice messages to '
                  'the endpoint below.',
            ),
            value: _sttEnabled,
            onChanged: (v) => setState(() => _sttEnabled = v),
            contentPadding: EdgeInsets.zero,
          ),
          if (_sttEnabled) ...[
            _field(_sttUrl, 'Base URL', hint: 'http://localhost:9000/v1'),
            _field(_sttModel, 'Model', hint: 'whisper-1'),
            _field(
              _sttKey,
              'API key (stored in the system keychain)',
              secret: true,
              hint: 'leave blank to keep the current key',
            ),
            SwitchListTile(
              title: const Text('Transcribe voice messages automatically'),
              subtitle: const Text(
                'Otherwise each voice message has a Transcribe action.',
              ),
              value: _sttAuto,
              onChanged: (v) => setState(() => _sttAuto = v),
              contentPadding: EdgeInsets.zero,
            ),
          ],
          const SizedBox(height: WeftSpace.xl),

          SettingsSectionHeader(
            title: 'AI assistant (LLM)',
            subtitle:
                'An OpenAI-compatible chat endpoint — a local Ollama works. '
                'Features that use it, like reply suggestions in '
                'notifications, have their own switches and stay off until '
                'you turn them on.',
          ),
          _field(_llmUrl, 'Base URL', hint: 'http://localhost:11434/v1'),
          _field(_llmModel, 'Model', hint: 'llama3.2'),
          _field(
            _llmKey,
            'API key (stored in the system keychain)',
            secret: true,
            hint: 'leave blank to keep the current key',
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.md),
      child: TextField(
        controller: controller,
        obscureText: secret,
        autocorrect: false,
        keyboardType: number ? TextInputType.number : TextInputType.url,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}
