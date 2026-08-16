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
  });
}
