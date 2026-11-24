import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'llm_request.dart';

/// What a server said about one model's limits.
@immutable
class LlmLimits {
  const LlmLimits({this.contextTokens, this.outputTokens, required this.from});

  /// The context window, in tokens, or null when the server did not say.
  final int? contextTokens;

  /// The longest answer, in tokens, or null when the server did not say.
  final int? outputTokens;

  /// The kind of server that said it: `litellm`, `ollama`, `lmstudio` or
  /// `openai` (any `/v1/models` that lists limits — vLLM, OpenRouter, …).
  final String from;

  bool get isEmpty => contextTokens == null && outputTokens == null;

  @override
  bool operator ==(Object other) =>
      other is LlmLimits &&
      other.contextTokens == contextTokens &&
      other.outputTokens == outputTokens &&
      other.from == from;

  @override
  int get hashCode => Object.hash(contextTokens, outputTokens, from);

  @override
  String toString() =>
      'LlmLimits(context $contextTokens, output $outputTokens, from $from)';
}

int? _positiveInt(Object? v) => switch (v) {
  final int n when n > 0 => n,
  final double n when n > 0 && n.isFinite => n.round(),
  final String s => _positiveInt(int.tryParse(s)),
  _ => null,
};

/// Whether [entry] names [model], ignoring case: the id a request is sent
/// with is the one the list is searched for.
bool _names(String? entry, String model) =>
    entry != null && entry.trim().toLowerCase() == model.trim().toLowerCase();

/// [model]'s limits in a litellm `/model/info` (or `/v1/model/info`) answer:
/// `{"data": [{"model_name": …, "model_info": {"max_input_tokens": …,
/// "max_output_tokens": …, "max_tokens": …}}]}`.
///
/// `max_input_tokens` is the window, as litellm's own context-window checks
/// read it; `max_tokens` is litellm's older spelling of the answer limit, used
/// when `max_output_tokens` is missing.
LlmLimits? parseLitellmModelInfo(Object? json, String model) {
  if (json is! Map || json['data'] is! List) return null;
  for (final entry in (json['data'] as List).whereType<Map>()) {
    if (!_names(entry['model_name'] as String?, model)) continue;
    final info = entry['model_info'];
    if (info is! Map) continue;
    final limits = LlmLimits(
      contextTokens: _positiveInt(info['max_input_tokens']),
      outputTokens:
          _positiveInt(info['max_output_tokens']) ??
          _positiveInt(info['max_tokens']),
      from: 'litellm',
    );
    if (!limits.isEmpty) return limits;
  }
  return null;
}

/// [model]'s limits in an OpenAI-style `/models` answer, for the servers that
/// add them to the list: litellm (`max_input_tokens`, `max_output_tokens`),
/// vLLM (`max_model_len`), OpenRouter and Together (`context_length`, and
/// OpenRouter's `top_provider.max_completion_tokens`), LM Studio's
/// `/api/v0/models` (`max_context_length`, `loaded_context_length`).
///
/// OpenAI's own list says nothing about limits, and gets null.
LlmLimits? parseOpenAiModels(Object? json, String model) {
  if (json is! Map || json['data'] is! List) return null;
  for (final entry in (json['data'] as List).whereType<Map>()) {
    if (!_names(entry['id'] as String?, model)) continue;
    final limits = _modelEntryLimits(entry, from: 'openai');
    if (limits != null) return limits;
  }
  return null;
}

LlmLimits? _modelEntryLimits(Map entry, {required String from}) {
  final top = entry['top_provider'];
  final limits = LlmLimits(
    // A loaded LM Studio model's window is what it was loaded with, which is
    // what a request is held to — not the most it could be loaded with.
    contextTokens:
        _positiveInt(entry['loaded_context_length']) ??
        _positiveInt(entry['max_input_tokens']) ??
        _positiveInt(entry['max_model_len']) ??
        _positiveInt(entry['context_length']) ??
        _positiveInt(entry['context_window']) ??
        _positiveInt(entry['max_context_length']) ??
        (top is Map ? _positiveInt(top['context_length']) : null),
    outputTokens:
        _positiveInt(entry['max_output_tokens']) ??
        _positiveInt(entry['max_completion_tokens']) ??
        (top is Map ? _positiveInt(top['max_completion_tokens']) : null),
    from: from,
  );
  return limits.isEmpty ? null : limits;
}

