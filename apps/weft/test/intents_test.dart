import 'package:flutter_test/flutter_test.dart';

import 'package:weft/app/intents.dart';

void main() {
  group('WeftLink.parse', () {
    test('opens a chat from both schemes identically', () {
      final custom = WeftLink.parse('weft://chat/!abc:example.org');
      final web = WeftLink.parse(
        'https://weft.bostrot.com/chat/!abc:example.org',
      );

      expect(custom, isA<OpenChatLink>());
      expect(web, isA<OpenChatLink>());
      expect(
        (custom! as OpenChatLink).chatId,
        (web! as OpenChatLink).chatId,
        reason: 'a shared web link and the app scheme must behave the same',
      );
    });

    test('decodes percent-encoded room ids', () {
      final link = WeftLink.parse('weft://chat/%21abc%3Aexample.org');
      expect((link! as OpenChatLink).chatId, '!abc:example.org');
    });

    test('decodes exactly once', () {
      // `Uri.pathSegments` has already decoded the segment, so a second
      // `Uri.decodeComponent` on top of it either does nothing — which is why
      // this went unnoticed for every id Weft generates — or corrupts an id
      // that legitimately contains a `%`. `%2521` is an escaped `%21`: the id
      // is the literal five characters `%21`, not `!`.
      expect(
        (WeftLink.parse('weft://chat/%2521')! as OpenChatLink).chatId,
        '%21',
      );
      expect(
        (WeftLink.parse('weft://user/%2540anna%3Aexample.org')! as OpenUserLink)
            .userId,
        '%40anna:example.org',
      );
    });

    test('an id a second decode would throw on still parses', () {
      // The failure this fixes: `Uri.decodeComponent('100% done')` is an
      // `ArgumentError`, thrown out of a method whose contract is that an
      // unknown link must not crash the router. Links arrive from outside the
      // app's control, and a notification's deep link is built from a chat id
      // Weft does not choose the shape of.
      for (final entry in {
        'weft://chat/100%25%20done': '100% done',
        'weft://chat/%25zz': '%zz',
        'weft://chat/gr%C3%BC%C3%9Fe': 'grüße',
        'https://weft.bostrot.com/chat/100%25': '100%',
      }.entries) {
        final link = WeftLink.parse(entry.key);
        expect(link, isA<OpenChatLink>(), reason: entry.key);
        expect((link! as OpenChatLink).chatId, entry.value, reason: entry.key);
      }
    });

    test('a notification link round-trips the chat id it was built from', () {
      // `notificationLinkFor` in `weft_notify` is one `Uri.encodeComponent`, so
      // this is the other half of the round trip a notification tap makes. The
      // merged id is the case that matters: tapping a merged contact's
      // notification must open the merged conversation, not one source room.
      for (final chatId in [
        'merged:contact_1730000000000_0',
        '!abc:example.org',
        '!weird +/:example.org',
        '!100%:example.org',
        '!grüße:example.org',
      ]) {
        final link = WeftLink.parse(
          'weft://chat/${Uri.encodeComponent(chatId)}',
        );
        expect((link! as OpenChatLink).chatId, chatId, reason: chatId);
      }
    });

    test('parses user and search links', () {
      expect(
        (WeftLink.parse('weft://user/@anna:example.org')! as OpenUserLink)
            .userId,
        '@anna:example.org',
      );
      expect(
        (WeftLink.parse('https://weft.bostrot.com/search?q=trial')!
                as OpenSearchLink)
            .query,
        'trial',
      );
    });

    test('a bare link opens the inbox', () {
      expect(WeftLink.parse('weft://'), isA<OpenInboxLink>());
    });

    test('rejects other hosts — a link is not trusted for being https', () {
      expect(WeftLink.parse('https://evil.example.com/chat/x'), isNull);
      expect(
        WeftLink.parse('https://weft.bostrot.com.evil.com/chat/x'),
        isNull,
      );
    });

    test('rejects malformed input without throwing', () {
      for (final bad in ['', 'not a url', 'weft://chat/', 'weft://unknown/x']) {
        expect(WeftLink.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('SharedPayload', () {
    test('parses a platform payload', () {
      final payload = SharedPayload.fromMap(const {
        'text': 'hello',
        'mimeType': 'text/plain',
        'uris': ['content://media/1', 42, 'content://media/2'],
      });

      expect(payload.text, 'hello');
      expect(
        payload.uris,
        hasLength(2),
        reason: 'non-string entries are dropped, not crashed on',
      );
      expect(payload.isEmpty, isFalse);
    });

    test('whitespace-only text with no files is empty', () {
      expect(SharedPayload.fromMap(const {'text': '  '}).isEmpty, isTrue);
    });

    test('a Direct Share tap carries the chat it was aimed at', () {
      // What `MainActivity` builds from an `EXTRA_SHORTCUT_ID` it resolved: a
      // `Chat.id`, not the sanitised shortcut id, because the sanitising is
      // lossy and only the platform kept the map.
      final payload = SharedPayload.fromMap(const {
        'uris': ['content://media/1'],
        'targetChatId': 'merged:contact_1',
      });

      expect(payload.targetChatId, 'merged:contact_1');
    });

    test('an unresolved shortcut is the same as no target', () {
      // Null is what the platform sends for a plain share and for a shortcut it
      // could not resolve — a build older than the id map, or one published
      // before a logout cleared it. Both mean "ask", and the empty string means
      // the same thing rather than pre-selecting a chat with no id.
      for (final absent in [null, '', '   ', 42]) {
        expect(
          SharedPayload.fromMap({
            'uris': const ['content://media/1'],
            'targetChatId': absent,
          }).targetChatId,
          isNull,
          reason: 'targetChatId: $absent',
        );
      }
    });
  });
}
