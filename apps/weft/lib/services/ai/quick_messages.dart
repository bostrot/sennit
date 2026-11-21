import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auto_reply_writer.dart'
    show AutoReplyDraft, AutoReplyOutcome, parseAutoReply;

/// The quick messages Sennit ships with.
///
/// An enum rather than a list of strings because the *title* is the user's
/// language and the *prompt* is the model's: the title is looked up in the ARB
/// on every build (`l10n_labels.dart`), so switching the app to German renames
/// "Happy Birthday" without anyone having saved anything, while the prompt
/// stays the English instruction [kQuickMessageDefaultPrompts] holds.
enum QuickMessagePreset {
  birthday,
  congratulations,
  getWell,
  thanks,
  onMyWay,
  newYear,
}

/// What each preset asks the model for, in English whatever the app language.
///
/// Short on purpose. Everything every quick message needs — the name, the
/// language, no quotation marks — is said once in the system message
/// [quickMessageRequest] writes; these only say what *this* message is.
const Map<QuickMessagePreset, String> kQuickMessageDefaultPrompts = {
  QuickMessagePreset.birthday:
      'A happy birthday wish. Say "happy birthday" in their language.',
  QuickMessagePreset.congratulations:
      'Congratulations. Name what for only if the earlier messages say it.',
  QuickMessagePreset.getWell:
      'A get-well-soon wish: hope they recover quickly.',
  QuickMessagePreset.thanks:
      'A thank-you. Name what for only if the earlier messages say it.',
  QuickMessagePreset.onMyWay:
      'Tell them I am running a little late and I am on my way.',
  QuickMessagePreset.newYear: 'A happy new year wish.',
};

const Map<QuickMessagePreset, String> _presetEmoji = {
  QuickMessagePreset.birthday: '🎂',
  QuickMessagePreset.congratulations: '🎉',
  QuickMessagePreset.getWell: '🤒',
  QuickMessagePreset.thanks: '🙏',
  QuickMessagePreset.onMyWay: '🏃',
  QuickMessagePreset.newYear: '🎆',
};

/// One entry in the quick message list.
///
/// A built-in entry carries its [preset] and leaves [title] and [prompt] null
/// until the user edits them, so an untouched default follows the app language
/// and any later improvement to its prompt. An edited one keeps what the user
/// wrote. A user's own entry has no preset and both fields set.
@immutable
class QuickMessage {
  const QuickMessage({
    required this.id,
    this.preset,
    this.title,
    this.emoji,
    this.prompt,
  });

  /// [preset] as it ships.
  factory QuickMessage.builtIn(QuickMessagePreset preset) => QuickMessage(
    id: 'preset:${preset.name}',
    preset: preset,
    emoji: _presetEmoji[preset],
  );

  final String id;
  final QuickMessagePreset? preset;

  /// The user's title, or null for a preset's localised one.
  final String? title;

  /// An emoji shown before the title; null or empty for none.
  final String? emoji;

  /// The user's prompt, or null for the preset's.
  final String? prompt;

  /// The instruction the model is given.
  String get effectivePrompt {
    final own = prompt?.trim() ?? '';
    if (own.isNotEmpty) return own;
    return preset == null ? '' : kQuickMessageDefaultPrompts[preset]!;
  }

  QuickMessage copyWith({String? title, String? emoji, String? prompt}) =>
      QuickMessage(
        id: id,
        preset: preset,
        title: title ?? this.title,
        emoji: emoji ?? this.emoji,
        prompt: prompt ?? this.prompt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    if (preset != null) 'preset': preset!.name,
    if (title != null) 'title': title,
    if (emoji != null) 'emoji': emoji,
    if (prompt != null) 'prompt': prompt,
  };

