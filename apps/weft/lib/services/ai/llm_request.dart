import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'on_device/on_device_client.dart';
import 'on_device/on_device_models.dart' show kOnDeviceLlmBaseUrl;

/// What a chat completion is being asked for, which decides how long it may
/// take.
enum LlmTask {
  /// A quick message the user tapped for and is watching being written.
  quickMessage,

  /// An auto-reply, written in the background while the user is away.
  autoReply,

  /// The to-do assistant's review of a conversation, in the background.
  todo,

  /// A calendar entry's title, asked for on the chip's tap — the rule-made
  /// title stands when it does not come.
  eventTitle,

  /// Facts about a person the model proposes for their note, asked for on a
  /// tap or after a quick message — never waited on by a message.
  personFacts,

  /// A message translated on the user's tap, with them watching a spinner.
  translate,

  /// The endpoints screen's test button.
  probe,
}

/// Hosts of the hosted model APIs people point Sennit at.
///
/// Everything else is read as self-hosted — Ollama, LM Studio, llama.cpp,
/// vLLM, a litellm proxy on the user's own domain — because getting that
/// wrong the other way is the bug this list exists for: a local model on a
/// laptop takes minutes for an answer a hosted one gives in seconds, and a
/// timeout sized for the second gives up on the first every time. A hosted
/// API missing from here only means its failures take longer to report.
const List<String> kHostedLlmDomains = [
  'api.openai.com',
  'openai.azure.com',
  'services.ai.azure.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
  'openrouter.ai',
  'api.groq.com',
  'api.mistral.ai',
  'api.together.xyz',
  'api.together.ai',
  'api.deepseek.com',
  'api.fireworks.ai',
  'api.perplexity.ai',
  'api.x.ai',
  'api.cohere.ai',
  'api.cohere.com',
  'api.deepinfra.com',
  'api.cerebras.ai',
  'router.huggingface.co',
  'api-inference.huggingface.co',
];

/// Whether [baseUrl] is one of the [kHostedLlmDomains], or a subdomain of one.
bool isHostedLlm(String baseUrl) {
  final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return kHostedLlmDomains.any(
    (domain) => host == domain || host.endsWith('.$domain'),
  );
}

/// How long [task] may wait for [baseUrl] to finish answering.
///
/// A hosted API keeps the short limits each feature always had: when one of
/// those has not answered in a minute, it is not going to. A self-hosted one
/// gets minutes — a model loading from disk, or running on a CPU, takes that
/// long for an answer that is still worth having. None of these requests
/// stream, so this is the whole wait: the server says nothing until it is done,
/// and there is no gap between chunks to time instead.
Duration llmResponseTimeout(String baseUrl, LlmTask task) {
  final hosted = isHostedLlm(baseUrl);
  return switch (task) {
    LlmTask.quickMessage ||
    LlmTask.autoReply ||
    LlmTask.translate => hosted ? kHostedReplyTimeout : kSelfHostedReplyTimeout,
    LlmTask.todo =>
      hosted ? const Duration(seconds: 20) : kSelfHostedReplyTimeout,
    // Learning reads far more of the chat than anything else — thousands of
    // tokens on a big window — and a hosted API takes longer for that too.
    LlmTask.personFacts =>
      hosted ? const Duration(seconds: 60) : kSelfHostedReplyTimeout,
    // Someone is looking at a spinner on the chip, and a title is not worth
    // ten minutes of it.
    LlmTask.eventTitle =>
      hosted ? const Duration(seconds: 8) : const Duration(minutes: 2),
    // The first request after a model is chosen is also the one that loads it.
    LlmTask.probe =>
      hosted ? const Duration(seconds: 12) : const Duration(minutes: 3),
  };
}

/// What asks [baseUrl]'s thinking model to answer straight away, for a task
/// too small to reason about and too urgent to wait for it.
///
/// Every server spells it differently and ignores the spellings it does not
/// know, so a self-hosted one is sent both that matter:
/// `reasoning_effort: none` — litellm, Ollama and vLLM — and the chat
/// template's `enable_thinking: false` — llama.cpp, vLLM and the Qwen
/// templates litellm passes it on to. A Qwen behind litellm went from five to
/// twelve seconds of thinking to one or two with these.
///
/// A hosted API gets only `low`: the one effort every reasoning model there
/// accepts — `none` and `minimal` are refused by some — and no template
/// switch, which a strict API refuses as an unknown field. A model that is
/// not a reasoning one refuses `reasoning_effort` outright, which is why
/// [requestCompletion] asks once more without these on a 400.
Map<String, Object?> noThinkingOptions(String baseUrl) => isHostedLlm(baseUrl)
    ? const {'reasoning_effort': 'low'}
    : const {
        'reasoning_effort': 'none',
        'chat_template_kwargs': {'enable_thinking': false},
      };

/// A hosted API's limit for a written message.
const Duration kHostedReplyTimeout = Duration(seconds: 60);

