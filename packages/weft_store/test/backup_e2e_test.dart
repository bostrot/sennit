/// The end-to-end pass, as a test rather than as a checklist somebody runs.
///
/// Everything else in this phase's suites is fast on purpose: `:memory:`
/// databases, an 8 KiB Argon2id, byte lists standing in for files. That is the
/// right trade for two hundred cases about framing and merge rules, and it
/// leaves exactly one thing unproven — that the whole thing works **on a real
/// profile, at the real cost, through real files**.
///
/// So this one does what the manual pass does: a database on disk, attachments
/// in a directory, an export at the shipping Argon2id parameters, the profile
/// wiped, and a restore into an empty one. It is slow — a real 64 MiB, 3-pass
/// derivation runs twice — and it is one test, which is the correct ratio.
///
/// Tagged so it can be excluded from a fast loop:
/// `flutter test --exclude-tags slow`. The tag is declared in
/// `packages/weft_store/dart_test.yaml`.
@Tags(['slow'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft_backup/weft_backup.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  late Directory profile;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('sennit-e2e');
  });

  tearDown(() async {
    if (profile.existsSync()) await profile.delete(recursive: true);
  });

  Directory sub(String name) =>
      Directory(p.join(profile.path, name))..createSync(recursive: true);

  /// A profile with something in it worth losing.
  void seed(WeftDatabase db, Directory media) {
    final identity = IdentityStore(db);

    // Two handles for one person on two networks, merged by the user. This is
    // the fact that exists nowhere but on this device.
    for (final (id, network, remote) in const [
      ('h-wa', ChatNetwork.whatsapp, '4915112345678'),
      ('h-sms', ChatNetwork.sms, '+4915112345678'),
    ]) {
      identity.upsertHandle(
        NetworkHandle(
          id: id,
          network: network,
          remoteId: remote,
          matrixUserId: '@${id}_$remote:example.org',
          roomId: '!room-$id:example.org',
          displayName: 'Anke Brandt',
          phoneE164: '+4915112345678',
          unifiedContactId: 'c-anke',
        ),
      );
    }
    identity.saveDecision((
      pair: 'h-sms|h-wa',
      verdict: 'same',
      source: 'user',
      decidedAt: DateTime.utc(2026, 5, 4, 11, 22),
    ));
    identity.setSendNetwork('chat-anke', ChatNetwork.sms);

    SettingsStore(db)
      ..setString('appearance.theme_mode', 'dark')
      ..setString('notify.push_key', 'this-phone-only');

    final search = SearchStore(db);
    // Enough rows to cross the default frame boundary in the body.
    search.indexMessages(
      [
        for (var i = 0; i < 400; i++)
          WeftMessage(
            eventId: '\$event-$i',
            roomId: '!room-h-wa:example.org',
            network: ChatNetwork.whatsapp,
            senderId: '@h-wa_4915112345678:example.org',
            senderName: 'Anke Brandt',
            timestamp: DateTime.utc(2026, 7, 14, 18).add(Duration(minutes: i)),
            kind: MessageKind.text,
            isOwn: i.isEven,
            body: 'Nachricht Nummer $i über Sylt und den Zug um acht.',
          ),
      ],
      chatId: 'chat-anke',
      chatTitle: 'Anke Brandt',
    );
    search.indexMessages(
      [
        WeftMessage(
          eventId: r'$photo',
          roomId: '!room-h-sms:example.org',
          network: ChatNetwork.sms,
          senderId: '@h-sms_4915112345678:example.org',
          senderName: 'Anke Brandt',
          timestamp: DateTime.utc(2026, 7, 14, 19),
          kind: MessageKind.image,
          isOwn: false,
          body: 'IMG_0042.jpg',
          attachmentUrl: 'mxc://example.org/photo',
        ),
      ],
      chatId: 'chat-anke',
      chatTitle: 'Anke Brandt',
    );

    TranscriptStore(db).save(
      const StoredTranscript(
        eventId: r'$voice',
        roomId: '!room-h-wa:example.org',
        text: 'Ich bin gleich da, warte am Gleis vier.',
        provider: 'whisper-local',
        language: 'de',
      ),
    );

    // Two attachments, one of them the same bytes in two places so dedup has
    // something real to do.
    final photo = List<int>.generate(512 * 1024, (i) => i & 0xFF);
    for (final folder in const ['_photo', '_photo-forwarded']) {
      File(p.join(media.path, folder, 'IMG_0042.jpg'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(photo);
    }
    File(p.join(media.path, '_voice', 'note.ogg'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(96 * 1024, 7));
  }

  // `test`, not `testWidgets`. A widget test body runs inside a `FakeAsync`
  // zone, and the pure-Dart Argon2id yields through real timers and isolates —
  // neither of which fake async will ever advance, so the derivation simply
  // never returns and the case dies on its timeout. Nothing here needs a
  // widget tree anyway.
  test(
    'a real profile survives export, a wipe, and a restore',
    () async {
      // ---------------------------------------------------------- before
      final beforeDir = sub('before');
      final beforeMedia = sub('before-media');
      final before = WeftDatabase.openAt(p.join(beforeDir.path, 'weft.db'));
      addTearDown(before.dispose);
      seed(before, beforeMedia);

      final archive = File(p.join(profile.path, 'sennit-2026-08-28.sennit'));
      final progress = <BackupProgress>[];

      // No `kdfOverride`: the shipping Argon2id parameters, because "does a
      // 64 MiB derivation actually complete here" is one of the things a
      // manual pass is for.
      final export = await exportArchiveToFile(
        source: StoreBackupSource(
          database: before,
          mediaDirectory: beforeMedia,
        ),
        passphrase: 'der Zug um acht nach Sylt',
        target: archive,
        appVersion: '1.0.0',
        createdAt: DateTime.utc(2026, 8, 28, 9, 30),
        onProgress: progress.add,
      );

      expect(archive.existsSync(), isTrue);
      expect(File('${archive.path}.part').existsSync(), isFalse);
      expect(export.mediaDeduplicated, 1, reason: 'one photo, stored once');
      expect(progress, isNotEmpty);
      expect(
        await archive.length(),
        greaterThan(512 * 1024),
        reason: 'the media is really in there',
      );

      // The header is readable with no passphrase, and says nothing about
      // which networks this person is on.
      final preview = await readArchiveFilePreview(archive);
      expect(preview.appVersion, '1.0.0');
      expect(preview.messageCount, 401);
      expect(preview.mediaIncluded, isTrue);
      expect(archive.readAsBytesSync().length, greaterThan(0));

      // -------------------------------------------------------- the wipe
      before.dispose();
      await beforeDir.delete(recursive: true);
      await beforeMedia.delete(recursive: true);

      // --------------------------------------------------------- restore
      final afterDir = sub('after');
      final afterMedia = sub('after-media');
      final after = WeftDatabase.openAt(p.join(afterDir.path, 'weft.db'));
      addTearDown(after.dispose);

      final reader = await openArchiveFile(
        archive,
        'der Zug um acht nach Sylt',
      );
      // The network list was inside the ciphertext, and here it is.
      expect(reader.manifest.networks, containsAll(['whatsapp', 'sms']));

      final outcome = await importArchive(
        reader: reader,
        sink: StoreBackupSink(database: after, mediaDirectory: afterMedia),
      );
      await reader.close();

      // ----------------------------------------------------- the checks
      expect(outcome.skippedUnknownType, 0);
      expect(outcome.mediaWritten, 2, reason: 'photo and voice note');

      // Chats: every message back, still findable, still on its own network.
      expect(
        after.raw.select('SELECT COUNT(*) AS c FROM search_message').first['c'],
        401,
      );
      expect(await SearchStore(after).keywordSearch('Gleis'), isEmpty);
      expect(await SearchStore(after).keywordSearch('Sylt'), isNotEmpty);
      expect(
        after.raw
            .select(
              'SELECT DISTINCT network FROM search_message ORDER BY network',
            )
            .map((r) => r['network'])
            .toList(),
        ['sms', 'whatsapp'],
      );

      // Merges: the irreplaceable part.
      final decision = IdentityStore(after).loadDecisions().single;
      expect(decision.pair, 'h-sms|h-wa');
      expect(decision.verdict, 'same');
      expect(decision.decidedAt, DateTime.utc(2026, 5, 4, 11, 22));
      expect(
        IdentityStore(after).loadHandles().map((h) => h.unifiedContactId),
        everyElement('c-anke'),
      );

      // Media: both files, in the folders the viewer looks in, byte-identical.
      final restoredPhoto = File(
        p.join(afterMedia.path, '_photo', 'IMG_0042.jpg'),
      );
      final forwarded = File(
        p.join(afterMedia.path, '_photo-forwarded', 'IMG_0042.jpg'),
      );
      expect(restoredPhoto.existsSync(), isTrue);
      expect(forwarded.existsSync(), isTrue);
      expect(restoredPhoto.lengthSync(), 512 * 1024);
      expect(
        restoredPhoto.readAsBytesSync(),
        equals(forwarded.readAsBytesSync()),
      );
      expect(
        File(p.join(afterMedia.path, '_voice', 'note.ogg')).lengthSync(),
        96 * 1024,
      );

      // Transcripts, prefs and settings.
      expect(
        TranscriptStore(
          after,
        ).byEvent(r'$voice', '!room-h-wa:example.org')!.text,
        'Ich bin gleich da, warte am Gleis vier.',
      );
      expect(IdentityStore(after).sendNetworkFor('chat-anke'), ChatNetwork.sms);
      expect(SettingsStore(after).getString('appearance.theme_mode'), 'dark');
      // And the one that must not have travelled.
      expect(SettingsStore(after).getString('notify.push_key'), isNull);

      // Semantic search has no hole where the restored history is.
      expect(SearchStore(after).pendingEmbeddingCount, 401);

      // The staging directory did not survive the commit.
      expect(
        Directory(p.join(afterMedia.path, '.restore')).existsSync(),
        isFalse,
      );

      // ------------------------------------------- and the wrong passphrase
      await expectLater(
        openArchiveFile(archive, 'der Zug um neun nach Sylt'),
        throwsA(isA<WrongPassphraseFailure>()),
      );
    },
    // Two real Argon2id derivations at 64 MiB, plus a megabyte of file I/O.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