/// The window in an Ollama `/api/show` answer.
///
/// What a request actually gets is `num_ctx` when the model's parameters set
/// one — Ollama loads every model with a small window unless told otherwise,
/// and a prompt longer than it is cut from the front without a word. The
/// architecture's `<arch>.context_length` is only the most the model was
/// trained for, and is used when no `num_ctx` is set.
LlmLimits? parseOllamaShow(Object? json) {
  if (json is! Map) return null;
  int? numCtx;
  final parameters = json['parameters'];
  if (parameters is String) {
    final match = RegExp(
      r'^\s*num_ctx\s+(\d+)',
      multiLine: true,
    ).firstMatch(parameters);
    numCtx = match == null ? null : int.tryParse(match[1]!);
  }
  int? trained;
  final info = json['model_info'];
  if (info is Map) {
    for (final entry in info.entries) {
      if ('${entry.key}'.endsWith('.context_length')) {
        trained = _positiveInt(entry.value);
        if (trained != null) break;
      }
    }
  }
  final context = numCtx ?? trained;
  return context == null
      ? null
      : LlmLimits(contextTokens: context, from: 'ollama');
}

/// The window in an LM Studio `/api/v0/models/<id>` answer.
LlmLimits? parseLmStudioModel(Object? json) =>
    json is Map ? _modelEntryLimits(json, from: 'lmstudio') : null;

/// Asks [baseUrl]'s server what [model]'s context window and answer limit
/// are, or null when it does not say.
///
/// Read-only GETs (and Ollama's POST `/api/show`, which reads too), tried
/// from the most to the least specific: litellm's `/model/info`, the
/// OpenAI-style `/models` list, Ollama, LM Studio. The first that names the
/// model wins. Each has a short timeout of its own — a server that does not
/// speak one of these answers 404 at once, and one that hangs should not hold
/// up the others — and nothing about the user's chats is sent to any of them.
Future<LlmLimits?> detectLlmLimits({
  required String baseUrl,
  required String model,
  String? apiKey,
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final name = model.trim();
  if (base.isEmpty || name.isEmpty) return null;
  // The server's root, for the APIs that are not under `/v1`.
  final root = base.replaceAll(RegExp(r'/v1$'), '');
  final headers = {
    if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();

  Future<Object?> get(String url) async {
    try {
      final response = await httpClient
          .get(Uri.parse(url), headers: headers)
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on Object catch (error) {
      debugPrint('weft: llm limits: $url: ${error.runtimeType}');
      return null;
    }
  }

  Future<Object?> post(String url, Object body) async {
    try {
      final response = await httpClient
          .post(
            Uri.parse(url),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on Object catch (error) {
      debugPrint('weft: llm limits: $url: ${error.runtimeType}');
      return null;
    }
  }

  try {
    final attempts = <Future<LlmLimits?> Function()>[
      () async => parseLitellmModelInfo(await get('$base/model/info'), name),
      if (root != base)
        () async => parseLitellmModelInfo(await get('$root/model/info'), name),
      () async => parseOpenAiModels(await get('$base/models'), name),
      () async =>
          parseOllamaShow(await post('$root/api/show', {'model': name})),
      () async => parseLmStudioModel(
        await get('$root/api/v0/models/${Uri.encodeComponent(name)}'),
      ),
    ];
    for (final attempt in attempts) {
      final limits = await attempt();
      if (limits != null) {
        debugPrint('weft: llm limits: $limits');
        return limits;
      }
    }
    debugPrint('weft: llm limits: nothing detected');
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}