  /// Null for anything this build cannot read: an entry from a newer build
  /// with a preset it does not know, or one that names nothing to say.
  static QuickMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final presetName = json['preset'];
    final preset = presetName is String
        ? QuickMessagePreset.values
              .where((p) => p.name == presetName)
              .firstOrNull
        : null;
    if (presetName != null && preset == null) return null;
    String? text(Object? v) => v is String ? v : null;
    final message = QuickMessage(
      id: id,
      preset: preset,
      title: text(json['title']),
      emoji: text(json['emoji']),
      prompt: text(json['prompt']),
    );
    if (preset == null &&
        ((message.title?.trim().isEmpty ?? true) ||
            message.effectivePrompt.isEmpty)) {
      return null;
    }
    return message;
  }

  /// The shipped list, in the order the sheet shows it.
  static List<QuickMessage> get defaults => [
    for (final preset in QuickMessagePreset.values)
      QuickMessage.builtIn(preset),
  ];

  /// The stored list, or [defaults] when nothing is stored. Never throws: an
  /// entry this build cannot read is dropped and the rest kept.
  static List<QuickMessage> listFromJson(Map<String, Object?>? json) {
    final raw = json?['messages'];
    if (raw is! List) return defaults;
    return [
      for (final entry in raw)
        if (fromJson(entry) case final QuickMessage message) message,
    ];
  }

  static Map<String, Object?> listToJson(List<QuickMessage> messages) => {
    'messages': [for (final m in messages) m.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is QuickMessage &&
      other.id == id &&
      other.preset == preset &&
      other.title == title &&
      other.emoji == emoji &&
      other.prompt == prompt;

  @override
  int get hashCode => Object.hash(id, preset, title, emoji, prompt);
}

/// The first name to greet someone by, from the name a chat shows for them,
/// or null when there is none worth using.
///
/// Display names on bridged networks are whatever the other side typed, plus
/// whatever the bridge added: `Anna Müller (WhatsApp)`, `🌸 Anna 🌸`,
/// `Müller, Anna`, `Dr. Anna Müller`, `Anna "Annie" Müller`, `@anna:matrix.org`,
/// `+49 170 1234567`. A birthday wish that says "Happy birthday, +49!" is
/// worse than one that says no name at all, so anything without a letter in
/// it is null, and so is a Matrix ID, a phone number or an email address.
String? firstNameOf(String? displayName) {
  var name = displayName?.trim() ?? '';
  if (name.isEmpty) return null;
  if (RegExp(r'^[@!#][^\s:]+:\S+$').hasMatch(name)) return null;
  if (RegExp(r'^\S+@\S+\.\S+$').hasMatch(name)) return null;

  // A nickname in quotes is what the person goes by.
  final nick = RegExp(r'''["“„«']([^"“”„«»']+)["”“»']''').firstMatch(name);
  if (nick != null && RegExp(r'\p{L}', unicode: true).hasMatch(nick[1]!)) {
    return _firstWord(nick[1]!);
  }

  // What a bridge or an address book appended: "(WhatsApp)", "[Telegram]",
  // "- Work", "| Acme".
  name = name
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}'), ' ')
      .split(RegExp(r'\s[-–—|/·]\s'))
      .first;

  // "Müller, Anna" is filed surname-first.
  final comma = name.split(',');
  if (comma.length == 2 && comma[1].trim().isNotEmpty) name = comma[1];

  return _firstWord(name);
}

const _honorifics = {
  'dr',
  'prof',
  'mr',
  'mrs',
  'ms',
  'miss',
  'herr',
  'frau',
  'mme',
  'mlle',
  'm',
  'sr',
  'sra',
  'srta',
  'dona',
  'don',
};

String? _firstWord(String text) {
  // Dots and underscores split too: "anna.mueller" is a handle, not a name.
  for (final raw in text.split(RegExp(r'[\s._]+'))) {
    // Letters, combining marks and the joiners names are spelled with; an
    // emoji or a digit is not part of anybody's first name.
    final word = raw
        .replaceAll(RegExp(r"[^\p{L}\p{M}'’-]", unicode: true), '')
        .replaceAll(RegExp(r"^['’-]+|['’-]+$"), '');
    if (word.isEmpty) continue;
    if (_honorifics.contains(word.toLowerCase())) continue;
    // All-lowercase handles ("anna.mueller") get a capital; a name the person
    // spelled in capitals or in a script without case is left alone.
    return word[0].toUpperCase() == word[0]
        ? word
        : word[0].toUpperCase() + word.substring(1);
  }
  return null;
}