/// A self-hosted model's limit for a written message.
const Duration kSelfHostedReplyTimeout = Duration(minutes: 10);

/// How long reaching the server may take, whatever it then takes to answer.
///
/// Kept short for every endpoint: a server that is down should say so in
/// seconds, not after the minutes a slow model is allowed.
const Duration kLlmConnectTimeout = Duration(seconds: 15);

/// The client an AI request makes for itself when none is given.
///
/// Requests to [kOnDeviceLlmBaseUrl] never reach the network: this client
/// answers them from the model on the phone (see [OnDeviceLlmClient]).
http.Client llmHttpClient() => OnDeviceLlmClient(
  IOClient(HttpClient()..connectionTimeout = kLlmConnectTimeout),
);

/// POSTs [body] to [url], giving up after [timeout] and when [cancel]
/// completes.
///
/// Both abort the request itself rather than only stop waiting for it, so a
/// cancelled quick message does not keep a local model busy for the minutes
/// it was allowed. A timeout throws [TimeoutException], a cancel
/// [http.RequestAbortedException].
Future<http.Response> postLlm(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  required String body,
  required Duration timeout,
  Future<void>? cancel,
}) async {
  final abort = Completer<void>();
  void stop() {
    if (!abort.isCompleted) abort.complete();
  }

  unawaited(cancel?.whenComplete(stop));
  final request = http.AbortableRequest('POST', url, abortTrigger: abort.future)
    ..headers.addAll(headers)
    ..body = body;
  try {
    return await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(timeout);
  } on TimeoutException {
    stop();
    rethrow;
  }
}

/// One chat completion's answer: the HTTP status, the text, and why the model
/// stopped.
class LlmAnswer {
  const LlmAnswer({required this.status, this.content, this.finishReason});

  final int status;

  /// The answer's text, or null when the model gave none — a thinking model
  /// cut off while still reasoning leaves it empty and its reasoning in
  /// `reasoning_content`.
  final String? content;

  /// `stop`, `length`, or whatever the server said; null when it said nothing.
  final String? finishReason;

  bool get ok => status == 200;

  /// Whether the model stopped at `max_tokens` rather than at its answer's
  /// end.
  bool get cutOff => finishReason == 'length';
}

/// Asks [url] for one chat completion of [body] — everything but
/// `max_tokens`, which is [maxTokens] — and reads the answer.
///
/// When the model is cut off at [maxTokens] before it wrote anything
/// [answered] accepts, it is asked once more with [retryMaxTokens], if that is
/// more: a thinking model that spent a short answer's budget on its reasoning
/// usually finishes with room to. The second answer is returned whatever it
/// is, and the caller tells the user it was cut off if it was. [timeout] is
/// per request, so a retry on a slow local model can take as long again.
///
/// [optional] is merged into [body] until the server refuses a request with
/// a 400 or 422 — it is then asked once more, and from then on, without it.
///
/// A timeout throws [TimeoutException] and a cancel
/// [http.RequestAbortedException], as [postLlm] does; anything else that is
/// not JSON throws too.
Future<LlmAnswer> requestCompletion(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  required Map<String, Object?> body,
  required int maxTokens,
  int? retryMaxTokens,
  bool Function(String content)? answered,
  required Duration timeout,
  Future<void>? cancel,
  String what = 'llm',
  Map<String, Object?> optional = const {},
}) async {
  var extra = optional;
  Future<LlmAnswer> ask(int tokens) async {
    Future<http.Response> post() => postLlm(
      client,
      url,
      headers: headers,
      body: jsonEncode({...body, ...extra, 'max_tokens': tokens}),
      timeout: timeout,
      cancel: cancel,
    );
    var response = await post();
    // A server that does not know one of the [optional] fields and says so:
    // the request is worth more than the option.
    if (extra.isNotEmpty &&
        (response.statusCode == 400 || response.statusCode == 422)) {
      debugPrint(
        'weft: $what: ${response.statusCode} with ${extra.keys.join(', ')}, '
        'asking without',
      );
      extra = const {};
      response = await post();
    }
    if (response.statusCode != 200) {
      return LlmAnswer(status: response.statusCode);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choice = (decoded is Map ? decoded['choices'] as List? : null)
        ?.whereType<Map>()
        .firstOrNull;
    final message = choice?['message'];
    return LlmAnswer(
      status: 200,
      content: message is Map ? message['content'] as String? : null,
      finishReason: choice?['finish_reason'] as String?,
    );
  }

  final first = await ask(maxTokens);
  final more = retryMaxTokens ?? maxTokens;
  if (!first.ok || !first.cutOff || more <= maxTokens) return first;
  final content = first.content;
  if (content != null && (answered?.call(content) ?? false)) return first;
  debugPrint('weft: $what: cut off at $maxTokens tokens, asking with $more');
  return ask(more);
}
