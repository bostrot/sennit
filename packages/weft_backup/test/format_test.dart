import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_backup/weft_backup.dart';

/// A header at this build's defaults, for mutating in the cases below.
Uint8List sampleHeader({
  ArchiveVersion version = kBraidArchiveFormatVersion,
  KdfParameters? kdf,
  CipherParameters? cipher,
}) => encodeArchiveHeader(
  version: version,
  kdf: kdf ?? KdfParameters(salt: Uint8List(16)),
  cipher: cipher ?? CipherParameters(noncePrefix: Uint8List(16)),
  preview: ArchivePreview(
    createdAt: DateTime.utc(2026, 8, 28, 12),
    appVersion: '1.4.0',
    chatCount: 12,
    messageCount: 4300,
    mediaIncluded: true,
    totalBytes: 987654,
  ),
);

/// [header] with `format` replaced, re-encoded the way a future Braid would.
Uint8List headerWithRawJson(Map<String, Object?> json) {
  final body = utf8.encode(jsonEncode(json));
  return Uint8List.fromList([
    ...kBraidArchiveMagic,
    ...uint32Bytes(body.length),
    ...body,
  ]);
}

Map<String, Object?> decodeHeaderJson(Uint8List header) {
  final length = readUint32(header, kBraidArchiveMagic.length);
  return jsonDecode(utf8.decode(header.sublist(12, 12 + length)))
      as Map<String, Object?>;
}

