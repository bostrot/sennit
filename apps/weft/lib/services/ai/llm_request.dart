import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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
    LlmTask.autoReply => hosted ? kHostedReplyTimeout : kSelfHostedReplyTimeout,
    LlmTask.todo =>
      hosted ? const Duration(seconds: 20) : kSelfHostedReplyTimeout,
    // Someone is looking at a spinner on the chip, and a title is not worth
    // ten minutes of it.
    LlmTask.eventTitle =>
      hosted ? const Duration(seconds: 8) : const Duration(minutes: 2),
    // The first request after a model is chosen is also the one that loads it.
    LlmTask.probe =>
      hosted ? const Duration(seconds: 12) : const Duration(minutes: 3),
  };
}

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
http.Client llmHttpClient() =>
    IOClient(HttpClient()..connectionTimeout = kLlmConnectTimeout);

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
