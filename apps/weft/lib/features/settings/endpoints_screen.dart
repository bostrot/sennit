import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_search/weft_search.dart'
    show OpenAiCompatibleEmbeddingProvider;
import 'package:weft_store/weft_store.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

import '../../app/a11y.dart';
import '../../app/stores.dart';
import '../../services/ai/smart_replies.dart' show probeLlm;
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

  final Map<String, String?> _testResult = {};
  final Set<String> _testing = {};

  Future<void> _runTest(String key, Future<String?> Function() probe) async {
    setState(() {
      _testing.add(key);
      _testResult.remove(key);
    });
    String? result;
    try {
      result = await probe();
    } on Object catch (error) {
      result = '$error';
    }
    if (!mounted) return;
    setState(() {
      _testing.remove(key);
      _testResult[key] = result;
    });
  }

  /// Probes run against what is *typed*, saved or not — testing is why the
  /// fields are being filled in.
  Future<String?> _probeEmbeddings() async {
    final uri = Uri.tryParse(_embeddingUrl.text.trim());
    if (uri == null || uri.host.isEmpty) return 'Enter a base URL first';
    final provider = OpenAiCompatibleEmbeddingProvider(
      baseUrl: uri,
      modelId: _embeddingModel.text.trim(),
      dimensions: int.tryParse(_embeddingDims.text) ?? 1536,
      apiKey: _embeddingKey.text.isNotEmpty
          ? _embeddingKey.text
          : ref.read(storesProvider).embeddingApiKey,
    );
    try {
      final vectors = await provider.embed(['connection test']);
      if (vectors.isEmpty || vectors.first.isEmpty) {
        return 'The server answered without a vector';
      }
      return null;
    } finally {
      provider.dispose();
    }
  }

  Future<String?> _probeLlmEndpoint() => probeLlm(
    baseUrl: _llmUrl.text,
    model: _llmModel.text,
    apiKey: _llmKey.text.isNotEmpty
        ? _llmKey.text
        : ref.read(storesProvider).llmApiKey,
  );

  Future<String?> _probeWhisper() async {
    final provider = buildTranscriptionProvider(
      TranscriptionSettings(
        enabled: true,
        backend: TranscriptionBackend.fromId(
          _settings.getString(WeftSettings.transcriptionProvider),
        ),
        baseUrl: _sttUrl.text.trim(),
        model: _sttModel.text.trim(),
        autoTranscribe: false,
      ),
      apiKey: _sttKey.text.isNotEmpty
          ? _sttKey.text
          : ref.read(storesProvider).transcriptionApiKey,
    );
    if (provider == null) return 'Enter a base URL first';
    try {
      // A quarter second of valid silence: enough for the server to accept
      // and answer, without a real message leaving this phone.
      await provider.transcribe(
        TranscriptionRequest(
          audio: _silentWav(),
          filename: 'probe.wav',
          mimeType: 'audio/wav',
        ),
      );
      return null;
    } on TranscriptionException catch (e) {
      // "Nothing recognisable" from a silence probe IS the success case.
      final message = e.message.toLowerCase();
      if (message.contains('nothing') || message.contains('recognis')) {
        return null;
      }
      return e.message;
    } finally {
      provider.dispose();
    }
  }

  /// 16 kHz mono 16-bit PCM silence, 0.25 s, with a correct RIFF header.
  static Uint8List _silentWav() {
    const sampleRate = 16000;
    const samples = sampleRate ~/ 4;
    const dataBytes = samples * 2;
    final bytes = BytesBuilder();
    void ascii(String s) => bytes.add(s.codeUnits);
    void u32(int v) => bytes.add([
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ]);
    void u16(int v) => bytes.add([v & 0xff, (v >> 8) & 0xff]);
    ascii('RIFF');
    u32(36 + dataBytes);
    ascii('WAVE');
    ascii('fmt ');
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate * 2);
    u16(2);
    u16(16);
    ascii('data');
    u32(dataBytes);
    bytes.add(Uint8List(dataBytes));
    return bytes.toBytes();
  }

  Widget _testRow(String key, Future<String?> Function() probe) {
    final busy = _testing.contains(key);
    final hasResult = _testResult.containsKey(key);
    final result = _testResult[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : () => _runTest(key, probe),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check_rounded, size: 16),
            label: const Text('Test connection'),
          ),
          const SizedBox(width: WeftSpace.md),
          if (hasResult)
            Expanded(
              child: Text(
                result ?? 'Connected',
                style: context.text.bodySmall?.copyWith(
                  color: result == null
                      ? context.palette.online
                      : context.colors.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final stores = ref.read(storesProvider);
    final oldModel = _settings.getString(WeftSettings.embeddingModel);

    // Every plain setting first, then the keychain. The keys go through the
    // system keychain, which can refuse (macOS is touchy about it for apps
    // signed the development way) — and one refusal used to abort this whole
    // method halfway, silently losing every section after the one that
    // threw. Now a keychain failure loses only the key it was for, and says
    // so.
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
    _settings.setBool(WeftSettings.transcriptionEnabled, value: _sttEnabled);
    _settings.setBool(WeftSettings.transcriptionAutoRun, value: _sttAuto);
    _settings.setString(WeftSettings.transcriptionBaseUrl, _sttUrl.text.trim());
    _settings.setString(WeftSettings.transcriptionModel, _sttModel.text.trim());
    _settings.setString(WeftSettings.llmBaseUrl, _llmUrl.text.trim());
    _settings.setString(WeftSettings.llmModel, _llmModel.text.trim());

    final keyFailures = <String>[];
    Future<void> writeKey(
      String label,
      String value,
      Future<void> Function(String) write,
    ) async {
      if (value.isEmpty) return;
      try {
        await write(value);
      } on Object catch (error) {
        debugPrint('weft: $label API key not stored: $error');
        keyFailures.add(label);
      }
    }

    await writeKey('embeddings', _embeddingKey.text, stores.setEmbeddingApiKey);
    await writeKey(
      'transcription',
      _sttKey.text,
      stores.setTranscriptionApiKey,
    );
    await writeKey('LLM', _llmKey.text, stores.setLlmApiKey);

    // A model change invalidates every stored vector: different models share
    // no coordinate space, and mixing them silently corrupts ranking.
    final newModel = _embeddingModel.text.trim();
    if (oldModel != null && oldModel.isNotEmpty && oldModel != newModel) {
      stores.search.reindexEmbeddings();
    }

    ref.read(settingsRevisionProvider.notifier).bump();
    if (!mounted) return;
    if (keyFailures.isNotEmpty) {
      showWeftMessage(
        context,
        'Saved — but the system keychain refused the '
        '${keyFailures.join(', ')} API key. Everything else is stored.',
      );
    }
    Navigator.of(context).pop();
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
            _testRow('embeddings', _probeEmbeddings),
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
            _testRow('whisper', _probeWhisper),
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
                'Any OpenAI-compatible chat endpoint. Point it at an Ollama '
                'or llama.cpp server on your own machine and message text '
                'never leaves your network — the same self-hosted rule as '
                'transcription and search above. Powers reply suggestions '
                'in notifications.',
          ),
          _field(_llmUrl, 'Base URL', hint: 'http://localhost:11434/v1'),
          _field(_llmModel, 'Model', hint: 'llama3.2'),
          _field(
            _llmKey,
            'API key (stored in the system keychain)',
            secret: true,
            hint: 'leave blank to keep the current key',
          ),
          _testRow('llm', _probeLlmEndpoint),
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
