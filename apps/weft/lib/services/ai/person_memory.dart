import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';

import 'llm_request.dart';

/// What the user has noted for the AI features, in two layers, and the facts
/// the model has offered to add, waiting for a yes or a no.
///
/// * **Chat memory** — detailed, one per conversation, groups included: what
///   is going on, plans, the tone used *in this chat*, the in-jokes. Filed
///   under the chat's rooms, `room:<id>` (see [chatMemoryKeys]). What the
///   model proposes lands here.
/// * **Person memory** — a few lines per person, used in every chat they are
///   in: what they like to be called, relationship, birthday, du or Sie,
///   language, the facts that matter everywhere. Filed under the person's
///   network handles, `handle:<id>`, or `dm:<room>` / `user:<mxid>` for a
///   person Sennit has no handle for (see [personMemoryKeys]).
///
/// One book for both, keyed by those prefixes, because the operations are the
/// same and so is where it is kept. A person is whatever set of handles Sennit
/// has merged into one contact, so a note written while Anna's WhatsApp and
/// Signal were two chats is found under both once they are merged, and stays
/// on each if they are split again. [noteFor] joins what the keys hold, and
/// [withNote] writes the one note back to every key — which is how two notes
/// for one person become one the first time it is edited.
///
/// Stored as one blob in the keychain (`SecretStore.personMemory`), never in
/// the database beside the messages, and never in a log: the `toString` says
/// how many, not what.
@immutable
class MemoryBook {
  const MemoryBook({
    this.notes = const {},
    this.suggestions = const {},
    this.dismissed = const {},
  });

  static const MemoryBook empty = MemoryBook();

  /// The note under each key, Markdown as the user typed it.
  final Map<String, String> notes;

  /// Facts the model proposed and the user has not answered yet.
  final Map<String, List<String>> suggestions;

  /// Facts the user said no to, so the model is not let offer them again.
  /// Bounded per key by [kPersonMemoryDismissedLimit].
  final Map<String, List<String>> dismissed;

  /// The note for a person filed under [keys]: the distinct notes the keys
  /// hold, in key order, joined by a blank line. Empty when there is none.
  String noteFor(Iterable<String> keys) {
    final seen = <String>{};
    final parts = <String>[];
    for (final key in keys) {
      final note = notes[key]?.trim() ?? '';
      if (note.isNotEmpty && seen.add(note)) parts.add(note);
    }
    return parts.join('\n\n');
  }

  /// The facts waiting for an answer for [keys], without duplicates.
  List<String> suggestionsFor(Iterable<String> keys) =>
      _union(suggestions, keys);

  List<String> _dismissedFor(Iterable<String> keys) => _union(dismissed, keys);

  static List<String> _union(
    Map<String, List<String>> map,
    Iterable<String> keys,
  ) {
    final seen = <String>{};
    return [
      for (final key in keys)
        for (final fact in map[key] ?? const <String>[])
          if (seen.add(factKey(fact))) fact,
    ];
  }

  /// [note] as the note for every one of [keys]. An empty note removes it.
  MemoryBook withNote(Iterable<String> keys, String note) {
    final text = note.trim();
    return _copy(
      notes: {...notes, for (final key in keys) key: text}
        ..removeWhere((_, v) => v.isEmpty),
    );
  }

  /// Adds what the model [proposed] to the facts waiting for [keys] — minus
  /// anything already in the note, already waiting, or once dismissed. See
  /// [mergeFactSuggestions].
  MemoryBook withProposals(Iterable<String> keys, List<String> proposed) {
    final keyList = keys.toList();
    if (keyList.isEmpty) return this;
    final merged = mergeFactSuggestions(
      note: noteFor(keyList),
      pending: suggestionsFor(keyList),
      dismissed: _dismissedFor(keyList),
      proposed: proposed,
    );
    return _copy(suggestions: _setAll(suggestions, keyList, merged));
  }

  /// [fact] written into the note as a bullet, and no longer waiting.
  MemoryBook accept(Iterable<String> keys, String fact) {
    final keyList = keys.toList();
    final note = noteFor(keyList);
    final line = '- ${fact.trim()}';
    final next = withNote(keyList, note.isEmpty ? line : '$note\n$line');
    return next._copy(
      suggestions: _setAll(next.suggestions, keyList, [
        for (final s in next.suggestionsFor(keyList))
          if (factKey(s) != factKey(fact)) s,
      ]),
    );
  }

