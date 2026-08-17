import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  group('MatrixAttachmentTransport.upload', () {
    test(
      'posts the bytes to the v3 upload endpoint and returns the mxc URI',
      () async {
        late http.Request seen;
        final transport = _transportWith(
          MockClient((request) async {
            seen = request;
            return _uriResponse('mxc://example.org/abc');
          }),
        );

        final uri = await transport.upload(
          _bytes(1024),
          mimeType: 'image/jpeg',
          uploadId: 'task-1',
        );

        expect(uri, 'mxc://example.org/abc');
        expect(seen.method, 'POST');
        expect(seen.url.path, '/_matrix/media/v3/upload');
        expect(seen.headers['authorization'], 'Bearer token-1');
        expect(seen.headers['content-type'], 'image/jpeg');
        expect(seen.bodyBytes, hasLength(1024));
      },
    );

    test('never sends a filename in the query string', () async {
      // For an encrypted room the body is ciphertext but a filename in the URL
      // is not, so this is a leak the transport must not have.
      late Uri url;
      final transport = _transportWith(
        MockClient((request) async {
          url = request.url;
          return _uriResponse('mxc://example.org/abc');
        }),
      );

      await transport.upload(
        _bytes(16),
        mimeType: 'image/jpeg',
        uploadId: 'task-1',
      );

      expect(url.hasQuery, isFalse);
      expect(url.toString(), isNot(contains('filename')));
    });

    test('reads the token per call rather than capturing it', () async {
      // The SDK refreshes access tokens underneath us on soft logout.
      final session = _FakeSession(
        MockClient((request) async {
          return _uriResponse('mxc://example.org/abc');
        }),
      );
      final transport = MatrixAttachmentTransport(session: session);

      session.accessToken = 'refreshed';
      await transport.upload(
        _bytes(8),
        mimeType: 'text/plain',
        uploadId: 'task-1',
      );

      expect(session.lastAuthorization, 'Bearer refreshed');
    });

    test('refuses without a session, and does not offer a retry', () async {
      final session = _FakeSession(MockClient((_) async => _uriResponse('x')))
        ..accessToken = null;
      final transport = MatrixAttachmentTransport(session: session);

      await expectLater(
        transport.upload(_bytes(8), mimeType: 'text/plain', uploadId: 't'),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('signed in')),
        ),
      );
    });

    test('reports byte-level progress as the body is streamed', () async {
      final transport = _transportWith(
        MockClient((_) async => _uriResponse('mxc://example.org/abc')),
      );
      final sent = <int>[];
      var total = 0;

      // Two and a bit chunks, so progress is genuinely intermediate rather than
      // a single jump from nothing to done.
      await transport.upload(
        _bytes(kUploadChunkBytes * 2 + 17),
        mimeType: 'video/mp4',
        uploadId: 'task-1',
        onProgress: (s, t) {
          sent.add(s);
          total = t;
        },
      );

      expect(total, kUploadChunkBytes * 2 + 17);
      expect(sent, [kUploadChunkBytes, kUploadChunkBytes * 2, total]);
    });

    test('cancel stops the body mid-flight', () async {
      var bodyBytesReceived = -1;
      final transport = _transportWith(
        MockClient((request) async {
          bodyBytesReceived = request.bodyBytes.length;
          return _uriResponse('mxc://example.org/abc');
        }),
      );

      await expectLater(
        transport.upload(
          _bytes(kUploadChunkBytes * 4),
          mimeType: 'video/mp4',
          uploadId: 'task-1',
          onProgress: (_, _) => transport.cancel('task-1'),
        ),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('cancelled')),
        ),
      );
      // The handler never ran: the stream threw before the body was complete.
      expect(bodyBytesReceived, -1);
    });

    test(
      'a retry under the same id is not aborted by the old cancellation',
      () async {
        // The queue reuses the task id across attempts, so a stale flag would
        // abort every subsequent try before it started.
        final transport = _transportWith(
          MockClient((_) async => _uriResponse('mxc://example.org/abc')),
        );
        transport.cancel('task-1');

        expect(
          await transport.upload(
            _bytes(64),
            mimeType: 'image/jpeg',
            uploadId: 'task-1',
          ),
          'mxc://example.org/abc',
        );
      },
    );

    test('cancelling an attachment cancels its thumbnail upload too', () async {
      final transport = _transportWith(
        MockClient((_) async => _uriResponse('mxc://example.org/abc')),
      );
      transport.cancel('task-1');

      await expectLater(
        transport.upload(
          _bytes(64),
          mimeType: 'image/jpeg',
          uploadId: MatrixAttachmentTransport.thumbnailUploadId('task-1'),
        ),
        throwsA(isA<AttachmentTransportException>()),
      );
    });
  });

  group('MatrixAttachmentTransport failures', () {
    test('413 is terminal — three attempts get the same refusal', () async {
      await expectLater(
        _uploadAgainst(http.Response('{"errcode":"M_TOO_LARGE"}', 413)),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.statusCode, 'statusCode', 413)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('401 is terminal and says to sign in again', () async {
      await expectLater(
        _uploadAgainst(http.Response('{"errcode":"M_UNKNOWN_TOKEN"}', 401)),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.message, 'message', contains('Sign in again')),
        ),
      );
    });

    test('403 surfaces the server sentence when there is one', () async {
      await expectLater(
        _uploadAgainst(
          http.Response(
            '{"errcode":"M_FORBIDDEN","error":"Uploads are disabled here."}',
            403,
          ),
        ),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having(
                (e) => e.message,
                'message',
                'Uploads are disabled here.',
              ),
        ),
      );
    });

    test('429 and 5xx are retryable', () async {
      await expectLater(
        _uploadAgainst(http.Response('{}', 429)),
        throwsA(
          isA<AttachmentTransportException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
      await expectLater(
        _uploadAgainst(http.Response('{}', 502)),
        throwsA(
          isA<AttachmentTransportException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });

    test(
      'an HTML error page from a proxy does not become a cast failure',
      () async {
        await expectLater(
          _uploadAgainst(
            http.Response('<html>504 Gateway Timeout</html>', 504),
          ),
          throwsA(
            isA<AttachmentTransportException>().having(
              (e) => e.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
      },
    );

    test('a dropped connection is retryable', () async {
      final transport = _transportWith(
        MockClient((_) async => throw http.ClientException('closed')),
      );

      await expectLater(
        transport.upload(_bytes(8), mimeType: 'text/plain', uploadId: 't'),
        throwsA(
          isA<AttachmentTransportException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having(
                (e) => e.message,
                'message',
                contains('reach the server'),
              ),
        ),
      );
    });

    test(
      'a 200 with no content_uri is terminal — retrying re-uploads for nothing',
      () async {
        await expectLater(
          _uploadAgainst(http.Response('{"ok":true}', 200)),
          throwsA(
            isA<AttachmentTransportException>()
                .having((e) => e.retryable, 'retryable', isFalse)
                .having(
                  (e) => e.message,
                  'message',
                  contains('did not say where'),
                ),
          ),
        );
      },
    );

    test('a non-mxc content_uri is refused rather than passed on', () async {
      await expectLater(
        _uploadAgainst(
          http.Response('{"content_uri":"https://example.org/file"}', 200),
        ),
        throwsA(isA<AttachmentTransportException>()),
      );
    });
  });

  group('MatrixAttachmentTransport.preparePayload', () {
    test('a plain room sends the file itself, with no key material', () async {
      final transport = _transportWith(
        MockClient((_) async => _uriResponse('x')),
      );

      final payload = await transport.preparePayload(
        _bytes(32),
        encrypted: false,
      );

      expect(payload.bytes, hasLength(32));
      expect(payload.file, isNull);
    });

    test(
      'an encrypted room sends ciphertext paired with its own key material',
      () async {
        final transport = _transportWith(
          MockClient((_) async => _uriResponse('x')),
          encryptor: _fakeEncryptor,
        );

        final payload = await transport.preparePayload(
          Uint8List.fromList([1, 2, 3]),
          encrypted: true,
        );

        expect(payload.bytes, [254, 253, 252]);
        expect(payload.file?.key, 'the-key');
        expect(payload.file?.iv, 'the-iv');
        // The hash must be of exactly these bytes, which is why encryption
        // produces both at once.
        expect(payload.file?.sha256, 'hash-of-3');
        expect(payload.file?.algorithm, 'A256CTR');
      },
    );

    test('an encrypted send puts ciphertext on the wire and in `file`', () async {
      // The three steps joined up, which is the shape a receiving client
      // actually sees: prepare, upload, then the event content. Each half is
      // covered on its own; what this pins is that they agree — plaintext must
      // never reach the socket, and the mxc URI of ciphertext must never appear
      // as a top-level `url`, where an unsuspecting client would fetch it and
      // render the encrypted bytes as a broken image.
      late http.Request seen;
      final transport = _transportWith(
        MockClient((request) async {
          seen = request;
          return _uriResponse('mxc://example.org/cipher');
        }),
        encryptor: _fakeEncryptor,
      );
      final plaintext = Uint8List.fromList([1, 2, 3]);

      final payload = await transport.preparePayload(
        plaintext,
        encrypted: true,
      );
      final uri = await transport.upload(
        payload.bytes,
        mimeType: 'application/octet-stream',
        uploadId: 'task-1',
      );
      final content = _planFor(
        _jpegSource(),
        encrypted: true,
      ).toEventContent(uri: uri, file: payload.file);

      expect(seen.bodyBytes, [254, 253, 252]);
      expect(seen.bodyBytes, isNot(plaintext));
      expect(content['url'], isNull);
      final file = content['file']! as Map<String, Object?>;
      expect(file['url'], 'mxc://example.org/cipher');
      expect((file['key']! as Map)['k'], 'the-key');
      expect((file['hashes']! as Map)['sha256'], 'hash-of-3');
    });

    test('a plain send is the file itself, addressed by `url`', () async {
      final transport = _transportWith(
        MockClient((_) async => _uriResponse('mxc://example.org/plain')),
      );

      final payload = await transport.preparePayload(
        _bytes(32),
        encrypted: false,
      );
      final uri = await transport.upload(
        payload.bytes,
        mimeType: 'image/jpeg',
        uploadId: 'task-1',
      );
      final content = _planFor(_jpegSource()).toEventContent(uri: uri);

      expect(content['url'], 'mxc://example.org/plain');
      expect(content.containsKey('file'), isFalse);
      expect(content['msgtype'], 'm.image');
    });
  });

  group('MatrixAttachmentTransport.maxUploadBytes', () {
    test(
      'reads the v1 media config when the server has authenticated media',
      () async {
        final paths = <String>[];
        final transport = _transportWith(
          MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/versions')) {
              return http.Response('{"versions":["v1.10","v1.11"]}', 200);
            }
            return http.Response('{"m.upload.size":52428800}', 200);
          }),
        );

        expect(await transport.maxUploadBytes(), 52428800);
        expect(paths, [
          '/_matrix/client/versions',
          '/_matrix/client/v1/media/config',
        ]);
      },
    );

    test('falls back to the legacy media config on an older server', () async {
      final paths = <String>[];
      final transport = _transportWith(
        MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/versions')) {
            return http.Response('{"versions":["v1.6","v1.9"]}', 200);
          }
          return http.Response('{"m.upload.size":100}', 200);
        }),
      );

      expect(await transport.maxUploadBytes(), 100);
      expect(paths.last, '/_matrix/media/v3/config');
    });

    test('accepts the MSC3916 unstable flag as authenticated media', () async {
      final paths = <String>[];
      final transport = _transportWith(
        MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/versions')) {
            return http.Response(
              '{"versions":["v1.9"],'
              '"unstable_features":{"org.matrix.msc3916.stable":true}}',
              200,
            );
          }
          return http.Response('{"m.upload.size":7}', 200);
        }),
      );

      expect(await transport.maxUploadBytes(), 7);
      expect(paths.last, '/_matrix/client/v1/media/config');
    });

    test(
      'caches the limit — twenty photos do not re-probe twenty times',
      () async {
        var requests = 0;
        final transport = _transportWith(
          MockClient((request) async {
            requests++;
            if (request.url.path.endsWith('/versions')) {
              return http.Response('{"versions":["v1.11"]}', 200);
            }
            return http.Response('{"m.upload.size":42}', 200);
          }),
        );

        expect(await transport.maxUploadBytes(), 42);
        expect(await transport.maxUploadBytes(), 42);
        expect(requests, 2);
      },
    );

    test('two uploads starting together share one probe', () async {
      var requests = 0;
      final transport = _transportWith(
        MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/versions')) {
            return http.Response('{"versions":["v1.11"]}', 200);
          }
          return http.Response('{"m.upload.size":42}', 200);
        }),
      );

      final both = await Future.wait([
        transport.maxUploadBytes(),
        transport.maxUploadBytes(),
      ]);

      expect(both, [42, 42]);
      expect(requests, 2);
    });

    test(
      'a server advertising no limit answers 0, and that is cached',
      () async {
        var requests = 0;
        final transport = _transportWith(
          MockClient((request) async {
            requests++;
            if (request.url.path.endsWith('/versions')) {
              return http.Response('{"versions":["v1.11"]}', 200);
            }
            return http.Response('{}', 200);
          }),
        );

        expect(await transport.maxUploadBytes(), 0);
        expect(await transport.maxUploadBytes(), 0);
        expect(requests, 2);
      },
    );

    test(
      'a failed probe is not cached, so the limit is not written off',
      () async {
        var configAttempts = 0;
        final transport = _transportWith(
          MockClient((request) async {
            if (request.url.path.endsWith('/versions')) {
              return http.Response('{"versions":["v1.11"]}', 200);
            }
            configAttempts++;
            return configAttempts == 1
                ? http.Response('{}', 503)
                : http.Response('{"m.upload.size":9}', 200);
          }),
        );

        expect(await transport.maxUploadBytes(), 0);
        expect(await transport.maxUploadBytes(), 9);
      },
    );

    test('an unreachable server gives 0 rather than throwing', () async {
      final transport = _transportWith(
        MockClient((_) async => throw http.ClientException('offline')),
      );

      expect(await transport.maxUploadBytes(), 0);
    });
  });

  group('MatrixAttachmentTransport.uploadThumbnail', () {
    test('a suppressed spec uploads nothing at all', () async {
      var uploads = 0;
      final transport = _transportWith(
        MockClient((_) async {
          uploads++;
          return _uriResponse('mxc://example.org/thumb');
        }),
        rasteriser: _fakeRasteriser,
      );

      // A 1 KB PDF: not visual, and under the minimum in any case.
      final result = await transport.uploadThumbnail(
        _planFor(_pdfSource(sizeBytes: 1024)),
        sourceBytes: _bytes(1024),
        uploadId: 'task-1',
      );

      expect(result, isNull);
      expect(uploads, 0);
    });

    test(
      'a plain room uploads the preview as JPEG under a derived id',
      () async {
        final requests = <http.Request>[];
        final transport = _transportWith(
          MockClient((request) async {
            requests.add(request);
            return _uriResponse('mxc://example.org/thumb');
          }),
          rasteriser: _fakeRasteriser,
        );

        final result = await transport.uploadThumbnail(
          _planFor(_jpegSource()),
          sourceBytes: _bytes(200000),
          uploadId: 'task-1',
        );

        expect(result?.uri, 'mxc://example.org/thumb');
        expect(result?.file, isNull);
        expect(result?.sizeBytes, 3);
        // The size it actually came out at, not the spec's bounding box.
        expect(result?.dimensions, const MediaDimensions(640, 360));
        expect(requests.single.headers['content-type'], 'image/jpeg');
      },
    );

    test('an encrypted room encrypts the preview and hides its type', () async {
      final requests = <http.Request>[];
      final transport = _transportWith(
        MockClient((request) async {
          requests.add(request);
          return _uriResponse('mxc://example.org/thumb');
        }),
        encryptor: _fakeEncryptor,
        rasteriser: _fakeRasteriser,
      );

      final result = await transport.uploadThumbnail(
        _planFor(_jpegSource(), encrypted: true),
        sourceBytes: _bytes(200000),
        uploadId: 'task-1',
      );

      // A plain preview beside an encrypted attachment is the one mistake here
      // that actually leaks.
      expect(result?.file?.key, 'the-key');
      expect(requests.single.headers['content-type'], kFallbackMimeType);
      expect(requests.single.bodyBytes, [255, 254, 253]);
    });

    test(
      'the pair feeds toEventContent as an encrypted thumbnail block',
      () async {
        final transport = _transportWith(
          MockClient((_) async => _uriResponse('mxc://example.org/thumb')),
          encryptor: _fakeEncryptor,
          rasteriser: _fakeRasteriser,
        );
        final plan = _planFor(_jpegSource(), encrypted: true);

        final thumb = await transport.uploadThumbnail(
          plan,
          sourceBytes: _bytes(200000),
          uploadId: 'task-1',
        );
        final content = plan.toEventContent(
          uri: 'mxc://example.org/full',
          file: const EncryptedFileInfo(key: 'k', iv: 'i', sha256: 's'),
          thumbnailUri: thumb!.uri,
          thumbnailFile: thumb.file,
          thumbnailSizeBytes: thumb.sizeBytes,
          thumbnailDimensions: thumb.dimensions,
        );

        final info = content['info']! as Map<String, Object?>;
        expect(info.containsKey('thumbnail_url'), isFalse);
        final thumbnailFile = info['thumbnail_file']! as Map<String, Object?>;
        expect(thumbnailFile['url'], 'mxc://example.org/thumb');
        final thumbnailInfo = info['thumbnail_info']! as Map<String, Object?>;
        expect(thumbnailInfo['w'], 640);
        expect(thumbnailInfo['h'], 360);
        expect(thumbnailInfo['size'], 3);
      },
    );

    test(
      'bytes that will not decode mean no preview, not a failed send',
      () async {
        var uploads = 0;
        final transport = _transportWith(
          MockClient((_) async {
            uploads++;
            return _uriResponse('mxc://example.org/thumb');
          }),
          rasteriser: (bytes, spec) async => null,
        );

        final result = await transport.uploadThumbnail(
          _planFor(_jpegSource()),
          sourceBytes: _bytes(200000),
          uploadId: 'task-1',
        );

        expect(result, isNull);
        expect(uploads, 0);
      },
    );

    test(
      'a failed second upload is swallowed — the photo still sends',
      () async {
        final transport = _transportWith(
          MockClient((_) async => http.Response('{}', 500)),
          rasteriser: _fakeRasteriser,
        );

        expect(
          await transport.uploadThumbnail(
            _planFor(_jpegSource()),
            sourceBytes: _bytes(200000),
            uploadId: 'task-1',
          ),
          isNull,
        );
      },
    );

    test('the preview runs under the attachment id, suffixed', () {
      expect(
        MatrixAttachmentTransport.thumbnailUploadId('upload-7'),
        startsWith('upload-7'),
      );
      expect(
        MatrixAttachmentTransport.thumbnailUploadId('upload-7'),
        isNot('upload-7'),
      );
    });
  });

  group('rasteriseThumbnail', () {
    test(
      'scales a large image into the box, preserving its aspect ratio',
      () async {
        final source = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 1600, height: 900)),
        );

        final raster = await rasteriseThumbnail(
          source,
          ThumbnailSpec.forSource(
            kind: MessageKind.image,
            sizeBytes: 200000,
            dimensions: const MediaDimensions(1600, 900),
          ),
        );

        expect(raster, isNotNull);
        expect(raster!.dimensions.width, 800);
        expect(raster.dimensions.height, 450);
        expect(raster.bytes, isNotEmpty);
        // It must decode as an image, not merely be non-empty bytes.
        expect(img.decodeJpg(raster.bytes)?.width, 800);
      },
    );

    test(
      'never upscales — a small image is sent through at its own size',
      () async {
        final source = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 120, height: 90)),
        );

        final raster = await rasteriseThumbnail(
          source,
          ThumbnailSpec.forSource(
            kind: MessageKind.image,
            sizeBytes: 200000,
            dimensions: const MediaDimensions(120, 90),
          ),
        );

        expect(raster?.dimensions, const MediaDimensions(120, 90));
      },
    );

    test('fits inside a square fallback box without stretching', () async {
      // A video's dimensions are routinely unprobeable, which makes the spec a
      // square; scaling a panorama to it directly would distort it.
      final source = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 2000, height: 500)),
      );

      final raster = await rasteriseThumbnail(
        source,
        ThumbnailSpec.forSource(kind: MessageKind.video, sizeBytes: 200000),
      );

      expect(raster?.dimensions, const MediaDimensions(800, 200));
    });

    test('returns null for anything package:image cannot decode', () async {
      // An MP4, a HEIC without a decoder, a truncated file: all "no preview".
      final raster = await rasteriseThumbnail(
        _bytes(4096),
        ThumbnailSpec.forSource(
          kind: MessageKind.video,
          sizeBytes: 200000,
          dimensions: const MediaDimensions(1920, 1080),
        ),
      );

      expect(raster, isNull);
    });

    test('a suppressed spec never touches the decoder', () async {
      expect(
        await rasteriseThumbnail(_bytes(64), const ThumbnailSpec.suppressed()),
        isNull,
      );
    });
  });
}