void main() {
  group('header round trip', () {
    test('parses back everything it was given', () {
      final result = parseArchiveHeader(sampleHeader());

      expect(result.isSuccess, isTrue);
      final header = result.header!;
      expect(header.version, kBraidArchiveFormatVersion);
      expect(header.kdf.id, KdfParameters.argon2id);
      expect(header.kdf.memoryKiB, KdfParameters.defaultMemoryKiB);
      expect(header.cipher.id, CipherParameters.xchacha20Poly1305);
      expect(header.preview.appVersion, '1.4.0');
      expect(header.preview.messageCount, 4300);
      expect(header.preview.createdAt, DateTime.utc(2026, 8, 28, 12));
    });

    test('keeps the header bytes verbatim, not re-encoded', () {
      // Load-bearing: these bytes are the AEAD's associated data, so a
      // re-encoding that dropped one unknown field would fail every frame of an
      // archive the version policy promises still opens.
      final bytes = sampleHeader();
      final header = parseArchiveHeader(bytes).header!;
      expect(header.bytes, equals(bytes));
    });

    test('the preview is readable with no passphrase anywhere in sight', () {
      // The whole point of a plaintext header: nothing below took a key.
      final header = parseArchiveHeader(sampleHeader()).header!;
      expect(header.preview.chatCount, 12);
      expect(header.preview.mediaIncluded, isTrue);
    });
  });

  group('what stays out of the plaintext header', () {
    test('the network list is not in it', () {
      // The deliberate boundary. Counts are inferable from the file size;
      // "this person has a Signal account" is not, so it lives inside the
      // ciphertext in the manifest and must never leak out here.
      final json = decodeHeaderJson(sampleHeader());
      expect(jsonEncode(json).toLowerCase(), isNot(contains('network')));
      expect(json['preview'], isNot(contains('networks')));
    });
  });

  group('wrong file versus damaged file', () {
    test('no magic reads as not-an-archive', () {
      final result = parseArchiveHeader(
        Uint8List.fromList(utf8.encode('this is a holiday photo, honestly')),
      );
      expect(result.problem, HeaderProblem.notAnArchive);
    });

    test('an empty file reads as not-an-archive', () {
      expect(
        parseArchiveHeader(Uint8List(0)).problem,
        HeaderProblem.notAnArchive,
      );
    });

    test('magic followed by rubbish reads as malformed, not wrong-file', () {
      final bytes = Uint8List.fromList([
        ...kBraidArchiveMagic,
        ...uint32Bytes(4),
        ...utf8.encode('{{{{'),
      ]);
      expect(parseArchiveHeader(bytes).problem, HeaderProblem.malformed);
    });

    test('a header cut short reads as malformed', () {
      final full = sampleHeader();
      final cut = Uint8List.sublistView(full, 0, full.length - 20);
      expect(parseArchiveHeader(cut).problem, HeaderProblem.malformed);
    });

    test('an absurd declared header length is refused, not allocated', () {
      final bytes = Uint8List.fromList([
        ...kBraidArchiveMagic,
        ...uint32Bytes(0x7FFFFFFF),
        ...utf8.encode('{}'),
      ]);
      expect(parseArchiveHeader(bytes).problem, HeaderProblem.malformed);
    });
  });

  group('version policy', () {
    test('a future major is refused and names the version', () {
      final result = parseArchiveHeader(
        sampleHeader(
          version: ArchiveVersion(kBraidArchiveFormatVersion.major + 1, 0),
        ),
      );
      expect(result.problem, HeaderProblem.unsupportedVersion);
      expect(result.version!.major, kBraidArchiveFormatVersion.major + 1);
    });

    test('a future minor is read normally and flagged', () {
      final result = parseArchiveHeader(
        sampleHeader(
          version: ArchiveVersion(
            kBraidArchiveFormatVersion.major,
            kBraidArchiveFormatVersion.minor + 7,
          ),
        ),
      );
      expect(result.isSuccess, isTrue);
      expect(result.header!.isFutureMinor, isTrue);
    });

    test('unknown top-level keys from a newer writer are ignored', () {
      final json = decodeHeaderJson(sampleHeader())
        ..['somethingNewInTwentyThirty'] = {'nested': true};
      final result = parseArchiveHeader(headerWithRawJson(json));
      expect(result.isSuccess, isTrue);
      expect(result.header!.preview.messageCount, 4300);
    });

    test(
      'a missing format block is malformed rather than assumed to be v1',
      () {
        final json = decodeHeaderJson(sampleHeader())..remove('format');
        expect(
          parseArchiveHeader(headerWithRawJson(json)).problem,
          HeaderProblem.malformed,
        );
      },
    );

    test('a primitive this build does not have reads as a version problem', () {
      // Same major, but named a cipher we cannot run. There is nothing to try,
      // so "update Braid" is the honest advice rather than "file is damaged".
      final json = decodeHeaderJson(sampleHeader());
      (json['cipher']! as Map<String, Object?>)['id'] = 'aes-256-siv';
      final result = parseArchiveHeader(headerWithRawJson(json));
      expect(result.problem, HeaderProblem.unsupportedVersion);
    });
  });

  group('parameters that would be a weapon', () {
    Map<String, Object?> withKdf(void Function(Map<String, Object?>) mutate) {
      final json = decodeHeaderJson(sampleHeader());
      mutate(json['kdf']! as Map<String, Object?>);
      return json;
    }

    test('an out-of-memory memory cost is refused', () {
      expect(
        parseArchiveHeader(
          headerWithRawJson(withKdf((kdf) => kdf['memoryKiB'] = 0x7FFFFFFF)),
        ).problem,
        HeaderProblem.malformed,
      );
    });

    test('a memory cost below any sane floor is refused', () {
      expect(
        parseArchiveHeader(
          headerWithRawJson(withKdf((kdf) => kdf['memoryKiB'] = 1)),
        ).problem,
        HeaderProblem.malformed,
      );
    });

    test('zero iterations is refused', () {
      expect(
        parseArchiveHeader(
          headerWithRawJson(withKdf((kdf) => kdf['iterations'] = 0)),
        ).problem,
        HeaderProblem.malformed,
      );
    });

    test('a key length other than 32 is refused', () {
      expect(
        parseArchiveHeader(
          headerWithRawJson(withKdf((kdf) => kdf['keyLength'] = 16)),
        ).problem,
        HeaderProblem.malformed,
      );
    });

    test('a salt that is not base64 is refused', () {
      expect(
        parseArchiveHeader(
          headerWithRawJson(withKdf((kdf) => kdf['salt'] = 'not base64 !!')),
        ).problem,
        HeaderProblem.malformed,
      );
    });

    test('a frame size above the reader ceiling is refused', () {
      final json = decodeHeaderJson(sampleHeader());
      (json['cipher']! as Map<String, Object?>)['frameSize'] =
          kMaxFrameSize + 1;
      expect(
        parseArchiveHeader(headerWithRawJson(json)).problem,
        HeaderProblem.malformed,
      );
    });

    test('a nonce prefix of the wrong length is refused', () {
      final json = decodeHeaderJson(sampleHeader());
      (json['cipher']! as Map<String, Object?>)['noncePrefix'] = base64.encode(
        Uint8List(8),
      );
      expect(
        parseArchiveHeader(headerWithRawJson(json)).problem,
        HeaderProblem.malformed,
      );
    });
  });

  group('preview and manifest degrade rather than refuse', () {
    test('a preview missing every field still parses', () {
      final preview = ArchivePreview.fromJson(const <String, Object?>{});
      expect(preview.createdAt.millisecondsSinceEpoch, 0);
      expect(preview.appVersion, '');
      expect(preview.messageCount, 0);
      expect(preview.mediaIncluded, isFalse);
    });

    test('a preview with wrongly typed fields still parses', () {
      final preview = ArchivePreview.fromJson({
        'createdAt': 'yesterday',
        'chatCount': -4,
        'mediaIncluded': 'yes',
      });
      expect(preview.createdAt.millisecondsSinceEpoch, 0);
      expect(preview.chatCount, 0);
      expect(preview.mediaIncluded, isFalse);
    });

    test('a manifest keeps the network ids it recognises as strings', () {
      final manifest = ArchiveManifest.fromJson({
        'networks': ['whatsapp', 42, 'sms', null],
        'messageCount': 7,
      });
      expect(manifest.networks, ['whatsapp', 'sms']);
      expect(manifest.messageCount, 7);
    });

    test('manifest timestamps come back in UTC', () {
      final manifest = ArchiveManifest.fromJson({
        'createdAt': DateTime.utc(2026, 3, 1).millisecondsSinceEpoch,
      });
      expect(manifest.createdAt.isUtc, isTrue);
      expect(manifest.createdAt, DateTime.utc(2026, 3, 1));
    });
  });
}
