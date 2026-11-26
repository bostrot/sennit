/// The prompt the on-device models are given, rendered by hand rather than by
/// the GGUF's Jinja template.
///
/// Every model "On this phone" offers is a Qwen3 or Qwen3.5 descendant, and
/// they share one template: ChatML turns, and — when the model is not to
/// think — an empty `<think></think>` block already written into the
/// assistant's turn, which is exactly what Qwen's own template does for
/// `enable_thinking: false`. Rendering it here keeps the prompt something a
/// test can read, and keeps a model with a broken embedded template working.
library;

/// One message of an OpenAI-style chat completion request.
class ChatTurn {
  const ChatTurn(this.role, this.content);

  /// `system`, `user` or `assistant`; anything else is rendered as `user`.
  final String role;
  final String content;

  /// The turns of a chat-completions body's `messages`, skipping what is not
  /// a message. A content list (the multi-part form) keeps its text parts.
  static List<ChatTurn> listFrom(Object? messages) {
    if (messages is! List) return const [];
    final turns = <ChatTurn>[];
    for (final message in messages) {
      if (message is! Map) continue;
      final role = message['role'];
      final content = message['content'];
      final String text;
      if (content is String) {
        text = content;
      } else if (content is List) {
        text = content
            .whereType<Map>()
            .where((part) => part['type'] == 'text')
            .map((part) => part['text'])
            .whereType<String>()
            .join('\n');
      } else {
        continue;
      }
      turns.add(ChatTurn(role is String ? role : 'user', text));
    }
    return turns;
  }
}

const String _imStart = '<|im_start|>';
const String _imEnd = '<|im_end|>';

/// What ends an answer: the end-of-turn token, and the start of a turn the
/// model should not be writing.
const List<String> kQwenStopSequences = [_imEnd, _imStart, '<|endoftext|>'];

/// Renders [turns] as a Qwen prompt that ends where the assistant's answer
/// begins.
///
/// A trailing assistant turn is a prefix the model continues, as the chat
/// completions API means it; otherwise a fresh assistant turn is opened. With
/// [thinking] off the turn opens with the empty think block, so the answer
/// starts at once. Special tokens a message happens to contain are defused:
/// a chat that quotes `<|im_end|>` must not end the user's turn early.
String formatQwenChat(List<ChatTurn> turns, {bool thinking = false}) {
  final out = StringBuffer();
  ChatTurn? prefix;
  for (var i = 0; i < turns.length; i++) {
    final turn = turns[i];
    final role = switch (turn.role) {
      'system' || 'developer' => 'system',
      'assistant' => 'assistant',
      _ => 'user',
    };
    if (role == 'assistant' && i == turns.length - 1) {
      prefix = turn;
      break;
    }
    // Qwen's template keeps only the first system message as one; a later
    // one is still said, as the instruction it is.
    out
      ..write(_imStart)
      ..write(role)
      ..write('\n')
      ..write(
        role == 'assistant'
            ? stripThinking(_defuse(turn.content))
            : _defuse(turn.content),
      )
      ..write(_imEnd)
      ..write('\n');
  }
  out.write('${_imStart}assistant\n');
  if (!thinking) out.write('<think>\n\n</think>\n\n');
  if (prefix != null) out.write(_defuse(prefix.content));
  return out.toString();
}

/// [text] with any `<think>…</think>` block removed, and an unfinished one —
/// a model cut off mid-thought — dropped from where it opens.
String stripThinking(String text) {
  var result = text.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>\s*', multiLine: true),
    '',
  );
  final open = result.indexOf('<think>');
  if (open >= 0) result = result.substring(0, open);
  // A template that opened the block for the model leaves only the close.
  final close = result.indexOf('</think>');
  if (close >= 0) result = result.substring(close + '</think>'.length);
  return result.trim();
}

String _defuse(String text) =>
    text.replaceAll('<|', '<​|').replaceAll('|>', '|​>');
