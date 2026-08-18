import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sms/weft_sms.dart';

void main() {
  SmsMessage message({
    String id = '42',
    String threadId = '7',
    String address = '+441234567890',
    String body = 'on my way',
    bool isOutgoing = false,
    String? subject,
    DeliveryState? deliveryState,
    String? attachmentUri,
    String? attachmentMimeType,
    int? attachmentSizeBytes,
  }) {
    return SmsMessage(
      id: id,
      threadId: threadId,
      address: address,
      timestamp: DateTime.utc(2026, 8, 18, 9, 30),
      isOutgoing: isOutgoing,
      body: body,
      subject: subject,
      deliveryState: deliveryState,
      attachmentUri: attachmentUri,
      attachmentMimeType: attachmentMimeType,
      attachmentSizeBytes: attachmentSizeBytes,
    );
  }

  group('synthetic ids', () {
    test('do not collide with the Matrix id namespace', () {
      // A real room id starts `!` and a real event id `$`. Keeping SMS in its
      // own scheme means anything that mixes the two up is visible on sight
      // rather than after a failed federation call.
      expect(smsRoomId('7'), 'sms:thread:7');
      expect(smsEventId('42'), 'sms:msg:42');
      expect(smsRoomId('7'), isNot(startsWith('!')));
      expect(smsEventId('42'), isNot(startsWith(r'$')));
    });

    test('key the handle on the number, so re-syncing upserts', () {
      const parser = PhoneNumberParser(defaultCountryCode: '44');
      final national = parser.parse('01234 567890')!;
      final international = parser.parse('+44 1234 567890')!;

      expect(smsHandleId(national), smsHandleId(international));
      expect(smsHandleId(national), 'sms:+441234567890');
    });
  });

  group('smsDeliveryState', () {
    test('gives a received message no delivery state at all', () {
      // Ticks belong to messages the user sent. Painting them on a received
      // bubble is wrong in a way that looks deliberate.
      expect(smsDeliveryState(type: SmsProviderType.inbox), isNull);
      expect(smsDeliveryState(type: SmsProviderType.draft), isNull);
    });

    test('maps the outgoing types', () {
      expect(
        smsDeliveryState(type: SmsProviderType.outbox),
        DeliveryState.sending,
      );
      expect(
        smsDeliveryState(type: SmsProviderType.queued),
        DeliveryState.sending,
      );
      expect(
        smsDeliveryState(type: SmsProviderType.failed),
        DeliveryState.failed,
      );
    });

    test('reads the delivery report when one came back', () {
      expect(
        smsDeliveryState(
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
        DeliveryState.delivered,
      );
      expect(
        smsDeliveryState(
          type: SmsProviderType.sent,
          status: SmsProviderStatus.failed,
        ),
        DeliveryState.failed,
      );
    });

    test('treats a sent message with no report as sent, not stuck', () {
      // Most carriers charge for delivery reports and most users never enable
      // them, so `none` is the common case — degrading it to `sending` would
      // leave a permanent spinner on nearly every SMS the user ever sends.
      expect(smsDeliveryState(type: SmsProviderType.sent), DeliveryState.sent);
      expect(
        smsDeliveryState(
          type: SmsProviderType.sent,
          status: SmsProviderStatus.pending,
        ),
        DeliveryState.sent,
      );
    });

    test('never claims a message was read', () {
      // SMS has no read receipts. Every reachable input is checked here because
      // the moment one of them returns `read`, the UI is asserting something
      // the network cannot know.
      final states = [
        for (final type in [1, 2, 3, 4, 5, 6, 99])
          for (final status in [-1, 0, 32, 64])
            smsDeliveryState(type: type, status: status),
      ];

      expect(states, isNot(contains(DeliveryState.read)));
    });
  });

  group('SmsMessage.toWeftMessage', () {
    test('maps a received text onto the SMS network', () {
      final mapped = message().toWeftMessage(senderName: 'Anna Maven');

      expect(mapped.network, ChatNetwork.sms);
      expect(mapped.roomId, 'sms:thread:7');
      expect(mapped.eventId, 'sms:msg:42');
      expect(mapped.kind, MessageKind.text);
      expect(mapped.isOwn, isFalse);
      expect(mapped.body, 'on my way');
      expect(mapped.senderId, '+441234567890');
      expect(mapped.senderName, 'Anna Maven');
      expect(mapped.deliveryState, isNull);
    });

    test('falls back to the raw address when contacts resolved nothing', () {
      // Which is what every other SMS app shows, and better than a blank.
      expect(message().toWeftMessage().senderName, '+441234567890');
    });

    test('carries an outgoing delivery state through', () {
      final mapped = message(
        isOutgoing: true,
        deliveryState: DeliveryState.delivered,
      ).toWeftMessage();

      expect(mapped.isOwn, isTrue);
      expect(mapped.deliveryState, DeliveryState.delivered);
    });

    test('derives the kind of an MMS from its attachment', () {
      final mapped = message(
        body: '',
        attachmentUri: 'content://mms/part/9',
        attachmentMimeType: 'image/jpeg',
        attachmentSizeBytes: 90 * 1024,
      ).toWeftMessage();

      expect(mapped.kind, MessageKind.image);
      expect(mapped.attachmentUrl, 'content://mms/part/9');
      expect(mapped.mediaSizeBytes, 90 * 1024);
    });

    test('puts an MMS subject above the body', () {
      final mapped = message(subject: 'Weekend').toWeftMessage();
      expect(mapped.body, 'Weekend\non my way');

      // The common case is no subject, and an empty one must not add a blank
      // first line to every bubble.
      expect(message(subject: '').toWeftMessage().body, 'on my way');
    });
  });

  group('SmsThread.toChat', () {
    test('produces a single-source chat on the SMS network', () {
      final thread = SmsThread(
        id: '7',
        addresses: const ['+441234567890'],
        title: 'Anna Maven',
        unreadCount: 2,
        lastMessageAt: DateTime.utc(2026, 8, 18),
      );

      final chat = thread.toChat(
        lastMessage: message().toWeftMessage(),
        handleId: 'sms:+441234567890',
      );

      expect(chat.id, 'sms:thread:7');
      expect(chat.title, 'Anna Maven');
      expect(chat.networks, [ChatNetwork.sms]);
      expect(chat.sendNetwork, ChatNetwork.sms);
      expect(chat.isMerged, isFalse);
      expect(chat.unreadCount, 2);
      expect(chat.sources.single.handleId, 'sms:+441234567890');
    });

    test('labels an unnamed thread with its participants', () {
      const thread = SmsThread(id: '9', addresses: ['+441234567890']);
      expect(thread.toChat().title, '+441234567890');
    });

    test('treats a multi-participant thread as a group', () {
      const thread = SmsThread(
        id: '9',
        addresses: ['+441234567890', '+441234567891'],
      );

      expect(thread.isGroup, isTrue);
      expect(thread.toChat().isGroup, isTrue);
      expect(thread.toChat().title, '+441234567890, +441234567891');
    });

    test('never merges itself', () {
      // Folding an SMS thread together with the WhatsApp chat for the same
      // number is the merge engine's decision, reached from the evidence
      // linkSmsIdentity contributes — a chat that merged itself would bypass
      // the confirmation the user is owed.
      const thread = SmsThread(id: '9', addresses: ['+441234567890']);
      expect(thread.toChat().sources, hasLength(1));
      expect(thread.toChat().isMerged, isFalse);
    });
  });
}
