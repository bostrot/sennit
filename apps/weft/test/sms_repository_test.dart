import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/sms_chat_repository.dart';
import 'package:weft/services/contacts/contact_book.dart';
import 'package:weft/services/sms/sms_platform.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_sms/weft_sms.dart';

import 'support/sms_fixtures.dart';

/// The repository half of the SMS integration, against a fake method channel.
///
/// `sms_platform_test.dart` covers what a provider row decodes to. What is
/// tested here is everything the layer above decides: which rows become inbox
/// rows, which thread a message joins, whether a delivery report changes a
/// bubble or adds one, what reaches the search index, and — the reason SMS is
/// in this app at all — whether an SMS thread and a bridged chat for the same
/// number become one merge suggestion.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSmsChannel platform;
  late SmsPlatform gateway;
  late SmsChatRepository sms;

  /// What the search index was handed, as `<chatId> <- <eventIds>`.
  late List<String> indexed;

  Future<void> start({PhoneNumberParser? parser}) async {
    sms =
        SmsChatRepository(
            gateway: gateway,
            parser: parser ?? const PhoneNumberParser(defaultCountryCode: '44'),
          )
          ..indexer = (roomId, messages, {String chatTitle = ''}) => indexed
              .add('$roomId <- ${messages.map((m) => m.eventId).join(',')}');
    await sms.start();
  }

  setUp(() {
    indexed = [];
    platform = FakeSmsChannel();
    gateway = SmsPlatform(channel: platform.channel);
  });

  tearDown(() async {
    await sms.dispose();
    await gateway.dispose();
    platform.dispose();
  });

  group('the inbox', () {
    test('threads become chats on the SMS network', () async {
      platform.threads = [
        smsThreadRow(id: '7', title: 'Anna', unreadCount: 2),
        smsThreadRow(
          id: '8',
          addresses: const ['+441234567891'],
          snippet: 'ok',
          lastMessageAt: 1600000000000,
        ),
      ];

      await start();

      final chats = sms.chats;
      expect(chats, hasLength(2));
      // Newest activity first, like every other source in the inbox.
      expect(chats.first.id, 'sms:thread:7');
      expect(chats.first.title, 'Anna');
      expect(chats.first.networks, [ChatNetwork.sms]);
      expect(chats.first.unreadCount, 2);
      expect(chats.first.isMerged, isFalse);
      // The preview is the provider's snippet until the thread is opened, and
      // it must not claim the user wrote it.
      expect(chats.first.lastMessage?.body, 'see you at six');
      expect(chats.first.lastMessage?.isOwn, isFalse);
    });

    test('a thread with no title is named by its participants', () async {
      platform.threads = [smsThreadRow(title: null)];

      await start();

      expect(sms.chats.single.title, '+441234567890');
    });

    test('a declined role leaves the inbox empty and asks nothing', () async {
      platform.status = const {
        'supported': true,
        'isDefault': false,
        'canRequestRole': true,
        'hasPermissions': false,
      };
      platform.threads = [smsThreadRow()];

      await start();

      expect(sms.isReady, isFalse);
      expect(sms.chats, isEmpty);
      // The whole point of the graceful decline: nothing is read, so no
      // permission is touched and no error is shown.
      expect(platform.calls, isNot(contains('getThreads')));
    });

    test('a device with no telephony never reads anything', () async {
      platform.status = const {'supported': false};

      await start();

      expect(sms.status.availability, SmsAvailability.unsupported);
      expect(sms.chats, isEmpty);
    });
  });

  group('messages', () {
    test('provider rows become WeftMessages with ChatNetwork.sms', () async {
      platform.threads = [smsThreadRow(title: 'Anna')];
      platform.messages = [
        smsRow(id: '11', body: 'hello', timestamp: 1700000000000),
        smsRow(
          id: '12',
          body: 'hi back',
          timestamp: 1700000001000,
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
      ];

      await start();
      final source = await sms.openTimeline('sms:thread:7');
      await source!.loadMore();

      final messages = source.loaded;
      expect(source.network, ChatNetwork.sms);
      // Newest first, as every timeline source promises.
      expect(messages.first.eventId, 'sms:msg:12');
      expect(messages.first.roomId, 'sms:thread:7');
      expect(messages.first.network, ChatNetwork.sms);
      expect(messages.first.isOwn, isTrue);
      expect(messages.first.deliveryState, DeliveryState.delivered);

      expect(messages.last.eventId, 'sms:msg:11');
      expect(messages.last.isOwn, isFalse);
      // A received message has no delivery state at all — the ticks belong to
      // messages the user sent.
      expect(messages.last.deliveryState, isNull);
      expect(messages.last.senderName, 'Anna');
    });

    test('an incoming message reaches an open thread and the inbox', () async {
      platform.threads = [smsThreadRow(unreadCount: 0)];
      platform.messages = [smsRow(id: '11')];

      await start();
      final source = await sms.openTimeline('sms:thread:7');
      await source!.loadMore();

      await platform.emit(
        'onSmsReceived',
        smsRow(id: '12', body: 'are you there', timestamp: 1700000005000),
      );

      expect(source.loaded.first.eventId, 'sms:msg:12');
      expect(source.loaded.first.body, 'are you there');
      // The inbox row follows: preview, and one more unread.
      expect(sms.chats.single.lastMessage?.body, 'are you there');
      expect(sms.chats.single.unreadCount, 1);
    });

    test('a message for an unknown thread creates one', () async {
      // An SMS can start the process, so the first thing Weft ever learns
      // about a conversation is sometimes a message in it.
      await start();
      expect(sms.chats, isEmpty);

      await platform.emit('onSmsReceived', smsRow(threadId: '99', body: 'hi'));

      expect(sms.chats, hasLength(1));
      expect(sms.chats.single.id, 'sms:thread:99');
      expect(sms.chats.single.unreadCount, 1);
    });

    test('loading older re-reads the provider with a deeper limit', () async {
      platform.threads = [smsThreadRow()];
      platform.messagesByThread = {
        '7': [
          for (var i = 0; i < 400; i++)
            smsRow(id: '$i', timestamp: 1700000000000 - i * 1000),
        ],
      };

      await start();
      final source = await sms.openTimeline('sms:thread:7');

      // The first read is capped, so the source has to go back for more.
      expect(platform.messageLimits, [kSmsReadLimit]);
      for (var round = 0; round < 8; round++) {
        await source!.loadMore(count: 30);
      }
      // Six full pages, a short one that exhausts the first read, then the
      // eighth round pays for a deeper read and pages again.
      expect(source!.loaded, hasLength(230));
      expect(platform.messageLimits.last, greaterThan(kSmsReadLimit));
      expect(source.hasMore, isTrue);
    });
  });

  group('delivery reports', () {
    test('a report updates the bubble rather than adding one', () async {
      platform.threads = [smsThreadRow()];
      platform.messages = [
        smsRow(id: '11', type: SmsProviderType.outbox, body: 'on its way'),
      ];

      await start();
      final source = await sms.openTimeline('sms:thread:7');
      await source!.loadMore();
      expect(source.loaded.single.deliveryState, DeliveryState.sending);

      await platform.emit(
        'onSmsStatus',
        smsRow(
          id: '11',
          body: 'on its way',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
      );

      expect(source.loaded, hasLength(1), reason: 'no second bubble');
      expect(source.loaded.single.deliveryState, DeliveryState.delivered);
    });

    test('a failed report is failed, not silently sent', () async {
      platform.threads = [smsThreadRow()];
      platform.messages = [smsRow(id: '11', type: SmsProviderType.outbox)];

      await start();
      final source = await sms.openTimeline('sms:thread:7');
      await source!.loadMore();

      await platform.emit(
        'onSmsStatus',
        smsRow(
          id: '11',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.failed,
        ),
      );

      expect(source.loaded.single.deliveryState, DeliveryState.failed);
    });

    test('a report for an unopened thread still moves the preview', () async {
      platform.threads = [smsThreadRow()];
      await start();

      // The sent message becomes the preview...
      platform.sentRow = smsRow(id: '20', type: SmsProviderType.outbox);
      await sms.send('sms:thread:7', 'hello');
      expect(
        sms.chats.single.lastMessage?.deliveryState,
        DeliveryState.sending,
      );

      // ...and its report changes that preview's tick, with nothing open.
      await platform.emit(
        'onSmsStatus',
        smsRow(
          id: '20',
          type: SmsProviderType.sent,
          status: SmsProviderStatus.complete,
        ),
      );
      expect(
        sms.chats.single.lastMessage?.deliveryState,
        DeliveryState.delivered,
      );
    });
  });

  group('sending', () {
    test('a sent message is stored and shown immediately', () async {
      platform.threads = [smsThreadRow()];
      platform.sentRow = smsRow(
        id: '20',
        type: SmsProviderType.outbox,
        body: 'on my way',
      );

      await start();
      await sms.send('sms:thread:7', 'on my way');

      expect(platform.arguments['sendMessage'], {
        'address': '+441234567890',
        'body': 'on my way',
      });
      final preview = sms.chats.single.lastMessage;
      expect(preview?.body, 'on my way');
      expect(preview?.isOwn, isTrue);
      // Outbox, not sent: the radio has it, the network has not confirmed it.
      expect(preview?.deliveryState, DeliveryState.sending);
    });

    test('a refusal by the device reaches the composer', () async {
      platform.threads = [smsThreadRow()];
      platform.sentRow = null;

      await start();

      expect(
        () => sms.send('sms:thread:7', 'hello'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'a group MMS thread refuses rather than messaging one member',
      () async {
        platform.threads = [
          smsThreadRow(addresses: const ['+441234567890', '+441234567891']),
        ];

        await start();

        // Quietly sending to the first participant would look like a group reply
        // and be a private message.
        expect(
          () => sms.send('sms:thread:7', 'hello all'),
          throwsA(isA<StateError>()),
        );
        expect(platform.calls, isNot(contains('sendMessage')));
      },
    );
  });

  group('search', () {
    test('loaded and incoming bodies are handed to the index', () async {
      platform.threads = [smsThreadRow(title: 'Anna')];
      platform.messages = [smsRow(id: '11', body: 'dinner at eight')];

      await start();
      await sms.openTimeline('sms:thread:7');
      await platform.emit('onSmsReceived', smsRow(id: '12', body: 'confirmed'));

      expect(indexed, [
        'sms:thread:7 <- sms:msg:11',
        'sms:thread:7 <- sms:msg:12',
      ]);
    });
  });

  group('merging', () {
    test('an SMS thread and a WhatsApp chat for one number merge', () async {
      // The claim the whole network exists to demonstrate. The SMS side is in
      // national format, the bridge's is international, and neither carries a
      // display name — so the only thing that can join them is the number.
      platform.threads = [
        smsThreadRow(addresses: const ['01234 567890']),
      ];

      await start();

      final graph = IdentityGraph(
        handles: const [
          NetworkHandle(
            id: 'wa-anna',
            network: ChatNetwork.whatsapp,
            remoteId: '441234567890',
            matrixUserId: '@whatsapp_441234567890:example.org',
            roomId: '!wa:example.org',
            phoneE164: '+441234567890',
          ),
        ],
      );
      for (final handle in sms.handles) {
        graph.upsertHandle(handle);
      }

      final suggestions = graph.suggestions();
      expect(suggestions, hasLength(1));
      expect(suggestions.single.score, closeTo(0.95, 0.001));
      expect(
        suggestions.single.signals.map((s) => s.name),
        contains(MergeSignal.phoneExact.name),
      );

      // And it is only ever a *suggestion*: an SMS number is recycled, spoofed
      // and shared, so nothing merges without the user saying so.
      expect(
        graph.contactIdOf('wa-anna'),
        isNot(graph.contactIdOf('sms:+441234567890')),
      );
    });

    test('the chat carries the handle its merge would be keyed on', () async {
      platform.threads = [smsThreadRow()];

      await start();

      expect(sms.chats.single.sources.single.handleId, 'sms:+441234567890');
    });

    test('a near-miss number is not evidence', () async {
      platform.threads = [
        smsThreadRow(addresses: const ['+441234567891']),
      ];

      await start();

      final graph = IdentityGraph(
        handles: const [
          NetworkHandle(
            id: 'wa-anna',
            network: ChatNetwork.whatsapp,
            remoteId: '441234567890',
            matrixUserId: '@whatsapp_441234567890:example.org',
            phoneE164: '+441234567890',
          ),
        ],
      );
      for (final handle in sms.handles) {
        graph.upsertHandle(handle);
      }

      expect(graph.suggestions(), isEmpty);
    });

    test('a short code is never a person', () async {
      // Two banks share one aggregator's code and the same five digits mean
      // different things in different countries.
      platform.threads = [
        smsThreadRow(addresses: const ['20202']),
      ];

      await start();

      expect(sms.handles, isEmpty);
      expect(sms.chats.single.sources.single.handleId, isNull);
      // The thread itself is still there — the alert is a conversation, it is
      // just not a person who can be merged.
      expect(sms.chats, hasLength(1));
    });

    test('a group thread contributes no handles', () async {
      // Merging two group conversations is not a "same person" question, and a
      // member's handle carrying the group's room id would fold that whole
      // thread into somebody's DM.
      platform.threads = [
        smsThreadRow(addresses: const ['+441234567890', '+441234567891']),
      ];

      await start();

      expect(sms.handles, isEmpty);
    });
  });

  group('read state', () {
    test('marking read clears the badge and tells the provider', () async {
      platform.threads = [smsThreadRow(unreadCount: 3)];

      await start();
      expect(sms.chats.single.unreadCount, 3);

      await sms.markRead('sms:thread:7');

      expect(platform.arguments['markThreadRead'], {'threadId': '7'});
      expect(sms.chats.single.unreadCount, 0);
    });
  });

  group('contacts', () {
    /// An address book in the formats people actually save numbers in.
    final book = ContactBook.fromEntries([
      (name: 'Anna', photoPath: '/c/anna.jpg', numbers: ['07700 900123']),
      (name: 'Ben', photoPath: null, numbers: ['+44 7700-900456']),
      (name: 'Bank', photoPath: null, numbers: ['22020']),
    ]);

    test('threads read before contacts are renamed once they arrive', () async {
      platform.threads = [
        smsThreadRow(id: '1', addresses: const ['+447700900123']),
        smsThreadRow(id: '2', addresses: const ['07700 900456']),
        smsThreadRow(id: '3', addresses: const ['22020']),
        smsThreadRow(id: '4', addresses: const ['+447700900999']),
      ];
      await start();
      expect(sms.chats.map((c) => c.title), contains('+447700900123'));

      var emitted = 0;
      final sub = sms.updates.listen((_) => emitted++);
      sms.setContacts(book);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(emitted, 1);
      final byId = {for (final c in sms.chats) c.id: c};
      expect(byId['sms:thread:1']?.title, 'Anna');
      expect(byId['sms:thread:1']?.avatarUrl, 'file:///c/anna.jpg');
      expect(byId['sms:thread:2']?.title, 'Ben');
      expect(byId['sms:thread:3']?.title, 'Bank');
      // A stranger stays a number.
      expect(byId['sms:thread:4']?.title, '+447700900999');
      expect(byId['sms:thread:4']?.avatarUrl, isNull);
      // The inbox preview speaks with the same name.
      expect(byId['sms:thread:1']?.lastMessage?.senderName, 'Anna');
    });

    test('turning contacts off brings the numbers back', () async {
      platform.threads = [
        smsThreadRow(addresses: const ['+447700900123']),
      ];
      await start();
      sms.setContacts(book);
      expect(sms.chats.single.title, 'Anna');

      sms.setContacts(ContactBook.empty);

      expect(sms.chats.single.title, '+447700900123');
    });

    test('a group is named by its members', () async {
      platform.threads = [
        smsThreadRow(
          addresses: const ['+447700900123', '+447700900456', '+447700900999'],
        ),
      ];
      await start();
      sms.setContacts(book);

      expect(sms.chats.single.title, 'Anna, Ben, +447700900999');
      expect(sms.chats.single.avatarUrl, isNull);
    });

    test('received messages carry the contact name', () async {
      platform.threads = [
        smsThreadRow(addresses: const ['+447700900123']),
      ];
      platform.messages = [smsRow(id: '11', address: '+447700900123')];
      await start();
      sms.setContacts(book);

      final timeline = await sms.openTimeline('sms:thread:7');
      await timeline!.loadMore();

      expect(timeline.loaded.single.senderName, 'Anna');
    });

    test('the platform E.164 makes a national thread merge evidence', () async {
      // No region on the parser: on its own `07700 900123` names nobody. The
      // platform read it against the SIM's country.
      platform.threads = [
        smsThreadRow(
          addresses: const ['07700 900123'],
          e164: const {'07700 900123': '+447700900123'},
        ),
      ];
      await start(parser: const PhoneNumberParser());
      sms.setContacts(book);

      final handle = sms.handles.single;
      expect(handle.phoneE164, '+447700900123');
      expect(handle.displayName, 'Anna');
      expect(handle.avatarUrl, 'file:///c/anna.jpg');
      expect(sms.chats.single.sources.single.handleId, 'sms:+447700900123');

      final graph = IdentityGraph(
        handles: const [
          NetworkHandle(
            id: 'wa-anna',
            network: ChatNetwork.whatsapp,
            remoteId: '447700900123',
            matrixUserId: '@whatsapp_447700900123:example.org',
            roomId: '!wa:example.org',
            phoneE164: '+447700900123',
          ),
        ],
      );
      for (final handle in sms.handles) {
        graph.upsertHandle(handle);
      }
      expect(graph.suggestions(), hasLength(1));
    });
  });
}
