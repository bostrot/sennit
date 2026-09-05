import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_backup/weft_backup.dart';

import 'support/fakes.dart';

const passphrase = 'a passphrase nobody will ever guess';

final DateTime writtenAt = DateTime.utc(2026, 8, 28, 9, 30);

/// One of every record type, populated so a dropped field shows up as a
/// mismatch rather than as two empty strings comparing equal.
List<BackupRecord> populated() => <BackupRecord>[
  const ContactRecord(
    id: 'contact-1',
    displayName: 'Anke Brandt',
    avatarUrl: 'mxc://example.org/avatar',
    pinned: true,
  ),
  const HandleRecord(
    id: 'handle-1',
    network: 'whatsapp',
    remoteId: '4915112345678',
    matrixUserId: '@whatsapp_4915112345678:example.org',
    roomId: '!room1:example.org',
    displayName: 'Anke',
    avatarUrl: 'mxc://example.org/a',
    phoneE164: '+4915112345678',
    email: 'anke@example.org',
    avatarDHash: 1234567890,
    unifiedContactId: 'contact-1',
  ),
  MergeDecisionRecord(
    pair: 'handle-1|handle-2',
    verdict: 'same',
    source: 'user',
    decidedAt: DateTime.utc(2026, 5, 4, 11, 22),
  ),
  ChatPrefRecord(
    chatId: 'chat-1',
    sendNetwork: 'sms',
    updatedAt: DateTime.utc(2026, 6, 1),
  ),
  const SettingRecord(key: 'appearance.theme_mode', value: 'dark'),
  MessageRecord(
    eventId: r'$event-1',
    roomId: '!room1:example.org',
    chatId: 'chat-1',
    network: 'whatsapp',
    senderId: '@whatsapp_4915112345678:example.org',
    senderName: 'Anke',
    timestamp: DateTime.utc(2026, 7, 14, 18, 5),
    kind: 'text',
    body: 'Sehen wir uns um acht? 🙂',
    chatTitle: 'Anke Brandt',
    reactions: const {'🙂': 2, '👍': 1},
  ),
  MessageRecord(
    eventId: r'$event-2',
    roomId: '!room1:example.org',
    chatId: 'chat-1',
    network: 'whatsapp',
    senderId: '@me:example.org',
    senderName: 'Me',
    timestamp: DateTime.utc(2026, 7, 14, 18, 7),
    kind: 'image',
    body: 'IMG_0042.jpg',
    chatTitle: 'Anke Brandt',
    hasMedia: true,
  ),
  TranscriptRecord(
    eventId: r'$event-3',
    roomId: '!room1:example.org',
    text: 'Ich bin gleich da.',
    provider: 'whisper-local',
    language: 'de',
    createdAt: DateTime.utc(2026, 7, 14, 18, 9),
  ),
];