/// The language the recent messages are written in, as an ISO 639-1 code, or
/// [fallback] when they say too little to tell.
///
/// Both sides count — the point is the language the two people speak to each
/// other — and only what was said: [lines] are transcript lines, `Name: text`,
/// and the names are stripped first so a German "Anna" in an English chat
/// cannot tip the count. A script settles it at once for the languages that
/// have their own; the Latin-script ones are told apart by their commonest
/// short words, which is crude and is also what works on four-word chat
/// lines where a statistical detector has nothing to go on.
String detectChatLanguage(List<String> lines, {required String fallback}) {
  final text = [
    for (final line in lines)
      line.contains(': ') ? line.substring(line.indexOf(': ') + 2) : line,
  ].join(' ');
  if (text.trim().isEmpty) return fallback;

  int count(String pattern) =>
      RegExp(pattern, unicode: true).allMatches(text).length;
  final scripts = <String, int>{
    'ja': count(r'[\p{Script=Hiragana}\p{Script=Katakana}]'),
    'ko': count(r'\p{Script=Hangul}'),
    'zh': count(r'\p{Script=Han}'),
    'ru': count(r'\p{Script=Cyrillic}'),
    'ar': count(r'\p{Script=Arabic}'),
    'he': count(r'\p{Script=Hebrew}'),
    'el': count(r'\p{Script=Greek}'),
    'th': count(r'\p{Script=Thai}'),
    'hi': count(r'\p{Script=Devanagari}'),
  };
  // Kana in any amount is Japanese, however many kanji sit beside it.
  if (scripts['ja']! > 0) return 'ja';
  final latin = count(r'\p{Script=Latin}');
  final topScript = scripts.entries.reduce(
    (a, b) => a.value >= b.value ? a : b,
  );
  if (topScript.value > 0 && topScript.value * 2 >= latin) return topScript.key;

  final words = text
      .toLowerCase()
      .split(RegExp(r"[^\p{L}']+", unicode: true))
      .where((w) => w.isNotEmpty);
  final scores = {for (final code in _stopwords.keys) code: 0};
  for (final word in words) {
    for (final entry in _stopwords.entries) {
      if (entry.value.contains(word)) {
        scores[entry.key] = scores[entry.key]! + 1;
      }
    }
  }
  final best = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final tied = scores.values.where((v) => v == best.value).length > 1;
  // Nothing recognised, or two languages equally likely: the app's language
  // is the better guess than either.
  if (best.value == 0 || tied) return fallback;
  return best.key;
}

/// The commonest short words of the Latin-script languages Sennit is likely
/// to meet, chosen so few are shared: "a", "o", "de" and "que" would vote for
/// three languages at once and are left out.
const Map<String, Set<String>> _stopwords = {
  'en': {
    'the',
    'you',
    'and',
    'is',
    'are',
    'it',
    'what',
    'have',
    'this',
    'that',
    'with',
    'for',
    'was',
    'will',
    'just',
    'thanks',
    'yes',
    'see',
    'how',
    'i\'m',
    'don\'t',
    'my',
    'your',
    'to',
    'of',
    'be',
    'we',
    'can',
    'not',
  },
  'de': {
    'ich',
    'du',
    'und',
    'ist',
    'nicht',
    'das',
    'der',
    'die',
    'mit',
    'auf',
    'hast',
    'bist',
    'wir',
    'ja',
    'auch',
    'noch',
    'schon',
    'mal',
    'gerne',
    'danke',
    'heute',
    'morgen',
    'wie',
    'was',
    'dich',
    'mich',
    'mir',
    'dir',
    'aber',
    'sehr',
    'gut',
    'kommst',
    'bin',
    'sind',
    'ein',
    'eine',
    'zu',
  },
  'fr': {
    'je',
    'tu',
    'est',
    'et',
    'le',
    'la',
    'les',
    'pas',
    'vous',
    'nous',
    'oui',
    'merci',
    'c\'est',
    'avec',
    'pour',
    'mais',
    'bien',
    'ça',
    'moi',
    'toi',
    'suis',
    'demain',
    'aujourd\'hui',
    'une',
    'des',
    'qui',
    'très',
  },
  'es': {
    'yo',
    'tú',
    'es',
    'el',
    'los',
    'las',
    'pero',
    'gracias',
    'sí',
    'está',
    'estoy',
    'muy',
    'bien',
    'mañana',
    'hoy',
    'con',
    'para',
    'por',
    'una',
    'qué',
    'cómo',
    'hola',
    'vamos',
    'nos',
    'te',
    'también',
    'y',
  },
  'pt': {
    'eu',
    'você',
    'não',
    'é',
    'obrigado',
    'obrigada',
    'sim',
    'está',
    'estou',
    'muito',
    'bem',
    'amanhã',
    'hoje',
    'com',
    'para',
    'uma',
    'tudo',
    'vamos',
    'também',
    'mas',
    'oi',
    'olá',
    'tá',
    'e',
    'do',
    'da',
  },
  'it': {
    'io',
    'sono',
    'non',
    'è',
    'il',
    'grazie',
    'sì',
    'ciao',
    'bene',
    'molto',
    'domani',
    'oggi',
    'con',
    'per',
    'anche',
    'ma',
    'che',
    'come',
    'tutto',
    'della',
    'ci',
    'mi',
    'ti',
  },
  'nl': {
    'ik',
    'jij',
    'je',
    'het',
    'een',
    'niet',
    'ook',
    'maar',
    'met',
    'voor',
    'dank',
    'bedankt',
    'ja',
    'morgen',
    'vandaag',
    'wat',
    'hoe',
    'goed',
    'heb',
    'ben',
    'zijn',
    'van',
    'dat',
    'wij',
    'we',
  },
};

