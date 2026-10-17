/// When the to-do assistant asks the model, and what it does with the answer.
///
/// The model is a fake that records what it was asked; the point is the
/// gating — off by default, never without an endpoint, never for a service or
/// broadcast chat, never for small talk unless the chat has open entries the
/// answer could tick off — and that a failing model never escapes.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/todo/todo_agent.dart';
import 'package:weft/services/todo/todo_assistant.dart';
import 'package:weft/services/todo/todo_item.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  const room = '!grace:example.org';
  const chat = Chat(
    id: room,
    title: 'Grace',
    sources: [ChatSource(roomId: room, network: ChatNetwork.whatsapp)],
  );
  const endpoint = AutoReplyEndpoint(baseUrl: 'http://llm.local', model: 'm');

  var seq = 0;
  WeftMessage msg(String body, {bool own = false, bool autoReply = false}) =>
      WeftMessage(
        eventId: '\$e${seq++}',
        roomId: room,
        network: ChatNetwork.whatsapp,
        senderId: own ? '@me:example.org' : '@whatsapp_grace:example.org',
        senderName: own ? 'Me' : 'Grace',
        timestamp: DateTime.utc(2026, 10, 17, 10),
        kind: MessageKind.text,
        isOwn: own,
        isAutoReply: autoReply,
        body: body,
      );

  late List<List<String>> asked;
  late List<TodoChanges> applied;
  late bool enabled;
  late AutoReplyEndpoint? configured;
  late List<TodoItem> open;
  late bool serviceChat;
  late TodoChanges? answer;
  late Object? failure;

  TodoAgent agent() => TodoAgent(
    incoming: const Stream.empty(),
    chatForRoom: (id) => id == room ? chat : null,
    isServiceChat: (_) => serviceChat,
    isBroadcast: (_) => false,
    enabled: () => enabled,
    endpoint: () => configured,
    openItemsFor: (_) => open,
    apply: (_, changes) => applied.add(changes),
    settle: Duration.zero,
    proposer:
        ({
          required baseUrl,
          required model,
          apiKey,
          required chatTitle,
          required transcript,
          required open,
          required today,
        }) async {
          asked.add(transcript);
          if (failure != null) throw failure!;
          return answer;
        },
  );

  setUp(() {
    asked = [];
    applied = [];
    enabled = true;
    configured = endpoint;
    open = const [];
    serviceChat = false;
    answer = const TodoChanges(add: [TodoProposal(title: 'Bring the cable')]);
    failure = null;
  });

  test(
    'a request is read with its conversation and the answer applied',
    () async {
      final a = agent();
      await a.handleMessage(msg('hey'));
      await a.handleMessage(msg('could you bring the cable tomorrow?'));

      expect(asked, hasLength(1));
      expect(asked.single, [
        'Grace: hey',
        'Grace: could you bring the cable tomorrow?',
      ]);
      expect(applied.single.add.single.title, 'Bring the cable');
    },
  );

  test('a promise the user makes counts too', () async {
    await agent().handleMessage(msg("I'll send it tonight", own: true));
    expect(asked.single.single, "You: I'll send it tonight");
  });

  test('switched off, or without an endpoint, nothing is asked', () async {
    enabled = false;
    await agent().handleMessage(msg('please call me'));
    enabled = true;
    configured = null;
    await agent().handleMessage(msg('please call me'));
    expect(asked, isEmpty);
  });

  test('small talk is not sent unless the chat has open entries', () async {
    final a = agent();
    await a.handleMessage(msg('haha nice'));
    expect(asked, isEmpty);

    open = [
      TodoItem(id: 'a', title: 'Bring the cable', createdAt: DateTime(2026)),
    ];
    answer = const TodoChanges(complete: {'a'});
    await a.handleMessage(msg('got it, thanks'));
    expect(asked, hasLength(1));
    expect(applied.single.complete, {'a'});
  });

  test('service chats and auto-replies never trigger a read', () async {
    final a = agent();
    await a.handleMessage(msg('please call me', own: true, autoReply: true));
    serviceChat = true;
    await a.handleMessage(msg('please confirm your account'));
    expect(asked, isEmpty);
  });

  test('a failing model, or an empty answer, changes nothing', () async {
    failure = StateError('model down');
    await agent().handleMessage(msg('please call me'));
    failure = null;
    answer = TodoChanges.none;
    await agent().handleMessage(msg('please call me'));
    expect(asked, hasLength(2));
    expect(applied, isEmpty);
  });

  test('a burst is read once after the conversation settles', () async {
    final a = TodoAgent(
      incoming: const Stream.empty(),
      chatForRoom: (_) => chat,
      isServiceChat: (_) => false,
      isBroadcast: (_) => false,
      enabled: () => true,
      endpoint: () => endpoint,
      openItemsFor: (_) => const [],
      apply: (_, changes) => applied.add(changes),
      settle: const Duration(milliseconds: 20),
      proposer:
          ({
            required baseUrl,
            required model,
            apiKey,
            required chatTitle,
            required transcript,
            required open,
            required today,
          }) async {
            asked.add(transcript);
            return answer;
          },
    );
    addTearDown(a.dispose);

    await a.handleMessage(msg('could you'));
    await a.handleMessage(msg('bring the cable'));
    await a.handleMessage(msg('please'));
    expect(asked, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(asked, hasLength(1));
    expect(asked.single, hasLength(3));
  });
}