  /// [fact] written into the person memory under [personKeys] instead of the
  /// chat's, and no longer waiting under [chatKeys] — "Add to profile".
  MemoryBook promote(
    Iterable<String> chatKeys,
    Iterable<String> personKeys,
    String fact,
  ) {
    final chatList = chatKeys.toList();
    final personList = personKeys.toList();
    final note = noteFor(personList);
    final line = '- ${fact.trim()}';
    final next = withNote(personList, note.isEmpty ? line : '$note\n$line');
    return next._copy(
      suggestions: _setAll(next.suggestions, chatList, [
        for (final s in next.suggestionsFor(chatList))
          if (factKey(s) != factKey(fact)) s,
      ]),
    );
  }

  /// [fact] no longer waiting, and remembered as unwanted.
  MemoryBook dismiss(Iterable<String> keys, String fact) {
    final keyList = keys.toList();
    final no = [..._dismissedFor(keyList), fact];
    return _copy(
      suggestions: _setAll(suggestions, keyList, [
        for (final s in suggestionsFor(keyList))
          if (factKey(s) != factKey(fact)) s,
      ]),
      dismissed: _setAll(
        dismissed,
        keyList,
        no.length > kPersonMemoryDismissedLimit
            ? no.sublist(no.length - kPersonMemoryDismissedLimit)
            : no,
      ),
    );
  }

  /// Everything about the person filed under [keys] gone: note, waiting facts
  /// and dismissals.
  MemoryBook forget(Iterable<String> keys) {
    final keySet = keys.toSet();
    bool drop(String key, Object? _) => keySet.contains(key);
    return MemoryBook(
      notes: {...notes}..removeWhere(drop),
      suggestions: {...suggestions}..removeWhere(drop),
      dismissed: {...dismissed}..removeWhere(drop),
    );
  }

  /// [other]'s notes added under the keys this book has none for — the restore
  /// rule every table in a backup follows: what is here wins.
  MemoryBook mergedWith(MemoryBook other) =>
      _copy(notes: {...other.notes, ...notes});

  bool get isEmpty => notes.isEmpty && suggestions.isEmpty && dismissed.isEmpty;

  static Map<String, List<String>> _setAll(
    Map<String, List<String>> map,
    List<String> keys,
    List<String> value,
  ) =>
      {...map, for (final key in keys) key: List.unmodifiable(value)}
        ..removeWhere((_, v) => v.isEmpty);

  MemoryBook _copy({
    Map<String, String>? notes,
    Map<String, List<String>>? suggestions,
    Map<String, List<String>>? dismissed,
  }) => MemoryBook(
    notes: notes ?? this.notes,
    suggestions: suggestions ?? this.suggestions,
    dismissed: dismissed ?? this.dismissed,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'notes': notes,
    if (suggestions.isNotEmpty) 'suggestions': suggestions,
    if (dismissed.isNotEmpty) 'dismissed': dismissed,
  };