/// English names for the codes [detectChatLanguage] answers with, for the
/// prompt: a small model follows "Write in German" far more reliably than "in
/// the language of the conversation".
const Map<String, String> _languageNames = {
  'en': 'English',
  'de': 'German',
  'fr': 'French',
  'es': 'Spanish',
  'pt': 'Portuguese',
  'it': 'Italian',
  'nl': 'Dutch',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ru': 'Russian',
  'ar': 'Arabic',
  'he': 'Hebrew',
  'el': 'Greek',
  'th': 'Thai',
  'hi': 'Hindi',
};

/// The longest a generated quick message may be: a few sentences.
const int kQuickMessageMaxTokens = 512;

/// How many recent messages a quick message is written in the light of.
///
/// Fewer than the calendar title reads, and well under `kAiContextMessages`:
/// the message is new, so the conversation is there for the language, a name,
/// and what the occasion is — the last dozen lines say all three.
const int kQuickMessageContextMessages = 12;

/// The chat completion messages for one quick message.
///
/// Separate from [composeQuickMessage] so the prompt can be tested without an
/// endpoint. [recipient] is the first name to use, or null; [groupName] is
/// set only for a group chat. [language] is an ISO code from
/// [detectChatLanguage].
///
/// Laid out as a form — task, for whom, language, then the chat — with two
/// worked examples in front, because that is what a phone-sized model
/// follows. Given the chat first and the task after, a 1.5B model answered
/// the chat ("Super, bis Samstag!") instead of wishing anyone a happy
/// birthday; told "in the language of the conversation", it wrote English.
List<Map<String, String>> quickMessageRequest({
  required String instruction,
  required List<String> transcript,
  required String language,
  String? recipient,
  String? groupName,
}) {
  final languageName =
      _languageNames[language] ?? 'the language of the recent messages';
  final String who;
  if (groupName != null) {
    who =
        'the group chat "$groupName" — address the group, or the one person '
        'the recent messages show it is for';
  } else {
    who = recipient ?? 'the other person in the chat (no name known)';
  }

  // The chat first and the task last: a small model follows what it read
  // most recently, and what it must follow is the task.
  String task(String instruction, String who, String language, String chat) =>
      'Earlier messages (background only — the new message is not a reply '
      'to them):\n$chat\n\n'
      'New message to write: $instruction\n'
      'It is for: $who\n'
      'Write it in: $language';

  return [
    {
      'role': 'system',
      'content':
          'You write one short chat message that the user will send from '
          'their own phone. You do not reply to the chat: you write the '
          'message the task asks for, to the person it is for, in the '
          'language given. Very short, warm and natural, like a text from a '
          'friend: one or two sentences, an emoji at most. Use the first '
          'name given once; never invent a name. Output only the message '
          'itself — no quotation marks, no preamble, no explanation, no '
          'signature, no placeholders like [name].',
    },
    {
      'role': 'user',
      'content': task(
        kQuickMessageDefaultPrompts[QuickMessagePreset.birthday]!,
        'Lea',
        'German',
        'Lea: Hast du am Samstag Zeit?\nYou: Ja, ich komme!',
      ),
    },
    {
      'role': 'assistant',
      'content':
          'Alles Gute zum Geburtstag, liebe Lea! 🎂 Hab einen wunderschönen '
          'Tag!',
    },
    {
      'role': 'user',
      'content': task(
        kQuickMessageDefaultPrompts[QuickMessagePreset.thanks]!,
        'Tom',
        'English',
        'Tom: I dropped your keys off with your neighbour\nYou: oh great',
      ),
    },
    {
      'role': 'assistant',
      'content':
          'Thanks so much for bringing my keys back, Tom, you saved my day!',
    },
    {
      'role': 'user',
      'content': task(
        instruction,
        who,
        languageName,
        transcript.isEmpty ? '(no messages yet)' : transcript.join('\n'),
      ),
    },
  ];
}