/// A transport over a mock homeserver, signed in as `token-1`.
MatrixAttachmentTransport _transportWith(
  http.Client client, {
  AttachmentEncryptor? encryptor,
  ThumbnailRasteriser? rasteriser,
}) {
  final session = _FakeSession(client);
  return MatrixAttachmentTransport(
    session: session,
    encryptor: encryptor ?? _unusedEncryptor,
    rasteriser: rasteriser ?? _unusedRasteriser,
  );
}

/// Uploads a token payload against a homeserver that always answers [response].
Future<String> _uploadAgainst(http.Response response) {
  return _transportWith(
    MockClient((_) async => response),
  ).upload(_bytes(64), mimeType: 'image/jpeg', uploadId: 'task-1');
}

http.Response _uriResponse(String uri) =>
    http.Response(jsonEncode({'content_uri': uri}), 200);

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 251));

/// A JPEG large enough that `ThumbnailSpec` decides a preview is worth making.
AttachmentSource _jpegSource() => AttachmentSource(
  filename: 'holiday.jpg',
  sizeBytes: 200000,
  header: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
);

AttachmentSource _pdfSource({required int sizeBytes}) => AttachmentSource(
  filename: 'invoice.pdf',
  sizeBytes: sizeBytes,
  header: Uint8List.fromList(utf8.encode('%PDF-1.7')),
);