  /// Never throws: anything unreadable is dropped, the rest kept.
  static MemoryBook fromJson(Object? json) {
    if (json is! Map) return empty;
    Map<String, String> strings(Object? raw) => {
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is String && value.trim().isNotEmpty)
            key: value,
    };
    Map<String, List<String>> lists(Object? raw) => {
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is List)
            key: List.unmodifiable(value.whereType<String>()),
    }..removeWhere((_, v) => v.isEmpty);
    return MemoryBook(
      notes: strings(json['notes']),
      suggestions: lists(json['suggestions']),
      dismissed: lists(json['dismissed']),
    );
  }

  /// The blob in the keychain, or [empty] for none or for one that is not
  /// JSON.
  static MemoryBook decode(String? blob) {
    if (blob == null || blob.isEmpty) return empty;
    try {
      return fromJson(jsonDecode(blob));
    } on FormatException {
      return empty;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  String toString() =>
      'MemoryBook(${notes.length} notes, '
      '${suggestions.length} with suggestions)';
}

/// The keys [MemoryBook] files [chat]'s own memory under: one per room the
/// chat is made of, so a merged chat finds what was written while its rooms
/// were separate chats, and each keeps it if they are split again.
List<String> chatMemoryKeys(Chat chat) => [
  for (final s in chat.sources) 'room:${s.roomId}',
];

/// The keys [MemoryBook] files the person [chat] is with under, or none for a
/// group — a group's people are found one by one, by [personKeysForSender].
///
/// [handles] are the handles of the chat's contact, every network the person
/// is merged across; their ids are the keys, because a handle id outlives the
/// contact id a merge or an unmerge mints. A direct chat with no handle — a
/// plain Matrix DM the identity graph has not met — is filed under its rooms,
/// with a prefix of its own so the person's memory is not the chat's.
List<String> personMemoryKeys({
  required Chat chat,
  required List<NetworkHandle> handles,
}) {
  if (chat.isGroup) return const [];
  if (handles.isNotEmpty) {
    return [for (final h in handles) 'handle:${h.id}'];
  }
  return [for (final s in chat.sources) 'dm:${s.roomId}'];
}

/// The keys a group member who wrote as [senderId] is filed under: their
/// contact's handles when Sennit knows the ghost, else the Matrix id itself.
///
/// [handlesOf] answers "every handle of the contact this Matrix user belongs
/// to", empty for a sender the identity graph has not met.
List<String> personKeysForSender(
  String senderId,
  List<NetworkHandle> Function(String matrixUserId) handlesOf,
) {
  final handles = handlesOf(senderId);
  if (handles.isNotEmpty) return [for (final h in handles) 'handle:${h.id}'];
  return ['user:$senderId'];
}

/// A person whose memory may go into a prompt: the name the model is told,
/// and the keys their note is filed under.
typedef MemoryPerson = ({String name, List<String> keys});

/// What the AI features are told about a conversation: the chat's own note
/// and the short notes of the people in it, most relevant first.
@immutable
class AiMemory {
  const AiMemory({this.chat = '', this.people = const []});

  /// The chat memory, untrimmed.
  final String chat;

  /// `(name, note)` per person, untrimmed, in the order they matter — for a
  /// group, the most recent speaker first.
  final List<({String name, String note})> people;

  bool get isEmpty =>
      chat.trim().isEmpty && people.every((p) => p.note.trim().isEmpty);

  @override
  String toString() =>
      'AiMemory(chat: ${chat.length} chars, ${people.length} people)';
}

/// The most of one person's note a prompt carries, for a hosted model.
const int kPersonMemoryHostedChars = 400;

/// The same for a self-hosted one.
const int kPersonMemoryLocalChars = 160;

/// The person memory a user is nudged to stay under in the editor: a few
/// lines. Not enforced — the prompt trims to [kPersonMemoryHostedChars] — but
/// past it the "condense" action is offered.
const int kPersonMemorySoftLimit = 300;

/// The most of everything [memoryPromptBlock] sends, for a hosted model — about
/// three hundred tokens.
const int kAiMemoryHostedChars = 1200;

/// The same for a self-hosted one — about a hundred tokens. A phone-sized
/// model reads every token of the prompt before it writes one, and a long
/// note costs seconds there that it costs nothing on an API.
const int kAiMemoryLocalChars = 400;

/// How many dismissed facts are remembered per person; older ones may be
/// offered again, which after fifty refusals is a fair thing to forget.
const int kPersonMemoryDismissedLimit = 50;

/// The shape two facts are compared in: case, punctuation and a leading
/// bullet do not make "Has two kids." new beside "- has two kids".
String factKey(String fact) => fact
    .toLowerCase()
    .replaceAll(RegExp(r'^\s*[-*•]\s*'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// What is left of [proposed] to offer: each fact once, at most
/// [kPersonMemoryMaxSuggestions] waiting in all, and none the [note] already
/// says, that is already [pending], or that the user once [dismissed].
///
/// "Already says" is a line of the note containing the fact, compared through
/// [factKey] — so "Has two kids" is not offered under a note that reads
/// "- has two kids: Mia and Ben". Crude, and the direction it errs in is
/// offering something nearly said, which costs a tap.
List<String> mergeFactSuggestions({
  required String note,
  required List<String> pending,
  required List<String> dismissed,
  required List<String> proposed,
}) {
  final noteLines = [
    for (final line in note.split('\n'))
      if (factKey(line).isNotEmpty) factKey(line),
  ];
  final known = {
    for (final f in [...pending, ...dismissed]) factKey(f),
  };
  final result = [...pending];
  for (final raw in proposed) {
    if (result.length >= kPersonMemoryMaxSuggestions) break;
    final fact = raw.trim();
    final key = factKey(fact);
    if (key.isEmpty || !known.add(key)) continue;
    if (noteLines.any((line) => line.contains(key))) continue;
    result.add(fact);
  }
  return result;
}

/// How many facts may wait for an answer per person.
const int kPersonMemoryMaxSuggestions = 8;

/// [note] made ready for a prompt: comments, headings with nothing under them
/// and runs of blank lines gone, then cut at a whole line to [maxChars].
///
/// The headings are what the editor suggests as a starting point, and a model
/// sent "## Birthday" with nothing after it reads it as something to fill in.
/// Cut from the end because the user writes what matters first, the way the
/// editor's hint lays it out; a first line longer than the whole budget is
/// cut at a word and marked.
String trimPersonMemory(String note, {required int maxChars}) {
  final text = note.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final lines = [for (final l in text.split('\n')) l.trimRight()];
  bool isHeading(String l) => RegExp(r'^\s*#{1,6}\s').hasMatch(l);
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (isHeading(line)) {
      // Kept only when something that is not another heading follows before
      // the next one.
      final next = lines
          .skip(i + 1)
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (next.isEmpty || isHeading(next)) continue;
    }
    if (line.trim().isEmpty && (kept.isEmpty || kept.last.isEmpty)) continue;
    kept.add(line.trim().isEmpty ? '' : line);
  }
  while (kept.isNotEmpty && kept.last.isEmpty) {
    kept.removeLast();
  }

  final out = StringBuffer();
  for (final line in kept) {
    final extra = (out.isEmpty ? 0 : 1) + line.length;
    if (out.length + extra <= maxChars) {
      if (out.isNotEmpty) out.write('\n');
      out.write(line);
      continue;
    }
    if (out.isEmpty) {
      final cut = line.substring(0, maxChars - 1).lastIndexOf(' ');
      out.write('${line.substring(0, cut > 0 ? cut : maxChars - 1)}…');
    }
    break;
  }
  // A heading left last by the cut has nothing under it any more.
  final result = out.toString().split('\n');
  while (result.isNotEmpty &&
      (result.last.trim().isEmpty || isHeading(result.last))) {
    result.removeLast();
  }
  return result.join('\n');
}

/// The whole budget [memoryPromptBlock] has for [baseUrl].
int aiMemoryBudget(String baseUrl) =>
    isHostedLlm(baseUrl) ? kAiMemoryHostedChars : kAiMemoryLocalChars;

/// The paragraph the system message of a quick message, an auto-reply or the
/// reply chips ends with, or nothing when there is nothing to send.
///
/// One wording for every feature, for the reason `calendarPromptBlock` is
/// shared. The people come first and get at most half of
/// [aiMemoryBudget] between them, each cut to [kPersonMemoryHostedChars] (or
/// the local figure) — in a group the list is in order of who spoke last, and
/// whoever does not fit is left out rather than everyone cut to nothing. The
/// chat memory gets what is left, which is at least the other half.
///
/// "Never quote" is there because a model handed a list of facts likes to
/// show it read them — "Happy birthday, and say hi to Mia and Ben, your two
/// kids!" — and a note is there to set the tone, not to be recited.
String memoryPromptBlock(AiMemory? memory, {required String baseUrl}) {
  if (memory == null || memory.isEmpty) return '';
  final hosted = isHostedLlm(baseUrl);
  final budget = aiMemoryBudget(baseUrl);
  final personCap = hosted ? kPersonMemoryHostedChars : kPersonMemoryLocalChars;

  final people = <String>[];
  var used = 0;
  for (final person in memory.people) {
    final note = trimPersonMemory(person.note, maxChars: personCap);
    if (note.isEmpty) continue;
    final entry = 'About ${person.name}:\n$note';
    if (used + entry.length > budget ~/ 2) {
      if (people.isEmpty) continue;
      break;
    }
    people.add(entry);
    used += entry.length + 2;
  }
  const chatHeading = 'About this chat:\n';
  final chat = trimPersonMemory(
    memory.chat,
    maxChars: budget - used - chatHeading.length,
  );
  if (people.isEmpty && chat.isEmpty) return '';

  return '\n\nWhat the user has noted (private; use it for the names to '
      'call people, the language, the tone — formal or informal, emojis or '
      'not — and what matters to them; never quote it and never mention that '
      'there are notes):\n'
      '${[...people, if (chat.isNotEmpty) '$chatHeading$chat'].join('\n\n')}';
}

/// The completion budget for proposing facts: a short JSON list.
const int kPersonFactsMaxTokens = 400;

/// The chat completion messages that ask for facts worth remembering from the
/// conversation [chatTitle].
///
/// Separate from [suggestPersonFacts] so the prompt can be tested without an
/// endpoint. [known] is what is already noted — the chat's memory and its
/// people's, trimmed like everywhere else — so the model can leave it out. In a
/// group every fact names the person it is about, which is what lets the user
/// add it to that person's memory.
List<Map<String, String>> personFactsRequest({
  required List<String> transcript,
  required String chatTitle,
  required bool isGroup,
  String? known,
}) => [
  {
    'role': 'system',
    'content':
        'You help the user remember things about a chat and the people in '
        'it. From the conversation, list facts that would still be worth '
        'knowing in a month: what someone likes to be called, family and '
        'partner names, birthdays, the language and tone used (du or Sie, '
        'emojis or not), likes and dislikes, plans, ongoing topics, running '
        'jokes. Only what the messages say plainly — no guesses, nothing '
        'about the user ("You"), nothing that only matters today. '
        '${isGroup ? 'Start every fact with the name of the person it is about. ' : ''}'
        'Each fact is one short sentence in the language of the '
        'conversation. Output ONLY a JSON object with a "facts" list — an '
        'empty list when there is nothing worth keeping.',
  },
  {
    'role': 'user',
    'content':
        'Conversation "Lea" (newest message last):\n'
        'Lea: Mia hat am 12. März Geburtstag, sie wird 5!\n'
        'You: Wie schnell die Zeit vergeht\n'
        'Lea: Ja 🙈 Ich bin übrigens ab Montag im neuen Job bei der Bahn\n\n'
        'Already noted:\n(nothing)\n\nJSON:',
  },
  {
    'role': 'assistant',
    'content':
        '{"facts": ["Tochter Mia, Geburtstag am 12. März", '
        '"Arbeitet seit Kurzem bei der Bahn", "Schreibt locker, mit Emojis"]}',
  },
  {
    'role': 'user',
    'content':
        'Conversation "$chatTitle" (newest message last):\n'
        '${transcript.join('\n')}\n\n'
        'Already noted:\n'
        '${known == null || known.trim().isEmpty ? '(nothing)' : known.trim()}'
        '\n\nJSON:',
  },
];

/// Asks the configured LLM what is worth remembering from a conversation.
///
/// The answer is only ever a proposal: it is merged into the facts waiting for
/// the user by `MemoryBook.withProposals`, never into a note. An empty list on
/// any failure — the user asked for suggestions, and "none" is an answer they
/// can live with; the caller learns which it was through [onError].
Future<List<String>> suggestPersonFacts({
  required String baseUrl,
  required String model,
  String? apiKey,
  required List<String> transcript,
  required String chatTitle,
  bool isGroup = false,
  AiMemory? known,
  http.Client? client,
  Duration? timeout,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) {
    return const [];
  }
  final content = await _complete(
    base: base,
    model: model,
    apiKey: apiKey,
    what: 'person facts',
    temperature: 0.2,
    maxTokens: kPersonFactsMaxTokens,
    messages: personFactsRequest(
      transcript: transcript,
      chatTitle: chatTitle,
      isGroup: isGroup,
      known: memoryPromptBlock(known, baseUrl: base).trim(),
    ),
    timeout: timeout ?? llmResponseTimeout(base, LlmTask.personFacts),
    client: client,
    cancel: cancel,
    onError: onError,
  );
  final facts = content == null ? const <String>[] : parsePersonFacts(content);
  debugPrint('weft: person facts: ${facts.length} proposed');
  return facts;
}

/// The chat completion messages that ask for [note] about [name] cut down to
/// a few lines.
List<Map<String, String>> condenseRequest({
  required String name,
  required String note,
}) => [
  {
    'role': 'system',
    'content':
        'You shorten the notes a user keeps about a person, for use in every '
        'chat with them. Keep only what matters in any conversation: what '
        'they like to be called, relationship, birthday, du or Sie, language, '
        'the few facts that matter most. Drop plans, topics and details that '
        'only matter in one chat. At most five short lines, as a Markdown '
        'list, in the language of the notes. Never add anything the notes do '
        'not say. Output ONLY a JSON object with a "memory" string.',
  },
  {'role': 'user', 'content': 'Notes about $name:\n${note.trim()}\n\nJSON:'},
];

/// Asks the configured LLM for a short version of the person memory [note].
///
/// Like a proposed fact, the answer is only offered: the editor shows it and
/// the user replaces the note with it, or does not. Null on any failure, or
/// for an answer with nothing in it.
Future<String?> condensePersonMemory({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String name,
  required String note,
  http.Client? client,
  Duration? timeout,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || note.trim().isEmpty) return null;
  final content = await _complete(
    base: base,
    model: model,
    apiKey: apiKey,
    what: 'condense',
    temperature: 0.2,
    maxTokens: kPersonFactsMaxTokens,
    messages: condenseRequest(name: name, note: note),
    timeout: timeout ?? llmResponseTimeout(base, LlmTask.personFacts),
    client: client,
    cancel: cancel,
    onError: onError,
  );
  return content == null ? null : parseCondensed(content);
}

/// The short version in whatever the model said: the `{"memory": "…"}` the
/// prompt asks for, or plain text through a code fence. Null for nothing, or
/// for reasoning that never ended.
String? parseCondensed(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  final fence = RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final parsed = jsonDecode(text.substring(start, end + 1));
      if (parsed is Map && parsed['memory'] is String) {
        text = parsed['memory'] as String;
      }
    } on FormatException {
      // Plain text, then.
    }
  }
  text = text.trim();
  if (text.isEmpty || !RegExp(r'\p{L}', unicode: true).hasMatch(text)) {
    return null;
  }
  return trimPersonMemory(text, maxChars: kPersonMemoryHostedChars);
}

