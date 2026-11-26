import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'on_device_llm.dart';
import 'on_device_models.dart';
import 'qwen_chat_template.dart';

/// An HTTP client that answers [kOnDeviceLlmHost] from the model on the
/// phone and sends everything else on to [inner].
///
/// This is what lets every AI feature use the on-device model without
/// knowing it exists: they post OpenAI-style chat completions to a base URL,
/// and for [kOnDeviceLlmBaseUrl] the answer comes from [OnDeviceLlm] instead
/// of a server. It speaks the part of that API Sennit uses —
/// `POST /chat/completions`, streamed (`"stream": true`, as server-sent
/// events) or not, and `GET /models`, whose context length is the one the
/// model runs with here, so the limits detection reads it like any other
/// server's. Aborting the request (see [postLlm]) cancels the generation.
class OnDeviceLlmClient extends http.BaseClient {
  OnDeviceLlmClient(this._inner, {OnDeviceLlm? Function()? llm})
    : _llm = llm ?? (() => OnDeviceLlm.instance);

  final http.Client _inner;
  final OnDeviceLlm? Function() _llm;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host.toLowerCase() != kOnDeviceLlmHost) {
      return _inner.send(request);
    }
    final path = request.url.path.replaceAll(RegExp(r'/+$'), '');
    final llm = _llm();
    if (llm == null) {
      return _error(
        request,
        503,
        'The on-device model only runs while Sennit is open.',
      );
    }
    if (request.method == 'GET' && path.endsWith('/models')) {
      return _json(request, 200, _models(llm));
    }
    if (request.method == 'POST' && path.endsWith('/chat/completions')) {
      final body = await request.finalize().bytesToString();
      final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        return _error(request, 400, 'The request is not JSON.');
      }
      if (decoded is! Map) return _error(request, 400, 'Expected an object.');
      return _complete(llm, request, decoded.cast<String, Object?>());
    }
    return _error(request, 404, 'Not found');
  }

  Map<String, Object?> _models(OnDeviceLlm llm) => {
    'object': 'list',
    'data': [
      for (final spec in OnDeviceLlmSpec.all)
        {
          'id': spec.id,
          'object': 'model',
          'owned_by': 'on-device',
          // The most this phone can hold, not what the user picked: the
          // budgets take the smaller of the two, so a later, smaller choice
          // is not capped by an old detection.
          'context_length': llm.contextCapFor(spec),
        },
    ],
  };

  Future<http.StreamedResponse> _complete(
    OnDeviceLlm llm,
    http.BaseRequest request,
    Map<String, Object?> body,
  ) async {
    final model = body['model'] as String? ?? '';
    final messages = ChatTurn.listFrom(body['messages']);
    if (messages.isEmpty) return _error(request, 400, 'No messages.');
    final maxTokens =
        _int(body['max_tokens']) ??
        _int(body['max_completion_tokens']) ??
        kOnDeviceAnswerTokens;
    final stream = body['stream'] == true;
    final abort = request is http.Abortable ? request.abortTrigger : null;

    if (!stream) {
      try {
        final answer = await llm.complete(
          modelId: model,
          messages: messages,
          maxTokens: maxTokens,
          thinking: wantsThinking(body),
          temperature: _double(body['temperature']) ?? 0.5,
          topP: _double(body['top_p']) ?? 0.9,
          cancel: abort,
        );
        return _json(request, 200, _completion(model, answer));
      } on OnDeviceCancelled {
        throw http.RequestAbortedException(request.url);
      } on OnDeviceLlmException catch (error) {
        return _failure(request, error);
      }
    }

    // Streamed: the answer goes out as it is written, one event per piece,
    // the way an OpenAI server sends it.
    final events = StreamController<List<int>>();
    final id = 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}';
    void send(Map<String, Object?> chunk) =>
        events.add(utf8.encode('data: ${jsonEncode(chunk)}\n\n'));
    Map<String, Object?> chunk(Map<String, Object?> delta, String? finish) => {
      'id': id,
      'object': 'chat.completion.chunk',
      'model': model,
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };
    final stopped = Completer<void>();
    if (abort != null) unawaited(abort.whenComplete(stopped.complete));
    events.onCancel = () {
      if (!stopped.isCompleted) stopped.complete();
    };
    final answer = llm.complete(
      modelId: model,
      messages: messages,
      maxTokens: maxTokens,
      thinking: wantsThinking(body),
      temperature: _double(body['temperature']) ?? 0.5,
      topP: _double(body['top_p']) ?? 0.9,
      cancel: stopped.future,
      onText: (text) => send(chunk({'content': text}, null)),
    );
    send(chunk({'role': 'assistant'}, null));
    unawaited(
      answer
          .then((done) {
            send(chunk(const {}, done.finishReason));
            events.add(utf8.encode('data: [DONE]\n\n'));
          })
          .catchError((Object error) {
            if (error is OnDeviceCancelled) {
              events.addError(http.RequestAbortedException(request.url));
            } else {
              events.addError(http.ClientException('$error', request.url));
            }
          })
          .whenComplete(events.close),
    );
    return http.StreamedResponse(
      events.stream,
      200,
      request: request,
      headers: const {'content-type': 'text/event-stream'},
    );
  }

  Map<String, Object?> _completion(String model, OnDeviceAnswer answer) => {
    'id': 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}',
    'object': 'chat.completion',
    'model': model,
    'choices': [
      {
        'index': 0,
        'message': {'role': 'assistant', 'content': answer.text},
        'finish_reason': answer.finishReason,
      },
    ],
    'usage': {
      'prompt_tokens': answer.promptTokens,
      'completion_tokens': answer.completionTokens,
      'total_tokens': answer.promptTokens + answer.completionTokens,
    },
    // llama-server's spelling, for anyone reading the speed.
    'timings': {
      'prompt_n': answer.promptTokens,
      'prompt_ms': answer.firstTokenTime.inMicroseconds / 1000,
      'predicted_n': answer.completionTokens,
      'predicted_ms': answer.totalTime.inMicroseconds / 1000,
      'predicted_per_second': answer.tokensPerSecond,
    },
  };

  http.StreamedResponse _failure(
    http.BaseRequest request,
    OnDeviceLlmException error,
  ) => switch (error.failure) {
    OnDeviceFailure.unknownModel ||
    OnDeviceFailure.notInstalled => _error(request, 404, '$error'),
    // What a server says for a prompt past its window; the features treat a
    // 400 as "ask without the optional fields", and then as a failure.
    OnDeviceFailure.promptTooLong => _error(request, 400, '$error'),
    OnDeviceFailure.loadFailed ||
    OnDeviceFailure.generationFailed => _error(request, 503, '$error'),
  };

  http.StreamedResponse _json(
    http.BaseRequest request,
    int status,
    Object body,
  ) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    status,
    request: request,
    headers: const {'content-type': 'application/json'},
  );

  http.StreamedResponse _error(
    http.BaseRequest request,
    int status,
    String message,
  ) => _json(request, status, {
    'error': {'message': message, 'type': 'on_device'},
  });

  @override
  void close() => _inner.close();
}

/// Whether [body] asks the model to think before it answers.
///
/// Only when it says so — `chat_template_kwargs.enable_thinking: true`. A
/// phone has no seconds to spare for reasoning about a chat reply, so no
/// word on it, like `enable_thinking: false` and `reasoning_effort: none`,
/// means no thinking.
bool wantsThinking(Map<String, Object?> body) {
  final kwargs = body['chat_template_kwargs'];
  return kwargs is Map && kwargs['enable_thinking'] == true;
}

int? _int(Object? value) => value is num ? value.toInt() : null;

double? _double(Object? value) => value is num ? value.toDouble() : null;
