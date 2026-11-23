import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai/llm_budget.dart';
import '../ai/llm_request.dart';
import '../ai/person_memory.dart' show AiMemory, memoryPromptBlock;
import 'todo_item.dart';

/// How many new entries one conversation may add at once.
///
/// Three, because a real message rarely asks for more and a model that
/// returns ten has misread a shopping list as a to-do list — the cap keeps one
/// bad answer from burying the entries the user actually cares about.
const int kTodoMaxAddsPerAnswer = 3;

/// The longest title the list accepts from the model.
const int kTodoMaxTitleLength = 120;

/// An entry the assistant wants on the list.
@immutable
class TodoProposal {
  const TodoProposal({required this.title, this.due});

  final String title;
  final DateTime? due;
}

/// What the assistant wants changed after reading a conversation.
@immutable
class TodoChanges {
  const TodoChanges({this.add = const [], this.complete = const {}});

  static const none = TodoChanges();

  final List<TodoProposal> add;

  /// Ids of open entries the conversation says are finished.
  final Set<String> complete;

  bool get isEmpty => add.isEmpty && complete.isEmpty;
}

/// [proposeTodoChanges]'s shape, so a test can supply a model that answers
/// instantly.
typedef TodoProposer =
    Future<TodoChanges?> Function({
      required String baseUrl,
      required String model,
      String? apiKey,
      required String chatTitle,
      required List<String> transcript,
      required List<TodoItem> open,
      required DateTime today,
      LlmBudget? budget,
      AiMemory? memory,
    });

/// Asks the user's model what the conversation adds to, or ticks off, the
/// to-do list.
///
/// The same OpenAI-compatible endpoint the reply chips and auto-replies use.
/// The model is shown the conversation and the entries still open *for that
/// conversation*, numbered — small local models copy a number back far more
/// reliably than an id. [memory] — what the user noted and Sennit learned about
/// the chat and its people — goes at the end of the system message, so a
/// title names "Mia's birthday present" rather than "the present". Null on any
/// failure: the list is a convenience, and a model that is down must never
/// surface as an error in the chat.
Future<TodoChanges?> proposeTodoChanges({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String chatTitle,
  required List<String> transcript,
  required List<TodoItem> open,
  required DateTime today,
  LlmBudget? budget,
  AiMemory? memory,
  http.Client? client,
  Duration? timeout,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) return null;
  final limits = budget ?? LlmBudget.resolve(base);
  final room = limits.forFeature(AiFeature.todo);
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  try {
    final answer = await requestCompletion(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: {
        'model': model,
        'temperature': 0.2,
        'messages': [
          {
            'role': 'system',
            'content':
                '$todoSystemPrompt'
                '${memoryPromptBlock(memory, baseUrl: base, budget: limits, feature: AiFeature.todo)}',
          },
          // One worked example, for the same reason the reply chips carry
          // one: it pins the format better than any instruction does.
          {
            'role': 'user',
            'content': todoUserPrompt(
              chatTitle: 'Anna',
              transcript: const [
                'Anna: Kannst du morgen die Fotos von Samstag schicken?',
                'You: Klar, mache ich',
                'Anna: Und das Buch hast du ja schon zurückgebracht, danke!',
              ],
              open: const ['Buch an Anna zurückgeben'],
              today: DateTime(2026, 5, 4),
            ),
          },
          {
            'role': 'assistant',
            'content':
                '{"add": [{"title": "Fotos von Samstag an Anna schicken", '
                '"due": "2026-05-05"}], "done": [1]}',
          },
          {
            'role': 'user',
            'content': todoUserPrompt(
              chatTitle: chatTitle,
              transcript: transcript,
              open: [for (final item in open) item.title],
              today: today,
            ),
          },
        ],
      },
      maxTokens: room.maxTokens,
      retryMaxTokens: room.retryMaxTokens,
      // An object closed after any reasoning is an answer, even an empty one.
      answered: (content) => content
          .replaceAll(
            RegExp(r'<think>[\s\S]*?(</think>|$)', caseSensitive: false),
            '',
          )
          .contains('}'),
      timeout: timeout ?? llmResponseTimeout(base, LlmTask.todo),
      what: 'to-do',
    );
    if (!answer.ok) {
      debugPrint('weft: to-do: $url answered ${answer.status}');
      return null;
    }
    final content = answer.content;
    if (content == null) return null;
    return parseTodoChanges(content, open: open);
  } on Object catch (error) {
    debugPrint('weft: to-do against $url failed: $error');
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

@visibleForTesting
const String todoSystemPrompt =
    'You keep the user\'s personal to-do list from their chats. Read the '
    'conversation and decide two things. First: does it give the user '
    '("You") something they have to do — something they were asked to do and '
    'did not refuse, something they promised, or something they must not '
    'forget? Second: does it show that one of the open to-dos is finished? '
    'Never add a task for the other person, a plan nobody committed to, small '
    'talk, or anything already on the list. Write each title as a short '
    'imperative phrase of at most ten words in the language of the '
    'conversation, naming who it is for when that matters. Give "due" as '
    'YYYY-MM-DD only when the conversation names a day, otherwise null. '
    'Output ONLY a JSON object {"add": [{"title": ..., "due": ...}], '
    '"done": [numbers of finished open to-dos]} — no commentary, no '
    'markdown. When nothing changes, output {"add": [], "done": []}.';

@visibleForTesting
String todoUserPrompt({
  required String chatTitle,
  required List<String> transcript,
  required List<String> open,
  required DateTime today,
}) {
  final buffer = StringBuffer()
    ..writeln('Today is ${formatTodoDate(today)}.')
    ..writeln('Chat: $chatTitle')
    ..writeln('Open to-dos from this chat:');
  if (open.isEmpty) buffer.writeln('(none)');
  for (var i = 0; i < open.length; i++) {
    buffer.writeln('${i + 1}. ${open[i]}');
  }
  buffer
    ..writeln()
    ..writeln('Conversation (newest message last):')
    ..writeln(transcript.join('\n'))
    ..writeln()
    ..write('JSON:');
  return buffer.toString();
}

/// Reads the model's answer into changes, keeping only what is usable.
///
/// Numbers in `done` are 1-based positions in [open]; anything out of range is
/// dropped. A title already open, in any letter case, is not added twice. An
/// answer that is not JSON at all is [TodoChanges.none] — a list the model
/// filled with its own reasoning is worse than a list it left alone.
TodoChanges parseTodoChanges(String content, {List<TodoItem> open = const []}) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) {
    return TodoChanges.none;
  }
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return TodoChanges.none;
  final Object? parsed;
  try {
    parsed = jsonDecode(text.substring(start, end + 1));
  } on FormatException {
    return TodoChanges.none;
  }
  if (parsed is! Map) return TodoChanges.none;

  final known = {for (final item in open) _normalise(item.title)};
  final add = <TodoProposal>[];
  final rawAdd = parsed['add'];
  if (rawAdd is List) {
    for (final entry in rawAdd) {
      // Some models write the bare title rather than an object.
      final title = switch (entry) {
        String() => entry,
        Map() when entry['title'] is String => entry['title'] as String,
        _ => null,
      }?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title == null || title.isEmpty) continue;
      if (title.length > kTodoMaxTitleLength) continue;
      if (!known.add(_normalise(title))) continue;
      final due = entry is Map && entry['due'] is String
          ? parseTodoDate(entry['due'] as String)
          : null;
      add.add(TodoProposal(title: title, due: due));
      if (add.length == kTodoMaxAddsPerAnswer) break;
    }
  }

  final complete = <String>{};
  final rawDone = parsed['done'];
  if (rawDone is List) {
    for (final entry in rawDone) {
      final index = switch (entry) {
        int() => entry,
        String() => int.tryParse(entry.trim()),
        _ => null,
      };
      if (index == null || index < 1 || index > open.length) continue;
      complete.add(open[index - 1].id);
    }
  }

  return TodoChanges(add: add, complete: complete);
}

