import 'package:flutter_test/flutter_test.dart';

import 'package:weft/services/ai/conversation_context.dart';

/// The buffer both AI features read.
///
/// Its whole job is two bounds and an order, and all three are load-bearing:
/// the per-conversation bound is how much leaves the device when the model is
/// asked anything, the conversation bound is what stops a busy account holding
/// a buffer per room for the life of the process, and the order is what the
/// prompts — "newest message last" — are written against.
void main() {
  group('remember', () {
    test('keeps the newest window, oldest first', () {
      final context = ConversationContext<String>(maxMessages: 3);

      for (final line in ['one', 'two', 'three', 'four', 'five']) {
        context.remember('chat', line);
      }

      expect(context.of('chat'), ['three', 'four', 'five']);
    });

    test('defaults to the shared AI bound', () {
      final context = ConversationContext<int>();

      for (var i = 0; i < kAiContextMessages * 2; i++) {
        context.remember('chat', i);
      }

      // Equal, not merely under: this is the number the architecture doc
      // quotes, so a buffer that quietly kept fewer would make the doc wrong.
      expect(context.of('chat'), hasLength(kAiContextMessages));
      expect(context.of('chat').first, kAiContextMessages);
      expect(context.of('chat').last, kAiContextMessages * 2 - 1);
    });

    test('returns the bounded result, so one step answers both questions', () {
      final context = ConversationContext<String>(maxMessages: 2);

      context.remember('chat', 'one');
      expect(context.remember('chat', 'two'), ['one', 'two']);
      expect(context.remember('chat', 'three'), ['two', 'three']);
    });

    test('hands out a snapshot a caller cannot trim', () {
      // The notification path passes this straight to the suggester, which is
      // someone else's closure; a live list would also change under it across
      // the await.
      final context = ConversationContext<String>();
      final thread = context.remember('chat', 'one');

      expect(() => thread.add('two'), throwsUnsupportedError);
      expect(() => context.of('chat').clear(), throwsUnsupportedError);
    });

    test('keeps conversations apart', () {
      final context = ConversationContext<String>();

      context.remember('a', 'from a');
      context.remember('b', 'from b');

      expect(context.of('a'), ['from a']);
      expect(context.of('b'), ['from b']);
    });
  });

  group('the conversation bound', () {
    test('drops the least recently spoken in', () {
      final context = ConversationContext<String>(maxConversations: 2);

      context.remember('a', 'first');
      context.remember('b', 'second');
      // Speaking in `a` again makes `b` the stale one, which is the difference
      // between an LRU and insertion order.
      context.remember('a', 'third');
      context.remember('c', 'fourth');

      expect(context.length, 2);
      expect(context.of('a'), ['first', 'third']);
      expect(context.of('c'), ['fourth']);
      expect(context.of('b'), isEmpty);
    });
  });

  group('forgetting', () {
    test('an unknown conversation reads as empty rather than throwing', () {
      // The notification path asks before anything has arrived for a chat on
      // every cold start.
      expect(ConversationContext<String>().of('nobody'), isEmpty);
    });

    test('forget drops one conversation and leaves the rest', () {
      final context = ConversationContext<String>();
      context.remember('a', 'from a');
      context.remember('b', 'from b');

      context.forget('a');

      expect(context.of('a'), isEmpty);
      expect(context.of('b'), ['from b']);
    });

    test('clear drops everything, which is what dispose needs', () {
      final context = ConversationContext<String>();
      context.remember('a', 'from a');
      context.remember('b', 'from b');

      context.clear();

      expect(context.length, 0);
      expect(context.of('a'), isEmpty);
    });
  });
}