Uint8List photo([int fill = 0xAB, int length = 4096]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

/// [populated] plus one photo, referenced from two events — so dedup has
/// something to deduplicate.
List<BackupRecord> populatedWithMedia() {
  final bytes = photo();
  final hash = mediaContentHash(bytes);
  return <BackupRecord>[
    ...populated(),
    MediaRecord.ofBytes(sha256: hash, bytes: bytes),
    MediaRefRecord(
      eventId: r'$event-2',
      sha256: hash,
      fileName: 'IMG_0042.jpg',
    ),
    // The same photo forwarded into another chat. Its bytes must not be
    // written twice; its reference must survive.
    MediaRecord.ofBytes(sha256: hash, bytes: bytes),
    MediaRefRecord(
      eventId: r'$event-9',
      sha256: hash,
      fileName: 'IMG_0042.jpg',
    ),
  ];
}

BackupSummary summaryFor(List<BackupRecord> records) {
  final media = records.whereType<MediaRecord>().toList();
  final hashes = media.map((m) => m.sha256).toSet();
  return BackupSummary(
    networks: const ['whatsapp', 'sms'],
    chatCount: 1,
    messageCount: records.whereType<MessageRecord>().length,
    mediaCount: hashes.length,
    mediaBytes: hashes
        .map((h) => media.firstWhere((m) => m.sha256 == h).sizeBytes)
        .fold(0, (a, b) => a + b),
    otherRecordCount: records.length,
  );
}

Future<Uint8List> archiveOf(
  List<BackupRecord> records, {
  bool includeMedia = true,
  int frameSize = 4096,
  String pass = passphrase,
}) async {
  final sink = BytesArchiveSink();
  await writeArchive(
    source: FakeSource(records, summary: summaryFor(records)),
    passphrase: pass,
    sink: sink,
    appVersion: '1.4.0',
    createdAt: writtenAt,
    includeMedia: includeMedia,
    frameSize: frameSize,
    kdfOverride: cheapKdf(),
  );
  return sink.bytes;
}

Future<ImportOutcome> importInto(
  MapSink sink,
  Uint8List archive, {
  ImportMode mode = ImportMode.merge,
  String pass = passphrase,
}) async {
  final reader = await openArchiveBytes(archive, pass);
  try {
    return await importArchive(reader: reader, sink: sink, mode: mode);
  } finally {
    await reader.close();
  }
}

void main() {
  group('round trip', () {
    test('every entity type comes back with full fidelity', () async {
      final records = populated();
      final sink = MapSink();
      final outcome = await importInto(sink, await archiveOf(records));

      expect(outcome.applied, records.length);
      expect(outcome.skippedUnknownType, 0);

      final state = sink.state;
      expect(state.contacts['contact-1']!.displayName, 'Anke Brandt');
      expect(state.contacts['contact-1']!.pinned, isTrue);

      final handle = state.handles['handle-1']!;
      expect(handle.phoneE164, '+4915112345678');
      expect(handle.avatarDHash, 1234567890);
      expect(handle.unifiedContactId, 'contact-1');

      final merge = state.merges['handle-1|handle-2']!;
      expect(merge.verdict, 'same');
      expect(merge.decidedAt, DateTime.utc(2026, 5, 4, 11, 22));
      expect(merge.decidedAt.isUtc, isTrue);

      expect(state.chatPrefs['chat-1']!.sendNetwork, 'sms');
      expect(state.settings['appearance.theme_mode'], 'dark');

      final message = state.messages[r'!room1:example.org $event-1']!;
      expect(message.body, 'Sehen wir uns um acht? 🙂');
      expect(message.senderName, 'Anke');
      expect(message.chatTitle, 'Anke Brandt');
      expect(message.network, 'whatsapp');
      expect(message.timestamp, DateTime.utc(2026, 7, 14, 18, 5));
      expect(message.reactions, {'🙂': 2, '👍': 1});

      final transcript = state.transcripts[r'!room1:example.org $event-3']!;
      expect(transcript.text, 'Ich bin gleich da.');
      expect(transcript.language, 'de');
    });

    test('the manifest survives and names the networks', () async {
      final reader = await openArchiveBytes(
        await archiveOf(populated()),
        passphrase,
      );
      addTearDown(reader.close);

      expect(reader.manifest.appVersion, '1.4.0');
      expect(reader.manifest.createdAt, writtenAt);
      expect(reader.manifest.networks, ['whatsapp', 'sms']);
      expect(reader.manifest.messageCount, 2);
    });

    test('an archive of nothing at all still opens', () async {
      // The very first backup on a fresh install. An empty body still gets a
      // final frame, which is what stops it reading as truncated.
      final sink = MapSink();
      final outcome = await importInto(sink, await archiveOf(const []));
      expect(outcome.applied, 0);
      expect(sink.state.totalRows, 0);
      expect(sink.committed, isTrue);
    });

    test('a record spanning many frames round-trips', () async {
      // Frame boundaries and record boundaries are independent. A body larger
      // than one frame is the case that proves it.
      final long = 'x' * 50000;
      final records = <BackupRecord>[
        MessageRecord(
          eventId: r'$long',
          roomId: '!r:example.org',
          chatId: 'c',
          network: 'sms',
          senderId: '@s:example.org',
          timestamp: writtenAt,
          kind: 'text',
          body: long,
        ),
      ];
      final sink = MapSink();
      await importInto(sink, await archiveOf(records, frameSize: 1024));
      expect(sink.state.messages[r'!r:example.org $long']!.body, long);
    });
  });

  group('merge is idempotent', () {
    test('importing the same archive twice produces no duplicates', () async {
      final archive = await archiveOf(populated());
      final sink = MapSink();

      final first = await importInto(sink, archive);
      final rowsAfterFirst = sink.state.totalRows;

      final second = await importInto(sink, archive);

      expect(second.applied, 0, reason: 'nothing was new the second time');
      expect(second.skippedExisting, first.applied);
      expect(sink.state.totalRows, rowsAfterFirst);
    });

    test('a message already present is recognised by room and event', () async {
      final sink = MapSink();
      await importInto(sink, await archiveOf(populated()));

      // The same event id in a *different* room is a different message — a
      // bridge backfilling one remote message into two rooms — and collapsing
      // them would delete one of them on every restore.
      final other = MessageRecord(
        eventId: r'$event-1',
        roomId: '!room2:example.org',
        chatId: 'chat-2',
        network: 'sms',
        senderId: '@s:example.org',
        timestamp: writtenAt,
        kind: 'text',
        body: 'a different message that happens to share an id',
      );
      final outcome = await importInto(sink, await archiveOf([other]));

      expect(outcome.applied, 1);
      expect(sink.state.messages.length, 3);
    });

    test(
      'merge leaves an existing row alone rather than overwriting',
      () async {
        final sink = MapSink();
        await sink.begin(ImportMode.merge);
        await sink.apply(
          const ContactRecord(id: 'contact-1', displayName: 'Local name'),
        );
        await sink.commit();

        await importInto(sink, await archiveOf(populated()));
        expect(sink.state.contacts['contact-1']!.displayName, 'Local name');
      },
    );

    test('replace clears first, so the archive is the whole truth', () async {
      final sink = MapSink();
      await sink.begin(ImportMode.replace);
      await sink.apply(
        const ContactRecord(id: 'stale', displayName: 'Should not survive'),
      );
      await sink.commit();

      await importInto(
        sink,
        await archiveOf(populated()),
        mode: ImportMode.replace,
      );

      expect(sink.state.contacts.containsKey('stale'), isFalse);
      expect(sink.state.contacts.containsKey('contact-1'), isTrue);
    });
  });

  group('media', () {
    test('bytes and references both come back', () async {
      final records = populatedWithMedia();
      final sink = MapSink();
      await importInto(sink, await archiveOf(records));

      final hash = mediaContentHash(photo());
      expect(sink.state.media[hash], equals(photo()));
      expect(sink.state.mediaRefs[r'$event-2']!.fileName, 'IMG_0042.jpg');
      expect(sink.state.mediaRefs[r'$event-9']!.sha256, hash);
    });

    test('identical bytes are stored once and pointed at twice', () async {
      final records = populatedWithMedia();
      final sinkBytes = BytesArchiveSink();
      final outcome = await writeArchive(
        source: FakeSource(records, summary: summaryFor(records)),
        passphrase: passphrase,
        sink: sinkBytes,
        appVersion: '1.4.0',
        createdAt: writtenAt,
        frameSize: 4096,
        kdfOverride: cheapKdf(),
      );

      expect(outcome.mediaDeduplicated, 1);
      // Two refs survive even though one copy of the bytes was dropped.
      final sink = MapSink();
      await importInto(sink, sinkBytes.bytes);
      expect(sink.state.mediaRefs.length, 2);
      expect(sink.state.media.length, 1);
    });

    test(
      'excluding media leaves the messages that reference it intact',
      () async {
        final sink = MapSink();
        final archive = await archiveOf(
          populatedWithMedia(),
          includeMedia: false,
        );
        await importInto(sink, archive);

        expect(sink.state.media, isEmpty);
        expect(sink.state.mediaRefs, isEmpty);
        // The photo message itself is still there, still flagged as having media.
        final message = sink.state.messages[r'!room1:example.org $event-2']!;
        expect(message.hasMedia, isTrue);
        expect(message.body, 'IMG_0042.jpg');
      },
    );

    test('the manifest says media was excluded', () async {
      final reader = await openArchiveBytes(
        await archiveOf(populatedWithMedia(), includeMedia: false),
        passphrase,
      );
      addTearDown(reader.close);
      expect(reader.manifest.mediaIncluded, isFalse);
      expect(reader.manifest.mediaBytes, 0);
    });

    test('a sink that already has the content skips the bytes', () async {
      final hash = mediaContentHash(photo());
      final sink = MapSink()..refuseMedia.add(hash);

      final outcome = await importInto(
        sink,
        await archiveOf(populatedWithMedia()),
      );

      expect(outcome.mediaSkipped, 1);
      expect(outcome.mediaWritten, 0);
      // Skipping the bytes must not skip the record after them.
      expect(sink.state.mediaRefs.length, 2);
    });

    test('a media blob larger than a frame round-trips', () async {
      final big = photo(0x11, 40000);
      final hash = mediaContentHash(big);
      final records = <BackupRecord>[
        MediaRecord.ofBytes(sha256: hash, bytes: big),
        MediaRefRecord(eventId: r'$big', sha256: hash, fileName: 'video.mp4'),
      ];

      final sink = MapSink();
      await importInto(sink, await archiveOf(records, frameSize: 1024));
      expect(sink.state.media[hash], equals(big));
    });

    test('a source that lies about a blob length fails the export', () async {
      final records = <BackupRecord>[
        MediaRecord(
          sha256: 'a' * 64,
          sizeBytes: 4096,
          openBytes: () => Stream.value(photo(0x01, 10)),
        ),
      ];
      expect(() => archiveOf(records), throwsA(isA<StateError>()));
    });
  });

  group('typed failures', () {
    test('a wrong passphrase says so, and writes nothing', () async {
      final sink = MapSink();
      await expectLater(
        importInto(sink, await archiveOf(populated()), pass: 'wrong'),
        throwsA(isA<WrongPassphraseFailure>()),
      );
      expect(sink.state.totalRows, 0);
    });

    test('a file that is not an archive says so', () async {
      expect(
        () => openArchiveBytes(
          Uint8List.fromList(utf8.encode('just a text file')),
          passphrase,
        ),
        throwsA(isA<NotAnArchiveFailure>()),
      );
    });

    test('a truncated file says truncated, not wrong passphrase', () async {
      final full = await archiveOf(populated());
      final cut = Uint8List.sublistView(full, 0, full.length - 40);
      expect(
        () =>
            openArchiveBytes(cut, passphrase).then((r) => r.records().toList()),
        throwsA(isA<TruncatedArchiveFailure>()),
      );
    });

    test('truncating exactly at a frame boundary is still caught', () async {
      // The final-frame flag is what catches this. Every remaining frame
      // authenticates perfectly; the file is simply missing its end.
      final full = await archiveOf(populated(), frameSize: 1024);
      final reader = await openArchiveBytes(full, passphrase);
      await reader.close();

      // Walk the frame headers to find a real boundary rather than guessing.
      var offset = parseArchiveHeader(full).header!.bytes.length;
      var boundary = offset;
      while (offset + 5 <= full.length) {
        final length = readUint32(full, offset);
        final isFinal = full[offset + 4] == 1;
        offset += 5 + length;
        if (isFinal) break;
        boundary = offset;
      }
      expect(boundary, lessThan(full.length), reason: 'need >1 frame');

      expect(
        () => openArchiveBytes(
          Uint8List.sublistView(full, 0, boundary),
          passphrase,
        ).then((r) => r.records().toList()),
        throwsA(isA<TruncatedArchiveFailure>()),
      );
    });

    test('a bit flipped deep in the ciphertext says damaged', () async {
      final full = await archiveOf(populated(), frameSize: 1024);
      final headerLength = parseArchiveHeader(full).header!.bytes.length;
      final firstFrameLength = readUint32(full, headerLength);

      // Past the first frame, so the key has already proven itself and the
      // honest answer is "this file is damaged" rather than "wrong passphrase".
      final flipped = Uint8List.fromList(full);
      flipped[headerLength + 5 + firstFrameLength + 10] ^= 0x01;

      expect(
        () => openArchiveBytes(
          flipped,
          passphrase,
        ).then((r) => r.records().toList()),
        throwsA(isA<DamagedArchiveFailure>()),
      );
    });

    test(
      'a bit flipped in the first frame reads as a wrong passphrase',
      () async {
        final full = await archiveOf(populated());
        final headerLength = parseArchiveHeader(full).header!.bytes.length;
        final flipped = Uint8List.fromList(full)..[headerLength + 6] ^= 0x01;

        expect(
          () => openArchiveBytes(flipped, passphrase),
          throwsA(isA<WrongPassphraseFailure>()),
        );
      },
    );

    test('an edited header fails even when the key is untouched', () async {
      // The header has no MAC of its own, so the only thing standing between an
      // attacker and a rewritten one is its use as associated data. The edit
      // here is deliberately a field the *key derivation does not depend on* —
      // the app version in the preview — so that the failure can only come from
      // the AAD binding. Tampering with `memoryKiB` instead would fail anyway,
      // by deriving a different key, and would prove nothing about the binding.
      final full = await archiveOf(populated());
      final header = parseArchiveHeader(full).header!;
      final json =
          jsonDecode(utf8.decode(full.sublist(12, header.bytes.length)))
              as Map<String, Object?>;

      final preview = json['preview']! as Map<String, Object?>;
      expect(preview['appVersion'], '1.4.0');
      preview['appVersion'] = '1.4.0 (tampered)';

      final rebuilt = utf8.encode(jsonEncode(json));
      final tampered = Uint8List.fromList([
        ...kBraidArchiveMagic,
        ...uint32Bytes(rebuilt.length),
        ...rebuilt,
        ...full.sublist(header.bytes.length),
      ]);

      await expectLater(
        openArchiveBytes(tampered, passphrase),
        throwsA(isA<WrongPassphraseFailure>()),
      );
    });

    test(
      'lowering the KDF cost in the header does not weaken anything',
      () async {
        // The attack the binding is really there for: rewrite Argon2id's cost
        // down so the passphrase can be brute-forced cheaply. It fails twice
        // over — a different key, and a header that no longer matches the AAD.
        final full = await archiveOf(populated());
        final header = parseArchiveHeader(full).header!;
        final json =
            jsonDecode(utf8.decode(full.sublist(12, header.bytes.length)))
                as Map<String, Object?>;

        final kdf = json['kdf']! as Map<String, Object?>;
        expect(
          kdf['memoryKiB'],
          8,
          reason: 'the test fixture is the cheap KDF',
        );
        kdf['memoryKiB'] = 4096;

        final rebuilt = utf8.encode(jsonEncode(json));
        final tampered = Uint8List.fromList([
          ...kBraidArchiveMagic,
          ...uint32Bytes(rebuilt.length),
          ...rebuilt,
          ...full.sublist(header.bytes.length),
        ]);

        await expectLater(
          openArchiveBytes(tampered, passphrase),
          throwsA(isA<WrongPassphraseFailure>()),
        );
      },
    );

    test('a future major version refuses with the version named', () async {
      final full = await archiveOf(populated());
      final header = parseArchiveHeader(full).header!;
      final json =
          jsonDecode(utf8.decode(full.sublist(12, header.bytes.length)))
              as Map<String, Object?>;
      json['format'] = {
        'major': kBraidArchiveFormatVersion.major + 5,
        'minor': 0,
      };

      final rebuilt = utf8.encode(jsonEncode(json));
      final bumped = Uint8List.fromList([
        ...kBraidArchiveMagic,
        ...uint32Bytes(rebuilt.length),
        ...rebuilt,
        ...full.sublist(header.bytes.length),
      ]);

      await expectLater(
        openArchiveBytes(bumped, passphrase),
        throwsA(
          isA<UnsupportedVersionFailure>().having(
            (f) => f.version.major,
            'major',
            kBraidArchiveFormatVersion.major + 5,
          ),
        ),
      );
    });

    test('a failed import rolls the sink back', () async {
      final sink = MapSink();
      final full = await archiveOf(populated(), frameSize: 1024);
      final headerLength = parseArchiveHeader(full).header!.bytes.length;
      final firstFrameLength = readUint32(full, headerLength);
      final flipped = Uint8List.fromList(full);
      flipped[headerLength + 5 + firstFrameLength + 10] ^= 0x01;

      final reader = await openArchiveBytes(flipped, passphrase);
      await expectLater(
        importArchive(reader: reader, sink: sink),
        throwsA(isA<DamagedArchiveFailure>()),
      );

      expect(sink.rolledBack, isTrue);
      expect(sink.committed, isFalse);
      expect(sink.state.totalRows, 0, reason: 'no half-populated store');
    });
  });

  group('forward compatibility', () {
    /// An archive written by a Braid that knows one record type and one message
    /// field more than this build does, at a bumped minor version.
    Future<Uint8List> futureArchive() async {
      final records = <BackupRecord>[
        ...populated(),
        // `UnknownRecord` is the writer-side escape hatch as well as the
        // reader-side one: it encodes to whatever `type` and fields it is
        // given, which is exactly how a record type this build has never heard
        // of would arrive.
        const UnknownRecord('holiday_plan', {
          'destination': 'Sylt',
          'nights': 4,
        }),
        // A *known* type carrying a field this build does not model.
        const UnknownRecord(BackupRecordType.message, {
          'eventId': r'$future',
          'roomId': '!future:example.org',
          'chatId': 'chat-future',
          'network': 'whatsapp',
          'senderId': '@s:example.org',
          'senderName': 'Someone',
          'timestamp': 1780000000000,
          'kind': 'text',
          'body': 'written by a newer Braid',
          'quantumSignature': {'algorithm': 'dilithium', 'value': 'abc'},
        }),
      ];
      final sink = BytesArchiveSink();
      await writeArchive(
        source: FakeSource(records, summary: summaryFor(records)),
        passphrase: passphrase,
        sink: sink,
        appVersion: '9.9.9',
        createdAt: writtenAt,
        frameSize: 4096,
        kdfOverride: cheapKdf(),
      );

      // Bump the minor after the fact, the way a future writer's header would
      // arrive. The header is associated data, so it is re-signed by re-writing
      // the whole archive rather than edited — which is exactly why this test
      // rebuilds it below instead of patching bytes.
      return sink.bytes;
    }

    test('an unknown record type is skipped and counted, not fatal', () async {
      final sink = MapSink();
      final outcome = await importInto(sink, await futureArchive());

      expect(outcome.skippedUnknownType, 1);
      expect(outcome.unknownTypes, {'holiday_plan'});
      expect(outcome.isComplete, isFalse);
      // Everything this build *does* understand still landed.
      expect(sink.state.contacts.length, 1);
      expect(sink.state.messages.length, 3);
    });

    test('an unknown field on a known record is ignored, not fatal', () async {
      final sink = MapSink();
      await importInto(sink, await futureArchive());

      final message = sink.state.messages[r'!future:example.org $future']!;
      expect(message.body, 'written by a newer Braid');
      expect(message.senderName, 'Someone');
    });

    test('a bumped minor version still imports, and is flagged', () async {
      // Written as a whole archive at the future version, because the header is
      // the AEAD's associated data and cannot be edited after the fact.
      final records = populated();
      final bytes = BytesArchiveSink();
      final kdf = cheapKdf();
      final cipher = CipherParameters(noncePrefix: Uint8List(16));
      final futureVersion = ArchiveVersion(
        kBraidArchiveFormatVersion.major,
        kBraidArchiveFormatVersion.minor + 3,
      );

      final header = encodeArchiveHeader(
        version: futureVersion,
        kdf: kdf,
        cipher: cipher,
        preview: ArchivePreview(createdAt: writtenAt, appVersion: '9.9.9'),
      );
      await bytes.add(header);

      final frames = FrameCipher(
        key: await deriveArchiveKey(passphrase, kdf),
        cipher: cipher,
        headerBytes: header,
      );

      final body = BytesBuilder(copy: false);
      final manifest = utf8.encode(
        jsonEncode(
          ArchiveManifest(
            createdAt: writtenAt,
            appVersion: '9.9.9',
            networks: const ['whatsapp'],
            // A field this build does not model, in the manifest.
            messageCount: 2,
          ).toJson()..['weatherOnTheDay'] = 'raining',
        ),
      );
      body
        ..add(uint32Bytes(manifest.length))
        ..add(manifest);
      for (final record in records) {
        final json = encodeBackupRecord(record);
        body
          ..add(uint32Bytes(json.length))
          ..add(json)
          ..add(uint32Bytes(0));
      }
      body.add(uint32Bytes(0));

      await bytes.add(
        uint32Bytes(
          (await frames.seal(
            body.toBytes(),
            frameIndex: 0,
            isFinal: true,
          )).length,
        ),
      );
      await bytes.add(<int>[1]);
      await bytes.add(
        await frames.seal(body.toBytes(), frameIndex: 0, isFinal: true),
      );

      final reader = await openArchiveBytes(bytes.bytes, passphrase);
      addTearDown(reader.close);

      expect(reader.isFutureMinor, isTrue);
      expect(reader.manifest.appVersion, '9.9.9');

      final sink = MapSink();
      final outcome = await importArchive(reader: reader, sink: sink);
      expect(outcome.applied, records.length);
      expect(outcome.skippedUnknownType, 0);
    });
  });

  group('streaming', () {
    test('a large archive imports without being held whole', () async {
      // 64 media entries of 512 KiB — a 32 MB archive. The assertion that
      // matters is not the number but the shape: peak memory here is one frame
      // plus one 256 KiB blob chunk, so this passes on a device where loading
      // the archive into a `Uint8List` would not.
      const count = 64;
      const size = 512 * 1024;

      final hashes = <String>[];
      for (var i = 0; i < count; i++) {
        hashes.add(mediaContentHash(photo(i & 0xFF, size)));
      }

      Stream<BackupRecord> generate({required bool includeMedia}) async* {
        for (var i = 0; i < count; i++) {
          // Built on demand and dropped straight after, so the *source* never
          // holds the set either.
          yield MediaRecord(
            sha256: hashes[i],
            sizeBytes: size,
            openBytes: () async* {
              // In 64 KiB pieces, the way a file read would arrive.
              const chunk = 64 * 1024;
              for (var written = 0; written < size; written += chunk) {
                yield Uint8List.fromList(List<int>.filled(chunk, i & 0xFF));
              }
            },
          );
          yield MediaRefRecord(
            eventId: '\$event-$i',
            sha256: hashes[i],
            fileName: 'file-$i.bin',
          );
        }
      }

      final directory = await Directory.systemTemp.createTemp('braid-backup');
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/large.braid');

      final outcome = await exportArchiveToFile(
        source: GeneratedSource(
          summary: const BackupSummary(
            mediaCount: count,
            mediaBytes: count * size,
            otherRecordCount: count,
          ),
          generate: generate,
        ),
        passphrase: passphrase,
        target: target,
        appVersion: '1.4.0',
        createdAt: writtenAt,
        kdfOverride: cheapKdf(),
      );

      expect(outcome.recordsWritten, count * 2);
      expect(await target.length(), greaterThan(count * size));

      // Counting rather than keeping: a sink that stored the bytes would be
      // the thing under test holding 32 MB, which is what this is checking is
      // unnecessary.
      final counting = _CountingSink();
      final reader = await openArchiveFile(target, passphrase);
      final imported = await importArchive(reader: reader, sink: counting);
      await reader.close();

      expect(imported.mediaWritten, count);
      expect(counting.mediaBytes, count * size);
      expect(counting.largestChunk, lessThanOrEqualTo(256 * 1024));
    });
  });

  group('export to a file', () {
    test('a finished export lands under its final name', () async {
      final directory = await Directory.systemTemp.createTemp('braid-backup');
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/backup.braid');

      final records = populated();
      await exportArchiveToFile(
        source: FakeSource(records, summary: summaryFor(records)),
        passphrase: passphrase,
        target: target,
        appVersion: '1.4.0',
        createdAt: writtenAt,
        kdfOverride: cheapKdf(),
      );

      expect(target.existsSync(), isTrue);
      expect(File('${target.path}.part').existsSync(), isFalse);

      final preview = await readArchiveFilePreview(target);
      expect(preview.appVersion, '1.4.0');
      expect(preview.createdAt, writtenAt);
    });

    test('cancelling leaves nothing at the destination', () async {
      final directory = await Directory.systemTemp.createTemp('braid-backup');
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/backup.braid');

      final records = populated();
      var seen = 0;
      await expectLater(
        exportArchiveToFile(
          source: FakeSource(records, summary: summaryFor(records)),
          passphrase: passphrase,
          target: target,
          appVersion: '1.4.0',
          createdAt: writtenAt,
          kdfOverride: cheapKdf(),
          shouldContinue: () async => ++seen < 3,
        ),
        throwsA(isA<BackupCancelledException>()),
      );

      expect(target.existsSync(), isFalse, reason: 'no half archive');
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('progress climbs and ends at the whole file', () async {
      final records = populatedWithMedia();
      final seen = <BackupProgress>[];
      final sink = BytesArchiveSink();

      await writeArchive(
        source: FakeSource(records, summary: summaryFor(records)),
        passphrase: passphrase,
        sink: sink,
        appVersion: '1.4.0',
        createdAt: writtenAt,
        frameSize: 1024,
        kdfOverride: cheapKdf(),
        onProgress: seen.add,
      );

      expect(seen, isNotEmpty);
      expect(seen.last.bytes, sink.length);
      expect(seen.last.fraction, 1.0);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].bytes, greaterThanOrEqualTo(seen[i - 1].bytes));
      }
    });
  });
}

/// A sink that measures instead of storing, so the streaming test does not
/// itself become the thing that holds the archive in memory.
class _CountingSink implements BackupSink {
  int mediaBytes = 0;
  int largestChunk = 0;

  @override
  Future<void> begin(ImportMode mode) async {}

  @override
  Future<bool> apply(BackupRecord record) async => true;

  @override
  Future<MediaWriter?> beginMedia(String sha256, int sizeBytes) async =>
      _CountingWriter(this);

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

class _CountingWriter implements MediaWriter {
  _CountingWriter(this._sink);

  final _CountingSink _sink;

  @override
  Future<void> add(List<int> bytes) async {
    _sink.mediaBytes += bytes.length;
    if (bytes.length > _sink.largestChunk) _sink.largestChunk = bytes.length;
  }

  @override
  Future<void> finish() async {}

  @override
  Future<void> abort() async {}
}