String _normalise(String title) => title.toLowerCase().replaceAll(
  RegExp(r'[^\p{L}\p{N}]+', unicode: true),
  '',
);

/// Whether [text] might add to or finish a to-do — the cheap gate in front of
/// the model.
///
/// Without it every message in every chat would be a completion, which is
/// slow on a local model and a disclosure on a hosted one. The phrases are the
/// ways people ask, promise and report back in the six languages the app
/// ships, matched as substrings of the lower-cased text. A miss costs one
/// to-do the user can still add by hand; a false hit costs one completion that
/// answers "nothing changes".
bool mightConcernTodo(String text) {
  final lower = text.toLowerCase();
  if (lower.trim().isEmpty) return false;
  return _todoCues.any(lower.contains);
}

const _todoCues = [
  // English
  'can you', 'could you', 'would you', 'please', 'pls', 'plz',
  "don't forget", 'dont forget', 'remember to', 'remind', 'need to',
  'have to', 'must ', 'to do', 'todo', 'to-do', "i'll ", 'i will',
  'let me ', 'deadline', 'by tomorrow', 'pick up', 'buy ', 'bring',
  'send me', 'call me', 'done', 'finished', 'sent it', 'took care',
  // German
  'kannst du', 'könntest du', 'würdest du', 'bitte', 'vergiss nicht',
  'denk dran', 'denk daran', 'erinner', 'muss', 'sollst', 'ich mach',
  'ich schick', 'ich kümmer', 'bis morgen', 'kauf', 'bring', 'schick',
  'erledigt', 'fertig', 'gemacht', 'geschickt',
  // Spanish
  'puedes', 'podrías', 'podrias', 'por favor', 'no olvides', 'recuerda',
  'tienes que', 'tengo que', 'compra', 'trae', 'envía', 'envia', 'hecho',
  'listo',
  // French
  'peux-tu', 'pourrais-tu', 'tu peux', "s'il te pla", 'stp', 'svp',
  "n'oublie pas", 'rappelle', 'il faut', 'je dois', 'tu dois', 'achète',
  'achete', 'apporte', 'envoie', "c'est fait", 'terminé',
  // Portuguese
  'pode ', 'podes', 'não esquece', 'nao esquece', 'lembra', 'tem que',
  'tenho que', 'preciso', 'traz', 'manda', 'feito', 'pronto',
  // Chinese
  '能不能', '可以帮', '帮我', '麻烦', '别忘了', '记得', '提醒', '需要', '完成',
  '搞定', '办好',
];