/// One completion, its text or null. Logs the status and the error type only:
/// what was said, and what the user wrote about anyone, stay out of the log.
Future<String?> _complete({
  required String base,
  required String model,
  String? apiKey,
  required String what,
  required double temperature,
  required int maxTokens,
  required List<Map<String, String>> messages,
  required Duration timeout,
  http.Client? client,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  try {
    final response = await postLlm(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'messages': messages,
      }),
      timeout: timeout,
      cancel: cancel,
    );
    if (response.statusCode != 200) {
      debugPrint('weft: $what: $url answered ${response.statusCode}');
      onError?.call(StateError('HTTP ${response.statusCode}'));
      return null;
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return ((decoded as Map)['choices'] as List?)
            ?.cast<Map>()
            .firstOrNull?['message']?['content']
        as String?;
  } on Object catch (error) {
    debugPrint('weft: $what against $url failed: ${error.runtimeType}');
    onError?.call(error);
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// The facts in whatever the model said: the `{"facts": [...]}` the prompt
/// asks for, or a bare list, through a code fence or `<think>` block. JSON or
/// nothing, for the reason `parseSmartReplies` gives — a model's analysis
/// turned into "facts" would be worse than none.
List<String> parsePersonFacts(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) {
    return const [];
  }
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();

  List<Object?> raw = const [];
  final objStart = text.indexOf('{');
  final objEnd = text.lastIndexOf('}');
  if (objStart >= 0 && objEnd > objStart) {
    try {
      final parsed = jsonDecode(text.substring(objStart, objEnd + 1));
      if (parsed is Map && parsed['facts'] is List) {
        raw = parsed['facts'] as List;
      }
    } on FormatException {
      // Try the bare list below.
    }
  }
  if (raw.isEmpty) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) {
      try {
        final parsed = jsonDecode(text.substring(start, end + 1));
        if (parsed is List) raw = parsed;
      } on FormatException {
        // Not JSON: no facts.
      }
    }
  }
  final seen = <String>{};
  return [
    for (final fact in raw.whereType<String>())
      if (fact.trim().isNotEmpty &&
          fact.trim().length <= kPersonFactMaxChars &&
          seen.add(factKey(fact)))
        fact.trim().replaceAll(RegExp(r'\s+'), ' '),
  ].take(kPersonMemoryMaxSuggestions).toList(growable: false);
}

/// The longest fact offered; past this the model is writing a summary.
const int kPersonFactMaxChars = 160;
