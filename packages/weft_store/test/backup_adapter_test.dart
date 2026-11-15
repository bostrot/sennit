import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft_backup/weft_backup.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

/// The pure-Dart suite in `weft_backup` proves the *format*. This one proves
/// the SQL underneath it: that every table this schema has is either in an
/// archive or deliberately out of one, that merge really is
/// `ON CONFLICT DO NOTHING` all the way down, and that a rollback leaves a
/// database indistinguishable from the one before the restore started.
void main() {
  late WeftDatabase source;
  late WeftDatabase target;
  late Directory workspace;

  /// Cheap KDF, for the reason `weft_backup`'s fakes give: these cases are
  /// about SQL, and paying 64 MiB of Argon2id per case buys nothing.
  final kdf = KdfParameters(
    salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
    memoryKiB: 8,
    iterations: 1,
    parallelism: 1,
  );

  setUp(() async {
    source = WeftDatabase.openAt(':memory:');
    target = WeftDatabase.openAt(':memory:');
    workspace = await Directory.systemTemp.createTemp('sennit-adapter');
  });

  tearDown(() async {
    source.dispose();
    target.dispose();
    if (workspace.existsSync()) await workspace.delete(recursive: true);
  });

  Directory mediaDir(String name) =>
      Directory(p.join(workspace.path, name))..createSync(recursive: true);

  /// Puts one attachment on disk the way `stageAttachment` does: a folder named
  /// for the sanitised event id, holding one file.
  File stage(Directory root, String eventFolder, String name, List<int> bytes) {
    final file = File(p.join(root.path, eventFolder, name))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return file;
  }

  void seed(WeftDatabase db) {
    final identity = IdentityStore(db);
    identity.upsertHandle(
      const NetworkHandle(
        id: 'handle-1',
        network: ChatNetwork.whatsapp,
        remoteId: '4915112345678',
        matrixUserId: '@wa_4915112345678:example.org',
        roomId: '!room1:example.org',
        displayName: 'Anke',
        phoneE164: '+4915112345678',
        unifiedContactId: 'contact-1',
      ),
    );
    identity.saveDecision((
      pair: 'handle-1|handle-2',
      verdict: 'same',
      source: 'user',
      decidedAt: DateTime.utc(2026, 5, 4),
    ));
    identity.setSendNetwork('chat-1', ChatNetwork.sms);

    final settings = SettingsStore(db)
      ..setString('appearance.theme_mode', 'dark')
      // Device-scoped: must not travel.
      ..setString('notify.push_key', 'fcm-token-of-this-phone');

    // Read back so the seeding is not silently a no-op.
    expect(settings.getString('appearance.theme_mode'), 'dark');

    SearchStore(db).indexMessages(
      [
        WeftMessage(
          eventId: r'$event-1',
          roomId: '!room1:example.org',
          network: ChatNetwork.whatsapp,
          senderId: '@wa_4915112345678:example.org',
          senderName: 'Anke',
          timestamp: DateTime.utc(2026, 7, 14, 18, 5),
          kind: MessageKind.text,
          isOwn: false,
          body: 'Sehen wir uns um acht?',
        ),
        WeftMessage(
          eventId: r'$event-2',
          roomId: '!room1:example.org',
          network: ChatNetwork.whatsapp,
          senderId: '@me:example.org',
          senderName: 'Me',
          timestamp: DateTime.utc(2026, 7, 14, 18, 7),
          kind: MessageKind.image,
          isOwn: true,
          body: 'IMG_0042.jpg',
          attachmentUrl: 'mxc://example.org/photo',
        ),
      ],
      chatId: 'chat-1',
      chatTitle: 'Anke Brandt',
    );

    TranscriptStore(db).save(
      const StoredTranscript(
        eventId: r'$event-3',
        roomId: '!room1:example.org',
        text: 'Ich bin gleich da.',
        provider: 'whisper-local',
        language: 'de',
      ),
    );

    // A cache the archive deliberately never carries.
    LinkPreviewStore(db).write('https://example.org', {'title': 'Example'});
  }

  Future<List<int>> archive(
    WeftDatabase db, {
    Directory? media,
    bool includeMedia = true,
    int frameSize = kDefaultFrameSize,
  }) async {
    final sink = BytesArchiveSink();
    await writeArchive(
      source: StoreBackupSource(database: db, mediaDirectory: media),
      passphrase: 'passphrase',
      sink: sink,
      appVersion: '1.4.0',
      createdAt: DateTime.utc(2026, 8, 28),
      includeMedia: includeMedia,
      frameSize: frameSize,
      kdfOverride: kdf,
    );
    return sink.bytes;
  }

  Future<ImportOutcome> restore(
    List<int> bytes,
    WeftDatabase db, {
    Directory? media,
    ImportMode mode = ImportMode.merge,
  }) async {
    final reader = await openArchiveBytes(
      Uint8List.fromList(bytes),
      'passphrase',
    );
    try {
      return await importArchive(
        reader: reader,
        sink: StoreBackupSink(database: db, mediaDirectory: media),
        mode: mode,
      );
    } finally {
      await reader.close();
    }
  }

  int count(WeftDatabase db, String table) =>
      db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;

  group('what a complete backup captures', () {
    test('every table round-trips into an empty database', () async {
      seed(source);
      await restore(await archive(source), target);

      expect(count(target, 'unified_contact'), 1);
      expect(count(target, 'network_handle'), 1);
      expect(count(target, 'merge_decision'), 1);
      expect(count(target, 'chat_prefs'), 1);
      expect(count(target, 'search_message'), 2);
      expect(count(target, 'transcript'), 1);

      final handle = IdentityStore(target).loadHandles().single;
      expect(handle.phoneE164, '+4915112345678');
      expect(handle.unifiedContactId, 'contact-1');

      final decision = IdentityStore(target).loadDecisions().single;
      expect(decision.verdict, 'same');
      expect(decision.decidedAt, DateTime.utc(2026, 5, 4));

      expect(IdentityStore(target).sendNetworkFor('chat-1'), ChatNetwork.sms);
      expect(SettingsStore(target).getString('appearance.theme_mode'), 'dark');

      final transcript = TranscriptStore(
        target,
      ).byEvent(r'$event-3', '!room1:example.org')!;
      expect(transcript.text, 'Ich bin gleich da.');
      expect(transcript.language, 'de');
    });

    test('restored messages are findable again', () async {
      // The FTS triggers fire on insert, so search works without a reindex.
      // If they did not, a restore would give back a history the user could
      // read but never find, which is the failure nobody notices until later.
      seed(source);
      await restore(await archive(source), target);

      final hits = await SearchStore(target).keywordSearch('acht');
      expect(hits, isNotEmpty);
    });

    test('restored messages are queued for embedding', () async {
      // Nothing called `indexMessage`, so without the sweep on commit the
      // vector index would have a hole exactly where the restored history is.
      seed(source);
      await restore(await archive(source), target);
      expect(SearchStore(target).pendingEmbeddingCount, 2);
    });

    test('the device-scoped push key does not travel', () async {
      seed(source);
      await restore(await archive(source), target);

      expect(
        SettingsStore(target).getString('notify.push_key'),
        isNull,
        reason: 'restoring it would delete a live pusher on another device',
      );
    });

    test('the link preview cache is deliberately left behind', () async {
      seed(source);
      await restore(await archive(source), target);
      expect(count(target, 'link_preview'), 0);
    });

    test('the manifest names the networks actually present', () async {
      seed(source);
      final reader = await openArchiveBytes(
        Uint8List.fromList(await archive(source)),
        'passphrase',
      );
      addTearDown(reader.close);

      expect(reader.manifest.networks, ['whatsapp']);
      expect(reader.manifest.messageCount, 2);
      expect(reader.manifest.chatCount, 1);
    });
  });

  group('merge', () {
    test('restoring twice changes nothing the second time', () async {
      seed(source);
      final bytes = await archive(source);

      final first = await restore(bytes, target);
      final rows = count(target, 'search_message');
      final second = await restore(bytes, target);

      expect(second.applied, 0);
      expect(second.skippedExisting, first.applied);
      expect(count(target, 'search_message'), rows);
    });

    test('a local row wins over the archive', () async {
      // Restoring a six-month-old backup must not roll back six months of
      // display names and merge verdicts.
      seed(source);
      IdentityStore(
        target,
      ).ensureContact('contact-1', displayName: 'The name I use now');

      await restore(await archive(source), target);

      final name =
          target.raw.select(
                'SELECT display_name FROM unified_contact WHERE id = ?',
                ['contact-1'],
              ).first['display_name']
              as String;
      expect(name, 'The name I use now');
    });

    test(
      'replace clears the tables the archive covers, and only those',
      () async {
        seed(source);
        SettingsStore(target).setString('appearance.theme_mode', 'light');
        LinkPreviewStore(target).write('https://kept.example', null);

        await restore(await archive(source), target, mode: ImportMode.replace);

        expect(
          SettingsStore(target).getString('appearance.theme_mode'),
          'dark',
          reason: 'replace means the archive is the whole truth',
        );
        expect(
          count(target, 'link_preview'),
          1,
          reason: 'the cache is not the archive\'s to clear',
        );
      },
    );

    test(
      'a handle whose contact is missing keeps the message, drops the merge',
      () async {
        // The foreign key would otherwise fail the whole restore. Losing one
        // merge assignment beats losing every message in the archive.
        seed(source);
        final bytes = await archive(source);

        // Import into a database where the contact record is filtered out, by
        // restoring the handle alone.
        final reader = await openArchiveBytes(
          Uint8List.fromList(bytes),
          'passphrase',
        );
        final records = <BackupRecord>[];
        await for (final record in reader.records()) {
          if (record is! ContactRecord) records.add(record);
        }
        await reader.close();

        final sink = StoreBackupSink(database: target);
        await sink.begin(ImportMode.merge);
        for (final record in records) {
          await sink.apply(record);
        }
        await sink.commit();

        final handle = IdentityStore(target).loadHandles().single;
        expect(handle.id, 'handle-1');
        expect(handle.unifiedContactId, isNull);
        expect(count(target, 'search_message'), 2);
      },
    );
  });

  group('media', () {
    test('attachments round-trip into the right folders', () async {
      seed(source);
      final from = mediaDir('from');
      final to = mediaDir('to');
      stage(from, '_event-2', 'IMG_0042.jpg', List<int>.filled(2048, 0x42));

      final outcome = await restore(
        await archive(source, media: from),
        target,
        media: to,
      );

      expect(outcome.mediaWritten, 1);
      final restored = File(p.join(to.path, '_event-2', 'IMG_0042.jpg'));
      expect(restored.existsSync(), isTrue);
      expect(restored.lengthSync(), 2048);
    });

    test(
      'the same bytes in two folders are stored once, restored twice',
      () async {
        seed(source);
        final from = mediaDir('from');
        final to = mediaDir('to');
        final bytes = List<int>.filled(4096, 0x7E);
        stage(from, '_event-2', 'photo.jpg', bytes);
        stage(from, '_event-9', 'photo.jpg', bytes);

        final sink = BytesArchiveSink();
        final export = await writeArchive(
          source: StoreBackupSource(database: source, mediaDirectory: from),
          passphrase: 'passphrase',
          sink: sink,
          appVersion: '1.4.0',
          createdAt: DateTime.utc(2026, 8, 28),
          kdfOverride: kdf,
        );
        expect(export.mediaDeduplicated, 1);

        await restore(sink.bytes, target, media: to);
        expect(
          File(p.join(to.path, '_event-2', 'photo.jpg')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(to.path, '_event-9', 'photo.jpg')).existsSync(),
          isTrue,
        );
      },
    );

    test('an unfinished download is not archived', () async {
      seed(source);
      final from = mediaDir('from');
      stage(from, '_event-2', 'photo.jpg.part', List<int>.filled(10, 1));

      final reader = await openArchiveBytes(
        Uint8List.fromList(await archive(source, media: from)),
        'passphrase',
      );
      addTearDown(reader.close);
      expect(reader.manifest.mediaCount, 0);
    });

    test('excluding media leaves the messages referencing it intact', () async {
      seed(source);
      final from = mediaDir('from');
      final to = mediaDir('to');
      stage(from, '_event-2', 'IMG_0042.jpg', List<int>.filled(512, 3));

      await restore(
        await archive(source, media: from, includeMedia: false),
        target,
        media: to,
      );

      expect(count(target, 'search_message'), 2);
      final hasMedia =
          target.raw.select(
                'SELECT has_media FROM search_message WHERE event_id = ?',
                [r'$event-2'],
              ).first['has_media']
              as int;
      expect(
        hasMedia,
        1,
        reason: 'the message still knows it has an attachment',
      );
      expect(Directory(p.join(to.path, '_event-2')).existsSync(), isFalse);
    });

    test('a hostile file name cannot escape the media directory', () async {
      // The archive is an untrusted file. A `media_ref` naming `../../` must
      // land inside the media root, sanitised, rather than wherever it asked.
      seed(source);
      final to = mediaDir('to');
      final bytes = List<int>.filled(64, 9);
      final hash = mediaContentHash(bytes);

      final sink = StoreBackupSink(database: target, mediaDirectory: to);
      await sink.begin(ImportMode.merge);
      final writer = await sink.beginMedia(hash, bytes.length);
      await writer!.add(bytes);
      await writer.finish();
      await sink.apply(
        MediaRefRecord(
          eventId: '../../../escaped',
          sha256: hash,
          fileName: '../../../etc/passwd',
        ),
      );
      await sink.commit();

      expect(File(p.join(workspace.path, 'escaped')).existsSync(), isFalse);
      expect(
        Directory(to.path).listSync(recursive: true).whereType<File>().length,
        1,
        reason: 'exactly one file, inside the media root',
      );
    });
  });

  group('rollback', () {
    test('a failed restore leaves the database untouched', () async {
      seed(source);
      // A small frame size on purpose: the seeded database fits in a single
      // default 1 MiB frame, and a one-frame archive can only fail at the
      // passphrase check — which is a different code path from the one this
      // case is about.
      final bytes = Uint8List.fromList(await archive(source, frameSize: 1024));

      // Corrupt a byte past the first frame, so the failure lands mid-import
      // rather than at the passphrase check.
      final header = parseArchiveHeader(bytes).header!;
      final firstFrame = readUint32(bytes, header.bytes.length);
      final damaged = List<int>.from(bytes);
      final offset = header.bytes.length + 5 + firstFrame + 4;

      // Asserted rather than guarded: an `if` here would turn a fixture that
      // stopped producing two frames into a test that passes without running.
      expect(
        offset,
        lessThan(damaged.length),
        reason: 'the fixture must span more than one frame',
      );
      damaged[offset] ^= 0x01;

      final before = count(target, 'search_message');
      await expectLater(
        restore(damaged, target),
        throwsA(isA<ArchiveOpenFailure>()),
      );
      expect(count(target, 'search_message'), before);
      expect(count(target, 'unified_contact'), 0);
    });

    test('a rollback sweeps the staging directory', () async {
      final to = mediaDir('to');
      final sink = StoreBackupSink(database: target, mediaDirectory: to);
      await sink.begin(ImportMode.merge);
      final writer = await sink.beginMedia('a' * 64, 4);
      await writer!.add([1, 2, 3, 4]);
      await writer.finish();
      await sink.rollback();

      expect(Directory(p.join(to.path, '.restore')).existsSync(), isFalse);
    });
  });
}
