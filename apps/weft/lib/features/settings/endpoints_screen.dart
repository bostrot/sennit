import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_search/weft_search.dart'
    show OpenAiCompatibleEmbeddingProvider;
import 'package:weft_store/weft_store.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/ai/smart_replies.dart' show probeLlm;
import '../../services/transcription/transcription_languages.dart';
import 'models_screen.dart';
import 'settings_section.dart';

/// The three endpoints this screen configures, as "copy from" names them.
enum _Endpoint {
  embeddings('embeddings'),
  transcription('whisper'),
  llm('llm');

  const _Endpoint(this.testKey);

  /// The key this endpoint's test result is filed under.
  final String testKey;
}

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

  /// Empty for "detect it": the dropdown needs a non-null value to select.
  late String _sttLanguage =
      _settings.getString(WeftSettings.transcriptionLanguage) ?? '';

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

  /// Fills [to]'s address and key from [from]'s.
  ///
  /// One server usually answers for all three — an Ollama or LM Studio box
  /// speaks embeddings, chat and often Whisper on the same base URL — and
  /// typing it three times is how the three drift apart. Copies what is
  /// *typed* in [from], falling back to its stored key: the key field is
  /// blank for "keep the current one", so the typed text alone would copy
  /// nothing from an endpoint that was set up last week.
  ///
  /// The model is left alone on purpose. It is the one field that is never
  /// the same between an embedding, a speech and a chat endpoint.
  void _copyEndpoint(_Endpoint from, _Endpoint to) {
    final stores = ref.read(storesProvider);
    final (fromUrl, fromKey, storedKey) = switch (from) {
      _Endpoint.embeddings => (
        _embeddingUrl,
        _embeddingKey,
        stores.embeddingApiKey,
      ),
      _Endpoint.transcription => (
        _sttUrl,
        _sttKey,
        stores.transcriptionApiKey,
      ),
      _Endpoint.llm => (_llmUrl, _llmKey, stores.llmApiKey),
    };
    final (toUrl, toKey) = switch (to) {
      _Endpoint.embeddings => (_embeddingUrl, _embeddingKey),
      _Endpoint.transcription => (_sttUrl, _sttKey),
      _Endpoint.llm => (_llmUrl, _llmKey),
    };
    final key = fromKey.text.isNotEmpty ? fromKey.text : (storedKey ?? '');
    setState(() {
      toUrl.text = fromUrl.text.trim();
      if (key.isNotEmpty) toKey.text = key;
      // Whatever the last test said, it said about the old address.
      _testResult.remove(to.testKey);
    });
  }

  Widget _copyRow(_Endpoint target) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: MenuAnchor(
          menuChildren: [
            for (final source in _Endpoint.values)
              if (source != target)
                MenuItemButton(
                  onPressed: () => _copyEndpoint(source, target),
                  child: Text(switch (source) {
                    _Endpoint.embeddings => l10n.endpointsEmbeddingsTitle,
                    _Endpoint.transcription => l10n.endpointsTranscriptionTitle,
                    _Endpoint.llm => l10n.endpointsLlmTitle,
                  }),
                ),
          ],
          builder: (context, controller, _) => TextButton.icon(
            key: ValueKey('copy-into-${target.name}'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.content_copy_rounded, size: 16),
            label: Text(l10n.endpointsCopyFrom),
          ),
        ),
      ),
    );
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
            label: Text(context.l10n.endpointsTestConnection),
          ),
          const SizedBox(width: WeftSpace.md),
          if (hasResult)
            Expanded(
              child: Text(
                result ?? context.l10n.endpointsConnected,
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
    if (_sttLanguage.isEmpty) {
      _settings.remove(WeftSettings.transcriptionLanguage);
    } else {
      _settings.setString(WeftSettings.transcriptionLanguage, _sttLanguage);
    }
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
        context.l10n.endpointsKeychainRefused(keyFailures.join(', ')),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.endpointsTitle),
        actions: [
          TextButton(onPressed: _save, child: Text(context.l10n.commonSave)),
          const SizedBox(width: WeftSpace.sm),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            PrivacyNotice(message: context.l10n.endpointsNotice),
            const SizedBox(height: WeftSpace.lg),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: Text(context.l10n.modelsTitle),
                subtitle: Text(context.l10n.endpointsLocalModelsSubtitle),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ModelsScreen()),
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.xl),

            SettingsSectionHeader(
              title: context.l10n.endpointsEmbeddingsTitle,
              subtitle: context.l10n.endpointsEmbeddingsSubtitle,
            ),
            SwitchListTile(
              title: PrivacyGatedTitle(
                title: context.l10n.endpointsEnableEmbeddings,
                warning: context.l10n.endpointsEnableEmbeddingsWarning,
              ),
              value: _embeddingEnabled,
              onChanged: (v) => setState(() => _embeddingEnabled = v),
              contentPadding: EdgeInsets.zero,
            ),
            if (_embeddingEnabled) ...[
              _field(
                _embeddingUrl,
                context.l10n.settingsBaseUrlField,
                hint: 'http://localhost:8080/v1',
              ),
              _field(
                _embeddingModel,
                context.l10n.settingsModelField,
                hint: 'text-embedding-3-small',
              ),
              _field(
                _embeddingDims,
                context.l10n.settingsDimensionsField,
                hint: '1536',
                number: true,
              ),
              _field(
                _embeddingKey,
                context.l10n.settingsApiKeyField,
                secret: true,
                hint: context.l10n.settingsKeepCurrentKeyHint,
              ),
              _copyRow(_Endpoint.embeddings),
              _testRow(_Endpoint.embeddings.testKey, _probeEmbeddings),
            ],
            const SizedBox(height: WeftSpace.xl),

            SettingsSectionHeader(
              title: context.l10n.endpointsTranscriptionTitle,
              subtitle: context.l10n.endpointsTranscriptionSubtitle,
            ),
            SwitchListTile(
              title: PrivacyGatedTitle(
                title: context.l10n.endpointsEnableTranscription,
                warning: context.l10n.endpointsEnableTranscriptionWarning,
              ),
              value: _sttEnabled,
              onChanged: (v) => setState(() => _sttEnabled = v),
              contentPadding: EdgeInsets.zero,
            ),
            if (_sttEnabled) ...[
              _field(
                _sttUrl,
                context.l10n.settingsBaseUrlField,
                hint: 'http://localhost:9000/v1',
              ),
              _field(
                _sttModel,
                context.l10n.settingsModelField,
                hint: 'whisper-1',
              ),
              _field(
                _sttKey,
                context.l10n.settingsApiKeyField,
                secret: true,
                hint: context.l10n.settingsKeepCurrentKeyHint,
              ),
              _copyRow(_Endpoint.transcription),
              _testRow(_Endpoint.transcription.testKey, _probeWhisper),
              SwitchListTile(
                title: Text(context.l10n.endpointsAutoTranscribeTitle),
                subtitle: Text(context.l10n.endpointsAutoTranscribeSubtitle),
                value: _sttAuto,
                onChanged: (v) => setState(() => _sttAuto = v),
                contentPadding: EdgeInsets.zero,
              ),
            ],
            // Outside the switch: an on-device model reads the same setting,
            // and it is the only transcription a user without an endpoint has.
            _languageField(),
            const SizedBox(height: WeftSpace.xl),

            SettingsSectionHeader(
              title: context.l10n.endpointsLlmTitle,
              subtitle: context.l10n.endpointsLlmSubtitle,
            ),
            _field(
              _llmUrl,
              context.l10n.settingsBaseUrlField,
              hint: 'http://localhost:11434/v1',
            ),
            _field(
              _llmModel,
              context.l10n.settingsModelField,
              hint: 'llama3.2',
            ),
            _field(
              _llmKey,
              context.l10n.settingsApiKeyField,
              secret: true,
              hint: context.l10n.settingsKeepCurrentKeyHint,
            ),
            _copyRow(_Endpoint.llm),
            _testRow(_Endpoint.llm.testKey, _probeLlmEndpoint),
          ],
        ),
      ),
    );
  }

  /// The spoken language sent with every voice message.
  ///
  /// Whisper detects it, so "detect" is the default; Cohere Transcribe cannot,
  /// and an endpoint serving it reads no language as English — German speech
  /// then comes back as an English rendering of what was said.
  Widget _languageField() {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.md),
      child: DropdownButtonFormField<String>(
        key: const ValueKey('transcription-language'),
        initialValue: _sttLanguage,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.endpointsTranscriptionLanguageField,
          helperText: l10n.endpointsTranscriptionLanguageHelper,
          helperMaxLines: 4,
        ),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(l10n.endpointsTranscriptionLanguageDetect),
          ),
          // A stored code from before this list grew, or typed into the
          // settings database by hand, stays selectable rather than throwing.
          if (_sttLanguage.isNotEmpty &&
              !kTranscriptionLanguages.containsKey(_sttLanguage))
            DropdownMenuItem(value: _sttLanguage, child: Text(_sttLanguage)),
          for (final entry in kTranscriptionLanguages.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (value) => setState(() => _sttLanguage = value ?? ''),
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
