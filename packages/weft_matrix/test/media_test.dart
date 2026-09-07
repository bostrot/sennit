import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  /// A client pointed at a homeserver, nothing more.
  ///
  /// Nothing here syncs or logs in — both functions under test read three
  /// fields and build a string — so the in-memory database is only there
  /// because the SDK will not construct a client without one.
  late sdk.MatrixSdkDatabase database;

  setUpAll(() async {
    database = await sdk.MatrixSdkDatabase.init(
      'weft-media-test',
      database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
    );
  });

  sdk.Client clientAt(String? homeserver, {String? token}) =>
      sdk.Client('media_test', database: database)
        ..homeserver = homeserver == null ? null : Uri.parse(homeserver)
        ..accessToken = token;

  const mxc = 'mxc://media.example.org/AbCdEf123';

  group('mxcToDownloadUrl', () {
    test('uses the authenticated endpoint when the server has one', () {
      expect(
        mxcToDownloadUrl(
          clientAt('https://matrix.example.org'),
          mxc,
          authenticatedMedia: true,
        ),
        'https://matrix.example.org/_matrix/client/v1/media/download'
        '/media.example.org/AbCdEf123',
      );
    });

    // Servers older than spec v1.11 only serve the legacy path, and asking the
    // wrong one 404s — which to the user is a save that produced nothing.
    test('falls back to the legacy media endpoint', () {
      expect(
        mxcToDownloadUrl(
          clientAt('https://matrix.example.org'),
          mxc,
          authenticatedMedia: false,
        ),
        'https://matrix.example.org/_matrix/media/v3/download'
        '/media.example.org/AbCdEf123',
      );
    });

    // The download is the *original*, not a crop: a Save that quietly wrote a
    // 96-pixel thumbnail would look like it had worked.
    test('carries no thumbnail sizing at all', () {
      final url = mxcToDownloadUrl(
        clientAt('https://matrix.example.org'),
        mxc,
        authenticatedMedia: true,
      );
      expect(url, isNot(contains('width')));
      expect(url, isNot(contains('method=crop')));
      expect(Uri.parse(url!).queryParameters, isEmpty);
    });

    test('keeps a non-standard homeserver port', () {
      expect(
        mxcToDownloadUrl(
          clientAt('https://matrix.example.org:8448'),
          mxc,
          authenticatedMedia: true,
        ),
        startsWith('https://matrix.example.org:8448/'),
      );
    });

    test('keeps the media server port, which is not the homeserver port', () {
      expect(
        mxcToDownloadUrl(
          clientAt('https://matrix.example.org'),
          'mxc://media.example.org:8448/AbCdEf123',
          authenticatedMedia: true,
        ),
        contains('/media.example.org:8448/AbCdEf123'),
      );
    });

    test('passes an already-HTTP url through untouched', () {
      const direct = 'https://cdn.example.org/photo.jpg';
      expect(
        mxcToDownloadUrl(
          clientAt('https://matrix.example.org'),
          direct,
          authenticatedMedia: true,
        ),
        direct,
      );
    });

    test('returns null rather than a broken url', () {
      final client = clientAt('https://matrix.example.org');
      expect(mxcToDownloadUrl(client, null, authenticatedMedia: true), isNull);
      expect(mxcToDownloadUrl(client, '', authenticatedMedia: true), isNull);
      expect(
        mxcToDownloadUrl(client, 'mxc://', authenticatedMedia: true),
        isNull,
      );
      expect(
        mxcToDownloadUrl(client, 'not a uri at all', authenticatedMedia: true),
        isNull,
      );
      expect(
        mxcToDownloadUrl(clientAt(null), mxc, authenticatedMedia: true),
        isNull,
      );
    });

    // The regression the shared helper protects: two endpoints built by one
    // function must differ in the verb and in nothing else.
    test('agrees with the thumbnail url on everything but the endpoint', () {
      final client = clientAt('https://matrix.example.org');
      final download = mxcToDownloadUrl(client, mxc, authenticatedMedia: true)!;
      final thumbnail = mxcToThumbnailUrl(
        client,
        mxc,
        authenticatedMedia: true,
      )!;
      expect(
        Uri.parse(download).path.replaceFirst('download', 'thumbnail'),
        Uri.parse(thumbnail).path,
      );
    });
  });

  group('attachmentServesAsThumbnail', () {
    // The rule this started as, kept because a photo with no thumbnail block is
    // the ordinary case on several bridges and the picture is its own preview.
    test('a picture is its own preview', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Image,
          mimetype: 'image/jpeg',
        ),
        isTrue,
      );
    });

    // The bug this was written for: WhatsApp stickers arrive as `m.sticker`
    // with a WebP inline and no thumbnail beside it, and the old msgtype test
    // refused the file — so every sticker drew a broken-image glyph.
    test('a sticker with no thumbnail is its own preview', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Sticker,
          mimetype: 'image/webp',
        ),
        isTrue,
      );
    });

    // `info.mimetype` is optional on the wire and some bridges omit it. A
    // sticker is small enough that guessing "picture" and being wrong is
    // cheaper than showing nothing for every sticker that skipped the key.
    test('a sticker that declares no mimetype is allowed through', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Sticker,
          mimetype: '',
        ),
        isTrue,
      );
    });

    // Telegram's animated stickers: an `m.sticker` carrying WebM, which is the
    // film case wearing a sticker's msgtype. Downloading it would spend the
    // bytes to arrive at the same broken glyph.
    test('a video sticker is not, however it is labelled', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Sticker,
          mimetype: 'video/webm',
        ),
        isFalse,
      );
    });

    test('a video is not', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Video,
          mimetype: 'video/mp4',
        ),
        isFalse,
      );
    });

    // A PDF's first page is not a thumbnail, and an `m.file` that happens to be
    // a picture is one the sender chose to send as a file.
    test('a file is not, whatever it holds', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.File,
          mimetype: 'image/png',
        ),
        isFalse,
      );
    });

    // The SDK's `messageType` falls back to `m.text` for content with no
    // msgtype at all, so this is the shape a malformed event arrives in.
    test('a message with no msgtype is not', () {
      expect(
        attachmentServesAsThumbnail(
          messageType: sdk.MessageTypes.Text,
          mimetype: '',
        ),
        isFalse,
      );
    });
  });

  group('mediaAuthHeaders', () {
    test('is a bearer header when there is a token', () {
      expect(
        mediaAuthHeaders(clientAt('https://x.example.org', token: 'tok')),
        {'authorization': 'Bearer tok'},
      );
    });

    test('is null when there is none, rather than an empty bearer', () {
      expect(mediaAuthHeaders(clientAt('https://x.example.org')), isNull);
      expect(
        mediaAuthHeaders(clientAt('https://x.example.org', token: '')),
        isNull,
      );
    });
  });
}