UploadPlan _planFor(AttachmentSource source, {bool encrypted = false}) {
  final decision = planUpload(source, encrypted: encrypted, maxUploadBytes: 0);
  return decision as UploadPlan;
}

/// Deterministic stand-in for the SDK's AES-CTR, which needs vodozemac.
Future<sdk.EncryptedFile> _fakeEncryptor(Uint8List plaintext) async =>
    sdk.EncryptedFile(
      data: Uint8List.fromList(plaintext.map((b) => 255 - b).toList()),
      k: 'the-key',
      iv: 'the-iv',
      sha256: 'hash-of-${plaintext.length}',
    );

/// A 640x360 preview of three bytes, whatever it is handed.
Future<RasterisedThumbnail?> _fakeRasteriser(
  Uint8List bytes,
  ThumbnailSpec spec,
) async => RasterisedThumbnail(
  bytes: Uint8List.fromList([0, 1, 2]),
  dimensions: const MediaDimensions(640, 360),
);

Future<sdk.EncryptedFile> _unusedEncryptor(Uint8List plaintext) async =>
    throw StateError('This test should not have encrypted anything');

Future<RasterisedThumbnail?> _unusedRasteriser(
  Uint8List bytes,
  ThumbnailSpec spec,
) async => throw StateError('This test should not have rasterised anything');

/// A signed-in session over a mock client, with a token the test can change
/// underneath a live transport.
class _FakeSession implements MatrixUploadSession {
  _FakeSession(http.Client inner) : httpClient = _RecordingClient(inner);

  @override
  Uri? get baseUrl => Uri.parse('https://example.org');

  @override
  String? accessToken = 'token-1';

  @override
  final _RecordingClient httpClient;

  String? get lastAuthorization => httpClient.lastAuthorization;
}

/// Notes the authorization header of the last request that went out.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner);

  final http.Client _inner;
  String? lastAuthorization;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    lastAuthorization = request.headers['authorization'];
    return _inner.send(request);
  }
}
