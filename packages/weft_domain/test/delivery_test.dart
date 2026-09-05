import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

/// The read indicator's arithmetic: receipts and a network in, ticks out.
///
/// Everything here is about *not claiming more than is known*. A tick that says
/// a message was read when nobody can tell is worse than no tick at all — it is
/// the one mark in a messenger people act on without thinking, and a client that
/// is casually wrong about it is a client whose ticks stop meaning anything.
void main() {
  group('deliveryCeilingFor', () {
    test('SMS and email stop at delivered', () {
      // SMS carries a real delivery report and has no read receipts at all;
      // `smsDeliveryState` in `weft_sms` says the same from the other side.
      expect(deliveryCeilingFor(ChatNetwork.sms), DeliveryState.delivered);
      expect(deliveryCeilingFor(ChatNetwork.email), DeliveryState.delivered);
    });

    test('everything else can reach read', () {
      for (final network in const [
        ChatNetwork.matrix,
        ChatNetwork.whatsapp,
        ChatNetwork.signal,
        ChatNetwork.telegram,
      ]) {
        expect(
          deliveryCeilingFor(network),
          DeliveryState.read,
          reason: 'on ${network.id}',
        );
      }
    });
  });

  group('DeliveryState.atLeast', () {
    test('the ticks are ordered the way they are drawn', () {
      expect(DeliveryState.read.atLeast(DeliveryState.delivered), isTrue);
      expect(DeliveryState.delivered.atLeast(DeliveryState.sent), isTrue);
      expect(DeliveryState.sent.atLeast(DeliveryState.sending), isTrue);
      expect(DeliveryState.sent.atLeast(DeliveryState.delivered), isFalse);
    });

    test('failure is below everything, not between sent and delivered', () {
      // Otherwise a ceiling could "raise" a failure into a success.
      expect(DeliveryState.failed.atLeast(DeliveryState.sending), isFalse);
      expect(DeliveryState.sending.atLeast(DeliveryState.failed), isTrue);
    });
  });

  group('resolveDeliveryState', () {
    DeliveryState? resolve({
      DeliveryState? reported = DeliveryState.delivered,
      ChatNetwork network = ChatNetwork.whatsapp,
      int readerCount = 0,
      int? peerCount = 1,
      bool receiptsEnabled = true,
    }) => resolveDeliveryState(
      reported: reported,
      network: network,
      readerCount: readerCount,
      peerCount: peerCount,
      receiptsEnabled: receiptsEnabled,
    );

    test('no reported state is no ticks', () {
      // An incoming message. The ticks belong to the sender.
      expect(resolve(reported: null), isNull);
    });

    test('the three ordinary states pass straight through', () {
      expect(resolve(reported: DeliveryState.sending), DeliveryState.sending);
      expect(resolve(reported: DeliveryState.sent), DeliveryState.sent);
      expect(resolve(), DeliveryState.delivered);
    });

    test('a receipt covering the only peer turns it read', () {
      expect(resolve(readerCount: 1), DeliveryState.read);
    });

    test('a receipt cannot promote a message that has not arrived', () {
      // A receipt for a message still in `sending` is a receipt for something
      // the server has not echoed; the honest reading is that the receipt is
      // for something else.
      expect(
        resolve(reported: DeliveryState.sending, readerCount: 1),
        DeliveryState.sending,
      );
      expect(
        resolve(reported: DeliveryState.sent, readerCount: 1),
        DeliveryState.sent,
      );
    });

    test('a failure stays a failure whatever else is true', () {
      expect(
        resolve(reported: DeliveryState.failed, readerCount: 5, peerCount: 1),
        DeliveryState.failed,
      );
      expect(
        resolve(reported: DeliveryState.failed, network: ChatNetwork.sms),
        DeliveryState.failed,
      );
    });

    group('the group semantic is everyone', () {
      test('one reader out of three is not read', () {
        // WhatsApp's rule, and the reason it is worth having: a group where one
        // person of nine has opened the message is not a message that has been
        // read, and a client that said so would make the mark useless in
        // exactly the conversations it is most looked at.
        expect(resolve(readerCount: 1, peerCount: 3), DeliveryState.delivered);
        expect(resolve(readerCount: 2, peerCount: 3), DeliveryState.delivered);
      });

      test('everyone having read it is read', () {
        expect(resolve(readerCount: 3, peerCount: 3), DeliveryState.read);
      });

      test('more receipts than participants still counts as everyone', () {
        // A member who left after reading, or a stale receipt from a ghost the
        // bridge has since renamed. Neither is a reason to withhold the tick.
        expect(resolve(readerCount: 5, peerCount: 3), DeliveryState.read);
      });

      test('an unknown group size stops at delivered', () {
        // One receipt out of nine looks exactly like one out of one, so the
        // honest answer is to say nothing more than "it arrived".
        expect(
          resolve(readerCount: 4, peerCount: null),
          DeliveryState.delivered,
        );
      });

      test('a group with no participants is not read by nobody', () {
        // A count of zero is a membership that has not loaded, not a room the
        // user is alone in where everything is trivially read.
        expect(resolve(readerCount: 0, peerCount: 0), DeliveryState.delivered);
      });
    });

    group('per-network degradation', () {
      test('SMS never shows a read state, however many receipts arrive', () {
        expect(
          resolve(network: ChatNetwork.sms, readerCount: 1, peerCount: 1),
          DeliveryState.delivered,
        );
      });

      test('SMS still shows sent and delivered', () {
        expect(
          resolve(reported: DeliveryState.sent, network: ChatNetwork.sms),
          DeliveryState.sent,
        );
        expect(resolve(network: ChatNetwork.sms), DeliveryState.delivered);
      });

      test('a state stronger than the network can report is capped', () {
        // Nothing should produce this, and if something does the tick must not
        // be the place it becomes visible as a lie.
        expect(
          resolveDeliveryState(
            reported: DeliveryState.read,
            network: ChatNetwork.sms,
          ),
          DeliveryState.delivered,
        );
      });
    });

    group('receipts switched off', () {
      test('a receipts-disabled account never renders a read state', () {
        // The account is not sending public receipts and nearly every bridge
        // stops relaying the other direction in return. A blue tick here would
        // be fabricated from whatever stale receipt happened to be in hand.
        expect(
          resolve(readerCount: 1, peerCount: 1, receiptsEnabled: false),
          DeliveryState.delivered,
        );
        expect(
          resolve(readerCount: 9, peerCount: 3, receiptsEnabled: false),
          DeliveryState.delivered,
        );
      });

      test('everything below read is unaffected', () {
        expect(
          resolve(reported: DeliveryState.sent, receiptsEnabled: false),
          DeliveryState.sent,
        );
        expect(
          resolve(reported: DeliveryState.failed, receiptsEnabled: false),
          DeliveryState.failed,
        );
      });
    });
  });

  group('deliveryStateIsComplete', () {
    bool complete({
      DeliveryState? state = DeliveryState.delivered,
      ChatNetwork network = ChatNetwork.whatsapp,
      bool receiptsEnabled = true,
    }) => deliveryStateIsComplete(
      state: state,
      network: network,
      receiptsEnabled: receiptsEnabled,
    );

    test('two grey ticks with receipts off are not the whole truth', () {
      // The one case where two grey ticks mean "we are not being told" rather
      // than "they have not looked at it". The bubble says so in words.
      expect(complete(receiptsEnabled: false), isFalse);
    });

    test('everything else is', () {
      expect(complete(), isTrue);
      expect(complete(state: null, receiptsEnabled: false), isTrue);
      expect(
        complete(state: DeliveryState.sent, receiptsEnabled: false),
        isTrue,
        reason: 'a single tick claims nothing about reading',
      );
      expect(
        complete(state: DeliveryState.failed, receiptsEnabled: false),
        isTrue,
        reason: 'a failure is not a missing read state',
      );
      expect(
        complete(state: DeliveryState.read, receiptsEnabled: false),
        isTrue,
        reason: 'a read state that exists is not incomplete',
      );
    });

    test('a network with no read state is complete at delivered', () {
      // SMS never had blue ticks to lose, so two ticks there mean exactly what
      // they say and there is nothing to explain.
      expect(
        complete(network: ChatNetwork.sms, receiptsEnabled: false),
        isTrue,
      );
    });
  });

  group('Chat.peerCount', () {
    Chat chat({bool isGroup = false, int? participantCount}) => Chat(
      id: '!room:example.org',
      title: 'Someone',
      isGroup: isGroup,
      participantCount: participantCount,
      sources: const [
        ChatSource(roomId: '!room:example.org', network: ChatNetwork.matrix),
      ],
    );

    test('a DM has exactly one peer, said or not', () {
      // That is what "not a group" means, and a DM whose room summary has not
      // arrived would otherwise lose its blue ticks for no reason a user could
      // name.
      expect(chat().peerCount, 1);
      expect(chat(participantCount: 1).peerCount, 1);
    });

    test('a group says how many, or does not know', () {
      expect(chat(isGroup: true, participantCount: 7).peerCount, 7);
      expect(chat(isGroup: true).peerCount, isNull);
    });
  });
}
