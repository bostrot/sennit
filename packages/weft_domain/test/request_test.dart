import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

/// The chat-request state machine and its per-network mappings.
///
/// Everything here is pure, which is the point: what accepting, declining and
/// blocking *mean* differs by network in ways that are easy to get wrong and
/// impossible to notice — a decline that quietly sent a read receipt looks
/// exactly like one that did not.
void main() {
  group('applyChatRequestAction', () {
    test('each answer moves a pending request to its own state', () {
      expect(
        applyChatRequestAction(
          ChatRequestState.pending,
          ChatRequestAction.accept,
        ),
        ChatRequestState.accepted,
      );
      expect(
        applyChatRequestAction(
          ChatRequestState.pending,
          ChatRequestAction.decline,
        ),
        ChatRequestState.declined,
      );
      expect(
        applyChatRequestAction(
          ChatRequestState.pending,
          ChatRequestAction.block,
        ),
        ChatRequestState.blocked,
      );
    });

    test('a settled request cannot be answered again', () {
      // Accepting a declined request would be accepting a room that has been
      // left — the thing being accepted no longer exists. A double-tap on
      // Accept is the ordinary way this is reached, and it must be harmless.
      for (final settled in const [
        ChatRequestState.accepted,
        ChatRequestState.declined,
        ChatRequestState.blocked,
      ]) {
        for (final action in ChatRequestAction.values) {
          expect(
            applyChatRequestAction(settled, action),
            settled,
            reason: '$action on $settled',
          );
        }
      }
    });
  });

  group('isPendingRequest', () {
    test('only pending is pending, and null is an ordinary chat', () {
      expect(isPendingRequest(ChatRequestState.pending), isTrue);
      expect(isPendingRequest(ChatRequestState.accepted), isFalse);
      expect(isPendingRequest(ChatRequestState.declined), isFalse);
      expect(isPendingRequest(ChatRequestState.blocked), isFalse);
      expect(isPendingRequest(null), isFalse);
    });
  });

  group('planChatRequest', () {
    test('a Matrix invite is joined on accept and left on decline', () {
      expect(
        planChatRequest(
          action: ChatRequestAction.accept,
          network: ChatNetwork.matrix,
        ),
        const ChatRequestPlan(join: true),
      );
      expect(
        planChatRequest(
          action: ChatRequestAction.decline,
          network: ChatNetwork.matrix,
        ),
        const ChatRequestPlan(leave: true),
      );
    });

    test('a bridged chat has nothing to join', () {
      // The bridge joined the room on the user's behalf before Braid ever saw
      // it. A `join` here would be a no-op at best and a membership change the
      // remote network relays at worst.
      for (final network in const [
        ChatNetwork.whatsapp,
        ChatNetwork.signal,
        ChatNetwork.telegram,
        ChatNetwork.instagram,
      ]) {
        expect(
          planChatRequest(
            action: ChatRequestAction.accept,
            network: network,
          ).join,
          isFalse,
          reason: 'on ${network.id}',
        );
        // Declining still leaves: it is the only way to stop the bridge
        // relaying into the room.
        expect(
          planChatRequest(
            action: ChatRequestAction.decline,
            network: network,
          ).leave,
          isTrue,
          reason: 'on ${network.id}',
        );
      }
    });

    test('SMS has no room to join or leave', () {
      for (final action in ChatRequestAction.values) {
        final plan = planChatRequest(action: action, network: ChatNetwork.sms);
        expect(plan.join, isFalse, reason: '$action');
        expect(plan.leave, isFalse, reason: '$action');
      }
      // Blocking still reaches somewhere real: the platform's own block list is
      // the only durable thing available for a phone number.
      expect(
        planChatRequest(
          action: ChatRequestAction.block,
          network: ChatNetwork.sms,
        ).ignoreSender,
        isTrue,
      );
    });

    test('only blocking ignores the sender', () {
      for (final network in ChatNetwork.values) {
        expect(
          planChatRequest(
            action: ChatRequestAction.accept,
            network: network,
          ).ignoreSender,
          isFalse,
          reason: 'accept on ${network.id}',
        );
        // Declining is not blocking. They look identical from the outside —
        // the row goes — and the difference is whether the sender can write
        // again.
        expect(
          planChatRequest(
            action: ChatRequestAction.decline,
            network: network,
          ).ignoreSender,
          isFalse,
          reason: 'decline on ${network.id}',
        );
        expect(
          planChatRequest(
            action: ChatRequestAction.block,
            network: network,
          ).ignoreSender,
          isTrue,
          reason: 'block on ${network.id}',
        );
      }
    });

    test('no plan on any network ever marks the request read', () {
      // The rule the whole feature rests on. The promise of holding a
      // stranger's message is that they learn nothing: not that it was
      // delivered, not that it was opened, and not that it was refused.
      for (final network in ChatNetwork.values) {
        for (final action in ChatRequestAction.values) {
          expect(
            planChatRequest(action: action, network: network).markRead,
            isFalse,
            reason: '$action on ${network.id}',
          );
        }
      }
    });
  });

  group('isChatRequest', () {
    test('a Matrix invite from a stranger is a request', () {
      expect(
        isChatRequest(
          invited: true,
          everSentByUser: false,
          knownContact: false,
        ),
        isTrue,
      );
    });

    test('a stranger on a bridged network is a request with no invite', () {
      // The bridge joined for the user, so there is no invite to notice. What
      // makes it a request is that nobody knows who this is.
      expect(
        isChatRequest(
          invited: false,
          everSentByUser: false,
          knownContact: false,
        ),
        isTrue,
      );
    });

    test('a known contact is never a request', () {
      expect(
        isChatRequest(
          invited: false,
          everSentByUser: false,
          knownContact: true,
        ),
        isFalse,
      );
    });

    test('having replied settles it, whatever else is true', () {
      // The rule that stops this from sweeping a real inbox into a requests
      // list overnight: a contact deleted from the address book, a number that
      // never had a name, a group joined a year ago and talked in since.
      expect(
        isChatRequest(invited: true, everSentByUser: true, knownContact: false),
        isFalse,
      );
      expect(
        isChatRequest(
          invited: false,
          everSentByUser: true,
          knownContact: false,
          isGroup: true,
        ),
        isFalse,
      );
    });

    test('a group from a stranger is a request too', () {
      // Being added to a group by someone unknown is the same imposition as
      // being messaged by them, and worse: a group can hold anyone.
      expect(
        isChatRequest(
          invited: true,
          everSentByUser: false,
          knownContact: false,
          isGroup: true,
        ),
        isTrue,
      );
    });
  });

  group('Chat.request', () {
    Chat chat({ChatRequestState? request}) => Chat(
      id: '!room:example.org',
      title: 'Someone',
      sources: const [
        ChatSource(roomId: '!room:example.org', network: ChatNetwork.matrix),
      ],
      request: request,
    );

    test('null is an ordinary conversation', () {
      expect(chat().request, isNull);
      expect(chat().isPendingRequest, isFalse);
    });

    test('accepting clears the flag rather than leaving it set', () {
      // A `??` here would make null mean "leave it alone", and the row would
      // stay in the requests section for ever.
      final accepted = chat(
        request: ChatRequestState.pending,
      ).copyWith(request: null);

      expect(accepted.request, isNull);
      expect(accepted.isPendingRequest, isFalse);
    });

    test('copyWith leaves the state alone when it is not named', () {
      final still = chat(
        request: ChatRequestState.pending,
      ).copyWith(muted: true);

      expect(still.request, ChatRequestState.pending);
      expect(still.isPendingRequest, isTrue);
    });
  });
}
