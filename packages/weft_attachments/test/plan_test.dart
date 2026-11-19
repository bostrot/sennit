import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import 'support/fixtures.dart';

void main() {
  /// A source whose real size is decoupled from its header slice, because that
  /// is how every caller uses it: a 4 MB photo is planned from 64 bytes.
  AttachmentSource source(
    List<int> header, {
    String filename = 'file.bin',
    String? declaredMimeType,
    int? sizeBytes,
  }) {
    return AttachmentSource(
      filename: filename,
      declaredMimeType: declaredMimeType,
      sizeBytes: sizeBytes ?? header.length,
      header: Uint8List.fromList(header),
    );
  }

  UploadPlan plan(
    List<int> header, {
    String filename = 'file.bin',
    String? declaredMimeType,
    int? sizeBytes,
    bool encrypted = false,
    int maxUploadBytes = 100 * 1024 * 1024,
    bool isVoiceNote = false,
    int? durationMs,
    String? caption,
  }) {
    final decision = planUpload(
      source(
        header,
        filename: filename,
        declaredMimeType: declaredMimeType,
        sizeBytes: sizeBytes,
      ),
      encrypted: encrypted,
      maxUploadBytes: maxUploadBytes,
      isVoiceNote: isVoiceNote,
      durationMs: durationMs,
      caption: caption,
    );
    return decision as UploadPlan;
  }

  const key = EncryptedFileInfo(
    key: 'k3y-mAt3r14l',
    iv: 'aXY0MgAAAAAA',
    sha256: 'c2hhMjU2LW9mLXRoZS1jaXBoZXJ0ZXh0',
  );
  const thumbKey = EncryptedFileInfo(
    key: 'th17mbn41l-k3y',
    iv: 'dGh1bWJpdgAA',
    sha256: 'c2hhMjU2LW9mLXRoZS10aHVtYg',
  );

  /// Comfortably past the 64 KiB thumbnail floor.
  const bigEnoughForThumbnail = 512 * 1024;

  group('planUpload — msgtype mapping', () {
    test('an image is m.image', () {
      final p = plan(png(width: 4, height: 4), filename: 'shot.png');
      expect(p.kind, MessageKind.image);
      expect(p.msgtype, 'm.image');
      expect(p.mimeType, 'image/png');
    });

    test('a video is m.video', () {
      final p = plan(isoBaseMedia(brand: 'isom'), filename: 'clip.mp4');
      expect(p.kind, MessageKind.video);
      expect(p.msgtype, 'm.video');
    });

    test('an audio file is m.audio', () {
      final p = plan(mp3(), filename: 'song.mp3');
      expect(p.kind, MessageKind.audio);
      expect(p.msgtype, 'm.audio');
    });

    test('a voice note is m.audio too — the msgtype does not carry it', () {
      final p = plan(ogg(), filename: 'note.ogg', isVoiceNote: true);
      expect(p.kind, MessageKind.voice);
      expect(p.msgtype, 'm.audio');
      expect(p.isVoiceNote, isTrue);
    });

    test('anything else is m.file', () {
      expect(plan(pdf(), filename: 'contract.pdf').msgtype, 'm.file');
      expect(plan(zip(), filename: 'logs.zip').msgtype, 'm.file');
      expect(
        plan(const [], filename: 'notes.txt', sizeBytes: 12).msgtype,
        'm.file',
      );
    });

    test('the sniffed type drives the msgtype, not the declared one', () {
      // A share intent claiming `*/*` for a JPEG would otherwise send a
      // paperclip where every other client expects a picture.
      final p = plan(
        jpeg(width: 8, height: 8),
        filename: 'shared',
        declaredMimeType: '*/*',
      );
      expect(p.mimeType, 'image/jpeg');
      expect(p.msgtype, 'm.image');
    });
  });

  group('planUpload — dimensions and duration', () {
    test('image dimensions come from the header', () {
      final p = plan(png(width: 640, height: 480), filename: 'a.png');
      expect(p.dimensions, const MediaDimensions(640, 480));
    });

    test('video dimensions come from a front-loaded moov', () {
      final p = plan(
        mp4WithTracks(const [MediaDimensions(1920, 1080)]),
        filename: 'a.mp4',
      );
      expect(p.dimensions, const MediaDimensions(1920, 1080));
    });

    test('an unprobeable video plans fine with null dimensions', () {
      // The normal case for anything not written for streaming: `moov` is at
      // the end of the file and never appears in a header slice.
      final p = plan(isoBaseMedia(brand: 'isom'), filename: 'a.mp4');
      expect(p.dimensions, isNull);
      expect(p.msgtype, 'm.video');
    });

    test('dimensions are not probed for non-visual kinds', () {
      // A PDF whose bytes happen to begin like a PNG must not report pixels.
      final p = plan(pdf(), filename: 'a.pdf');
      expect(p.dimensions, isNull);
    });

    // The send path reads the whole file for upload and measures it then;
    // a phone's recording keeps `moov` at the end, out of the header's reach.
    test('a video measured from the whole file announces shape and length', () {
      final whole = Uint8List.fromList(
        mp4WithTracks(
          const [MediaDimensions(1920, 1080)],
          portrait: true,
          timescale: 600,
          duration: 1800,
          moovAtEnd: true,
        ),
      );
      final p = plan(whole.take(48).toList(), filename: 'clip.mp4');
      expect(p.dimensions, isNull);

      final info =
          p.toEventContent(
                uri: 'mxc://weft.test/v',
                measuredDimensions: probeVideoDimensions(whole),
                measuredDurationMs: probeVideoDurationMs(whole),
              )['info']!
              as Map<String, Object?>;
      expect(info['mimetype'], 'video/mp4');
      expect(info['w'], 1080);
      expect(info['h'], 1920);
      expect(info['duration'], 3000);
    });

    test('what the plan knew is not overwritten by a measurement', () {
      final p = plan(
        mp4WithTracks(const [MediaDimensions(640, 360)]),
        filename: 'a.mp4',
        durationMs: 1234,
      );
      final info =
          p.toEventContent(
                uri: 'mxc://weft.test/v',
                measuredDimensions: const MediaDimensions(1, 1),
                measuredDurationMs: 9,
              )['info']!
              as Map<String, Object?>;
      expect(info['w'], 640);
      expect(info['duration'], 1234);
    });

    test('duration is the caller\'s to supply', () {
      expect(plan(mp3(), filename: 'a.mp3', durationMs: 4200).durationMs, 4200);
      expect(plan(mp3(), filename: 'a.mp3').durationMs, isNull);
    });
  });

  group('ThumbnailSpec', () {
    test('a large image is scaled to a longest edge of 800', () {
      final p = plan(
        png(width: 4000, height: 3000),
        filename: 'a.png',
        sizeBytes: bigEnoughForThumbnail,
      );
      expect(p.thumbnail.shouldGenerate, isTrue);
      expect(p.thumbnail.width, 800);
      expect(p.thumbnail.height, 600);
      expect(p.thumbnail.mimeType, 'image/jpeg');
    });

    test('a portrait image scales on its height', () {
      final p = plan(
        png(width: 1200, height: 1600),
        filename: 'a.png',
        sizeBytes: bigEnoughForThumbnail,
      );
      expect(p.thumbnail.width, 600);
      expect(p.thumbnail.height, 800);
    });

    test('an image already under 800px is not upscaled', () {
      final p = plan(
        png(width: 300, height: 200),
        filename: 'a.png',
        sizeBytes: bigEnoughForThumbnail,
      );
      expect(p.thumbnail.width, 300);
      expect(p.thumbnail.height, 200);
    });

    test('an extreme aspect ratio never collapses to zero', () {
      final p = plan(
        png(width: 4000, height: 9),
        filename: 'panorama.png',
        sizeBytes: bigEnoughForThumbnail,
      );
      expect(p.thumbnail.height, greaterThanOrEqualTo(1));
    });

    test('unknown dimensions fall back to an 800x800 bounding box', () {
      final p = plan(
        isoBaseMedia(brand: 'isom'),
        filename: 'a.mp4',
        sizeBytes: bigEnoughForThumbnail,
      );
      expect(p.thumbnail.shouldGenerate, isTrue);
      expect(p.thumbnail.width, 800);
      expect(p.thumbnail.height, 800);
    });

    test('a file under 64 KiB gets no thumbnail', () {
      final p = plan(
        png(width: 4000, height: 3000),
        filename: 'a.png',
        sizeBytes: 64 * 1024 - 1,
      );
      expect(p.thumbnail.shouldGenerate, isFalse);
      expect(p.thumbnail, const ThumbnailSpec.suppressed());
    });

    test('exactly 64 KiB is on the generating side of the line', () {
      final p = plan(
        png(width: 4000, height: 3000),
        filename: 'a.png',
        sizeBytes: 64 * 1024,
      );
      expect(p.thumbnail.shouldGenerate, isTrue);
    });

    test('non-visual kinds get no thumbnail however large', () {
      for (final p in [
        plan(pdf(), filename: 'a.pdf', sizeBytes: 20 * 1024 * 1024),
        plan(mp3(), filename: 'a.mp3', sizeBytes: 20 * 1024 * 1024),
        plan(
          ogg(),
          filename: 'a.ogg',
          sizeBytes: 20 * 1024 * 1024,
          isVoiceNote: true,
        ),
      ]) {
        expect(p.thumbnail.shouldGenerate, isFalse, reason: '${p.kind}');
      }
    });
  });

  group('planUpload — rejections', () {
    test('an empty file is rejected', () {
      final decision = planUpload(
        source(const [], filename: 'empty.png', sizeBytes: 0),
        encrypted: false,
        maxUploadBytes: 1024,
      );
      expect(decision, isA<UploadRejection>());
      final rejection = decision as UploadRejection;
      expect(rejection.reason, UploadRejectionReason.empty);
      expect(rejection.message, isNotEmpty);
    });

    test('a file over the homeserver limit is rejected with both sizes', () {
      final decision =
          planUpload(
                source(
                  png(width: 2, height: 2),
                  filename: 'huge.png',
                  sizeBytes: 60 * 1024 * 1024,
                ),
                encrypted: false,
                maxUploadBytes: 50 * 1024 * 1024,
              )
              as UploadRejection;
      expect(decision.reason, UploadRejectionReason.tooLarge);
      expect(decision.message, contains('60.0'));
      expect(decision.message, contains('50.0'));
    });

    test('a file exactly at the limit is accepted', () {
      final decision = planUpload(
        source(
          png(width: 2, height: 2),
          filename: 'exact.png',
          sizeBytes: 50 * 1024 * 1024,
        ),
        encrypted: false,
        maxUploadBytes: 50 * 1024 * 1024,
      );
      expect(decision, isA<UploadPlan>());
    });

    test('an unadvertised limit means unknown, not zero', () {
      // A homeserver that never sent `m.upload.size` must not reject
      // everything the user picks.
      final decision = planUpload(
        source(
          png(width: 2, height: 2),
          filename: 'a.png',
          sizeBytes: 900 * 1024 * 1024,
        ),
        encrypted: false,
        maxUploadBytes: 0,
      );
      expect(decision, isA<UploadPlan>());
    });

    test('a nameless file is rejected as unsupported', () {
      final decision = planUpload(
        source(png(width: 2, height: 2), filename: '  ', sizeBytes: 1024),
        encrypted: false,
        maxUploadBytes: 0,
      );
      expect(decision, isA<UploadRejection>());
      expect(
        (decision as UploadRejection).reason,
        UploadRejectionReason.unsupported,
      );
    });

    test('emptiness is checked before the size limit', () {
      // Both apply to a 0-byte file when the limit is 0; the useful message is
      // the one about the file, not about the server.
      final decision =
          planUpload(
                source(const [], filename: 'a.png', sizeBytes: 0),
                encrypted: false,
                maxUploadBytes: 0,
              )
              as UploadRejection;
      expect(decision.reason, UploadRejectionReason.empty);
    });
  });

  group('toEventContent — the plain/encrypted split', () {
    test('a plain room carries the URI at the top level under url', () {
      final content = plan(
        png(width: 640, height: 480),
        filename: 'photo.png',
        sizeBytes: 200000,
      ).toEventContent(uri: 'mxc://weft.test/abc');

      expect(content['url'], 'mxc://weft.test/abc');
      expect(content['file'], isNull);
      expect(content['msgtype'], 'm.image');
      expect(content['body'], 'photo.png');
      expect(content['info'], {
        'mimetype': 'image/png',
        'size': 200000,
        'w': 640,
        'h': 480,
      });
    });

    test('an encrypted room carries the URI inside file.url', () {
      final content = plan(
        png(width: 640, height: 480),
        filename: 'photo.png',
        sizeBytes: 200000,
        encrypted: true,
      ).toEventContent(uri: 'mxc://weft.test/abc', file: key);

      expect(content['url'], isNull, reason: 'a plain url leaks the split');
      final file = content['file']! as Map<String, Object?>;
      expect(file['url'], 'mxc://weft.test/abc');
      expect(file['iv'], key.iv);
      expect(file['v'], 'v2');
      expect(file['hashes'], {'sha256': key.sha256});
      expect(file['key'], {
        'kty': 'oct',
        'alg': 'A256CTR',
        'ext': true,
        'k': key.key,
        'key_ops': ['encrypt', 'decrypt'],
      });
    });

    test('both shapes still satisfy weft_matrix\'s attachment test', () {
      // `_hasAttachment` is `content['url'] is String || content['file'] is Map`
      // — an event failing both renders as a bubble with nothing in it.
      final plain = plan(
        pdf(),
        filename: 'a.pdf',
        sizeBytes: 99,
      ).toEventContent(uri: 'mxc://weft.test/p');
      final encrypted = plan(
        pdf(),
        filename: 'a.pdf',
        sizeBytes: 99,
        encrypted: true,
      ).toEventContent(uri: 'mxc://weft.test/e', file: key);

      expect(plain['url'] is String || plain['file'] is Map, isTrue);
      expect(encrypted['url'] is String || encrypted['file'] is Map, isTrue);
    });

    test('an encrypted plan without key material is a programming error', () {
      final p = plan(pdf(), filename: 'a.pdf', sizeBytes: 99, encrypted: true);
      expect(
        () => p.toEventContent(uri: 'mxc://weft.test/a'),
        throwsArgumentError,
      );
    });

    test('key material on a plain plan is refused rather than mixed in', () {
      final p = plan(pdf(), filename: 'a.pdf', sizeBytes: 99);
      expect(
        () => p.toEventContent(uri: 'mxc://weft.test/a', file: key),
        throwsArgumentError,
      );
    });
  });

  group('toEventContent — thumbnails', () {
    UploadPlan thumbnailablePlan({bool encrypted = false}) => plan(
      png(width: 1600, height: 1200),
      filename: 'photo.png',
      sizeBytes: bigEnoughForThumbnail,
      encrypted: encrypted,
    );

    test('a plain room puts the thumbnail under info.thumbnail_url', () {
      final content = thumbnailablePlan().toEventContent(
        uri: 'mxc://weft.test/full',
        thumbnailUri: 'mxc://weft.test/thumb',
        thumbnailSizeBytes: 4096,
      );

      final info = content['info']! as Map<String, Object?>;
      expect(info['thumbnail_url'], 'mxc://weft.test/thumb');
      expect(info['thumbnail_file'], isNull);
      expect(info['thumbnail_info'], {
        'mimetype': 'image/jpeg',
        'w': 800,
        'h': 600,
        'size': 4096,
      });
    });

    test('an encrypted room mirrors the rule with info.thumbnail_file', () {
      final content = thumbnailablePlan(encrypted: true).toEventContent(
        uri: 'mxc://weft.test/full',
        file: key,
        thumbnailUri: 'mxc://weft.test/thumb',
        thumbnailFile: thumbKey,
        thumbnailSizeBytes: 4096,
      );

      final info = content['info']! as Map<String, Object?>;
      expect(
        info['thumbnail_url'],
        isNull,
        reason:
            'a plain thumbnail url leaks a preview out of an encrypted room',
      );
      final file = info['thumbnail_file']! as Map<String, Object?>;
      expect(file['url'], 'mxc://weft.test/thumb');
      expect(file['iv'], thumbKey.iv);
      expect(
        (file['key']! as Map<String, Object?>)['k'],
        thumbKey.key,
        reason: 'the thumbnail has its own key, not the attachment\'s',
      );
    });

    test('an explicit thumbnail size overrides the planned one', () {
      // The rasteriser may not hit the target exactly; what it produced wins.
      final content = thumbnailablePlan().toEventContent(
        uri: 'mxc://weft.test/full',
        thumbnailUri: 'mxc://weft.test/thumb',
        thumbnailDimensions: const MediaDimensions(799, 599),
      );
      final info = content['info']! as Map<String, Object?>;
      expect((info['thumbnail_info']! as Map)['w'], 799);
      expect((info['thumbnail_info']! as Map)['h'], 599);
    });

    test('no thumbnail URI means no thumbnail keys at all', () {
      final content = thumbnailablePlan().toEventContent(
        uri: 'mxc://weft.test/full',
      );
      final info = content['info']! as Map<String, Object?>;
      expect(info.containsKey('thumbnail_url'), isFalse);
      expect(info.containsKey('thumbnail_file'), isFalse);
      expect(info.containsKey('thumbnail_info'), isFalse);
    });

    test('thumbnail details without a URI are refused', () {
      expect(
        () => thumbnailablePlan().toEventContent(
          uri: 'mxc://weft.test/full',
          thumbnailSizeBytes: 4096,
        ),
        throwsArgumentError,
      );
    });

    test('an encrypted thumbnail without its key is refused', () {
      expect(
        () => thumbnailablePlan(encrypted: true).toEventContent(
          uri: 'mxc://weft.test/full',
          file: key,
          thumbnailUri: 'mxc://weft.test/thumb',
        ),
        throwsArgumentError,
      );
    });
  });

  group('toEventContent — audio and voice notes', () {
    test('duration lands in info, where weft_matrix reads it first', () {
      final content = plan(
        mp3(),
        filename: 'song.mp3',
        sizeBytes: 5000,
        durationMs: 183000,
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect((content['info']! as Map)['duration'], 183000);
      expect(content.containsKey('org.matrix.msc3245.voice'), isFalse);
    });

    test('a voice note carries both MSC keys so it round-trips as voice', () {
      // `isVoiceMessage` accepts either key; writing both means a client that
      // only knows one still shows a voice bubble rather than a music file.
      final content = plan(
        ogg(),
        filename: 'note.ogg',
        sizeBytes: 5000,
        isVoiceNote: true,
        durationMs: 3400,
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect(content['msgtype'], 'm.audio');
      expect(content['org.matrix.msc3245.voice'], isEmpty);
      expect(content['org.matrix.msc1767.audio'], {'duration': 3400});
    });

    test('a voice note with no duration still emits the marker keys', () {
      final content = plan(
        ogg(),
        filename: 'note.ogg',
        sizeBytes: 5000,
        isVoiceNote: true,
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect(content.containsKey('org.matrix.msc3245.voice'), isTrue);
      expect(content['org.matrix.msc1767.audio'], isEmpty);
    });
  });

  group('toEventContent — body and filename', () {
    test('body is the filename, stripped of any path', () {
      final content = plan(
        pdf(),
        filename: '/private/var/tmp/report.pdf',
        sizeBytes: 99,
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect(content['body'], 'report.pdf');
      expect(content.containsKey('filename'), isFalse);
    });

    test('a caption becomes body and pushes the name to filename', () {
      final content = plan(
        png(width: 2, height: 2),
        filename: 'photo.png',
        sizeBytes: 99,
        caption: 'the cat again',
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect(content['body'], 'the cat again');
      expect(content['filename'], 'photo.png');
    });

    test('a caption is trimmed on the way in', () {
      final planned = plan(
        png(width: 2, height: 2),
        filename: 'photo.png',
        sizeBytes: 99,
        caption: '  at the beach\n',
      );

      expect(planned.caption, 'at the beach');
      expect(
        planned.toEventContent(uri: 'mxc://weft.test/a')['body'],
        'at the beach',
      );
    });

    test('a blank caption is no caption at all', () {
      // The regression: a composer that submitted an untouched field would
      // otherwise send `body: "   "` with the name pushed aside, which renders
      // as an empty line under the picture on every client — and, worse, is
      // what the *name* would have been showing.
      for (final blank in ['', '   ', '\n', '\t \n']) {
        final planned = plan(
          png(width: 2, height: 2),
          filename: 'photo.png',
          sizeBytes: 99,
          caption: blank,
        );

        expect(planned.caption, isNull, reason: 'for ${jsonEncode(blank)}');
        final content = planned.toEventContent(uri: 'mxc://weft.test/a');
        expect(content['body'], 'photo.png');
        expect(content.containsKey('filename'), isFalse);
      }
    });

    test('a caption on an encrypted plan does not disturb the file block', () {
      // The caption is the one part of the content that is *not* structural,
      // and the shape rules are the part that leaks a preview when they are
      // wrong. Asserted together because a caption arriving through a second
      // parameter used to be threaded past exactly this branch.
      final content = plan(
        png(width: 2, height: 2),
        filename: 'photo.png',
        sizeBytes: 99,
        encrypted: true,
        caption: 'the cat again',
      ).toEventContent(uri: 'mxc://weft.test/a', file: key);

      expect(content['body'], 'the cat again');
      expect(content['filename'], 'photo.png');
      expect(content.containsKey('url'), isFalse);
      expect((content['file']! as Map)['url'], 'mxc://weft.test/a');
    });

    test('a captioned voice note keeps both MSC keys', () {
      final content = plan(
        ogg(),
        filename: 'note.ogg',
        sizeBytes: 5000,
        isVoiceNote: true,
        durationMs: 3400,
        caption: 'sorry about the noise',
      ).toEventContent(uri: 'mxc://weft.test/a');

      expect(content['body'], 'sorry about the noise');
      expect(content['filename'], 'note.ogg');
      expect(content['org.matrix.msc3245.voice'], isEmpty);
      expect(content['org.matrix.msc1767.audio'], {'duration': 3400});
    });
  });

  group('EncryptedFileInfo', () {
    test('round-trips through JSON', () {
      expect(EncryptedFileInfo.fromJson(key.toJson()), key);
    });

    test('survives a file block with a url already in it', () {
      final json = {...key.toJson(), 'url': 'mxc://weft.test/a'};
      expect(EncryptedFileInfo.fromJson(json), key);
    });

    test('a reshaped block parses to empty fields rather than throwing', () {
      expect(
        () => EncryptedFileInfo.fromJson(const {'key': 'not-a-jwk'}),
        returnsNormally,
      );
      final parsed = EncryptedFileInfo.fromJson(const {
        'key': 'not-a-jwk',
        'hashes': 42,
      });
      expect(parsed.key, isEmpty);
      expect(parsed.sha256, isEmpty);
      expect(parsed.algorithm, 'A256CTR');
    });

    test('an unexpected algorithm is carried through, not rewritten', () {
      final parsed = EncryptedFileInfo.fromJson(const {
        'key': {'k': 'abc', 'alg': 'A128CTR'},
        'iv': 'iv',
        'hashes': {'sha256': 'h'},
        'v': 'v3',
      });
      expect(parsed.algorithm, 'A128CTR');
      expect(parsed.version, 'v3');
      expect(EncryptedFileInfo.fromJson(parsed.toJson()), parsed);
    });
  });

  group('UploadDecision', () {
    test('is sealed, so both branches must be handled', () {
      final decisions = <UploadDecision>[
        planUpload(
          source(png(width: 2, height: 2), filename: 'a.png', sizeBytes: 10),
          encrypted: false,
          maxUploadBytes: 1024,
        ),
        planUpload(
          source(const [], filename: 'a.png', sizeBytes: 0),
          encrypted: false,
          maxUploadBytes: 1024,
        ),
      ];

      final described = decisions.map(
        (d) => switch (d) {
          UploadPlan(:final msgtype) => msgtype,
          UploadRejection(:final reason) => reason.name,
        },
      );
      expect(described, ['m.image', 'empty']);
    });
  });
}
