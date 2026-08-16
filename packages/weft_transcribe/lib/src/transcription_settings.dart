import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'transcription_provider.dart';

/// Which backend to use.
enum TranscriptionBackend {
  /// Any endpoint speaking OpenAI's `/v1/audio/transcriptions` shape.
  openAiCompatible('OpenAI-compatible'),

  deepgram('Deepgram');

  const TranscriptionBackend(this.label);

  final String label;

  static TranscriptionBackend fromId(String? id) =>
      TranscriptionBackend.values.firstWhere(
        (b) => b.name == id,
        orElse: () => TranscriptionBackend.openAiCompatible,
      );
}

/// Everything the user configures for transcription.
///
/// The API key is deliberately absent: it lives in the platform keychain via
/// `SecretStore` and is passed in at construction time, so it never lands in
/// the settings database or in a log line.
@immutable
class TranscriptionSettings {
  const TranscriptionSettings({
    this.enabled = false,
    this.backend = TranscriptionBackend.openAiCompatible,
    this.baseUrl,
    this.model = 'whisper-1',
    this.languageHint,
    this.autoTranscribe = false,
    this.excludedNetworks = const {},
  });

  /// Master switch. Off by default — transcription means sending the audio of
  /// private conversations to whatever endpoint is configured, and that has to
  /// be a deliberate choice.
  final bool enabled;

  final TranscriptionBackend backend;

  /// Endpoint root. Required for [TranscriptionBackend.openAiCompatible];
  /// Deepgram has a fixed default.
  final String? baseUrl;

  final String model;

  /// Null means auto-detect.
  final String? languageHint;

  /// Transcribe on arrival rather than on demand. Costs money and bandwidth
  /// per message, so it is opt-in even once transcription is enabled.
  final bool autoTranscribe;

  /// Network ids never sent to the endpoint, whatever else is configured.
  /// The escape hatch for "transcribe my work chats but not my family's".
  final Set<String> excludedNetworks;

  /// Whether this configuration could actually run.
  bool get isUsable {
    if (!enabled) return false;
    return switch (backend) {
      TranscriptionBackend.openAiCompatible =>
        baseUrl != null && Uri.tryParse(baseUrl!)?.host.isNotEmpty == true,
      TranscriptionBackend.deepgram => true,
    };
  }

  bool allows(String networkId) =>
      isUsable && !excludedNetworks.contains(networkId);

  TranscriptionSettings copyWith({
    bool? enabled,
    TranscriptionBackend? backend,
    Object? baseUrl = _sentinel,
    String? model,
    Object? languageHint = _sentinel,
    bool? autoTranscribe,
    Set<String>? excludedNetworks,
  }) {
    return TranscriptionSettings(
      enabled: enabled ?? this.enabled,
      backend: backend ?? this.backend,
      baseUrl: identical(baseUrl, _sentinel)
          ? this.baseUrl
          : baseUrl as String?,
      model: model ?? this.model,
      languageHint: identical(languageHint, _sentinel)
          ? this.languageHint
          : languageHint as String?,
      autoTranscribe: autoTranscribe ?? this.autoTranscribe,
      excludedNetworks: excludedNetworks ?? this.excludedNetworks,
    );
  }

  static const Object _sentinel = Object();
}

/// Builds the provider described by [settings].
///
/// Returns null when the configuration is incomplete, so callers can treat
/// "not set up" and "set up but broken" differently.
TranscriptionProvider? buildTranscriptionProvider(
  TranscriptionSettings settings, {
  String? apiKey,
  http.Client? httpClient,
}) {
  if (!settings.isUsable) return null;

  switch (settings.backend) {
    case TranscriptionBackend.openAiCompatible:
      final uri = Uri.tryParse(settings.baseUrl!);
      if (uri == null || uri.host.isEmpty) return null;
      return OpenAiCompatibleTranscriptionProvider(
        baseUrl: uri,
        model: settings.model,
        apiKey: apiKey,
        httpClient: httpClient,
      );

    case TranscriptionBackend.deepgram:
      if (apiKey == null || apiKey.isEmpty) return null;
      return DeepgramTranscriptionProvider(
        apiKey: apiKey,
        model: settings.model == 'whisper-1' ? 'nova-2' : settings.model,
        httpClient: httpClient,
      );
  }
}