/// Asks the configured LLM to write one quick message.
///
/// The same OpenAI-compatible endpoint the other AI features use. Nothing is
/// sent: the text lands in the composer for the user to read first, which is
/// why the answer is read as plain text here and not fenced in the
/// auto-reply's `<reply>` tags — the small local models people run ignored the
/// tags for this prompt nearly every time, and a draft the user reviews does
/// not need the guarantee that a message sent unseen does. A thinking model's
/// `<think>` block is still never let through. [AutoReplyOutcome.sent] here
/// only means "written".
Future<AutoReplyDraft> composeQuickMessage({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String instruction,
  required List<String> transcript,
  required String language,
  String? recipient,
  String? groupName,
  http.Client? client,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || instruction.trim().isEmpty) {
    return const AutoReplyDraft.failed(AutoReplyOutcome.notConfigured);
  }
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            // Warmer than a title: "regenerate" should give a different wish.
            'temperature': 0.7,
            'max_tokens': kQuickMessageMaxTokens,
            'messages': quickMessageRequest(
              instruction: instruction,
              transcript: transcript,
              language: language,
              recipient: recipient,
              groupName: groupName,
            ),
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      debugPrint('weft: quick message: $url answered ${response.statusCode}');
      return const AutoReplyDraft.failed(AutoReplyOutcome.unreachable);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final content =
        ((decoded as Map)['choices'] as List?)
                ?.cast<Map>()
                .firstOrNull?['message']?['content']
            as String?;
    final text = content == null ? null : parseQuickMessage(content);
    if (text == null) {
      debugPrint(
        'weft: quick message: nothing usable in ${jsonEncode(content)}',
      );
      return const AutoReplyDraft.failed(AutoReplyOutcome.refused);
    }
    return AutoReplyDraft.written(text);
  } on TimeoutException {
    debugPrint('weft: quick message against $url timed out');
    return const AutoReplyDraft.failed(AutoReplyOutcome.timedOut);
  } on Object catch (error) {
    debugPrint('weft: quick message against $url failed: $error');
    return const AutoReplyDraft.failed(AutoReplyOutcome.unreachable);
  } finally {
    if (owned) httpClient.close();
  }
}

/// The message in whatever the model said, or null when there is none.
///
/// Reasoning in `<think>` is dropped, and an answer that never left it is
/// nothing. A model that wrapped its answer in the auto-reply tags anyway is
/// read through [parseAutoReply]. Otherwise the first paragraph, with the
/// labels and quotation marks small models like to add taken off: `Message:`,
/// a speaker's `Anna:` echoed from the transcript, `"…"` around the whole.
String? parseQuickMessage(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  if (RegExp(r'<\s*reply\s*>', caseSensitive: false).hasMatch(text)) {
    return parseAutoReply(text, finished: true).text;
  }
  final fence = RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  text = text.split(RegExp(r'\n\s*\n')).first.trim();
  text = text
      .replaceFirst(
        RegExp(
          r'^(?:message|reply|answer|you|here(?: i|\x27)s[^:\n]*)\s*:\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  text = _unwrap(text);
  if (text.isEmpty || !RegExp(r'\p{L}', unicode: true).hasMatch(text)) {
    return null;
  }
  if (text.length > kQuickMessageMaxChars) {
    final cut = text.substring(0, kQuickMessageMaxChars).lastIndexOf(' ');
    text = '${text.substring(0, cut > 0 ? cut : kQuickMessageMaxChars)}…';
  }
  return text;
}

/// The longest draft put into the composer; past this a model has stopped
/// writing a quick message.
const int kQuickMessageMaxChars = 600;

String _unwrap(String text) {
  const pairs = {'"': '"', '“': '”', '„': '“', '«': '»', '»': '«'};
  if (text.length < 2) return text;
  final closing = pairs[text[0]];
  if (closing == null || !text.endsWith(closing)) return text;
  final inner = text.substring(1, text.length - 1);
  return inner.contains(closing) ? text : inner.trim();
}
