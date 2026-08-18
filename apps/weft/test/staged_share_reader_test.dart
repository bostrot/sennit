import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/intents.dart';
import 'package:weft/services/share/staged_share_reader.dart';
import 'package:weft_share/weft_share.dart';

import 'support/share_fixtures.dart';

/// A container that never sees a filesystem.
///
/// The App Group container is a directory two processes with different bundle
/// ids write into, and there is no version of `flutter test` in which that
/// exists. What *is* testable here is every decision the drain makes about what
/// it finds there: what it delivers, what it deletes, what it refuses to do
/// twice, and in what order. So the fake is a map of blobs and a log of calls.
class _FakeContainer implements StagedShareGateway {
  /// Container id → the blob's JSON, or null for a file that could not be read.
  final Map<String, String?> blobs = {};

  /// Ids passed to [removeStagedShare], in order.
  final List<String> removed = [];

  /// Ids passed to [ingestStagedShare], in order.
  final List<String> ingested = [];

  /// Every target list written, newest last.
  final List<String> targetWrites = [];

  /// Relative paths this container refuses to move — a file that vanished, or
  /// one whose blob named a path outside the container.
  final Set<String> unmovable = {};

  /// Ids whose deletion fails: a container the app has momentarily lost its
  /// entitlement to, or a file another process still holds open.
  final Set<String> undeletable = {};

  /// The TTL the reader passed down, which the platform sweep needs.
  Duration? sweptWith;

  /// Runs between the read and the ingest of the first share, which is the
  /// window a second drain would have to squeeze into.
  Future<void>? interleave;

  /// The container has no App Group at all: an unsigned build, or a profile
  /// that predates the capability.
  bool unavailable = false;

  @override
  Future<List<StagedShareBlob>> readStagedShares({
    required Duration ttl,
  }) async {
    sweptWith = ttl;
    if (unavailable) return const [];
    return [
      for (final entry in blobs.entries)
        StagedShareBlob(id: entry.key, json: entry.value),
    ];
  }

  @override
  Future<Map<String, String>> ingestStagedShare(
    String id,
    List<StagedFile> files,
  ) async {
    ingested.add(id);
    // The real one deletes the blob before it moves a byte, which is what makes
    // a second reader unable to find the share at all.
    blobs.remove(id);
    final pending = interleave;
    if (pending != null) {
      interleave = null;
      await pending;
    }
    return {
      for (final file in files)
        if (!unmovable.contains(file.relativePath))
          file.relativePath: '/cache/weft-share/$id/${file.name}',
    };
  }

  @override
  Future<void> removeStagedShare(String id) async {
    removed.add(id);
    if (undeletable.contains(id)) {
      throw PlatformException(code: 'remove_failed', message: id);
    }
    blobs.remove(id);
  }

  @override
  Future<bool> writeShareTargets(String json) async {
    if (unavailable) return false;
    targetWrites.add(json);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = ShareStagingCodec();

  /// A blob as `ShareViewController.swift` writes one.
  ///
  /// Built through the codec rather than by hand, because the codec's key names
  /// *are* the cross-language contract and a hand-written literal here would
  /// keep passing after a rename that breaks Swift.
  String blob(
    String id, {
    String? text,
    List<StagedFile> files = const [],
    String? targetChatId,
    DateTime? capturedAt,
  }) => codec.encode(
    StagedShare(
      id: id,
      capturedAt: capturedAt ?? shareAgo(const Duration(minutes: 5)),
      text: text,
      files: files,
      targetChatId: targetChatId,
    ),
  );

  StagedFile file(
    String name, {
    String? path,
    String mimeType = 'image/jpeg',
    int sizeBytes = 96000,
  }) => StagedFile(
    relativePath: path ?? 'share/staged/abc/0-$name',
    name: name,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
  );

  /// A reader whose clock is [shareNow], with the payloads it delivered.
  ({StagedShareReader reader, List<SharedPayload> delivered}) readerOver(
    StagedShareGateway container, {
    Duration ttl = kStagedShareTtl,
  }) {
    final delivered = <SharedPayload>[];
    final reader = StagedShareReader(gateway: container, ttl: ttl)
      ..onShare = delivered.add;
    return (reader: reader, delivered: delivered);
  }

  /// Drains with the suite's pinned clock, so `capturedAt` ages deterministically.
  Future<void> drain(StagedShareReader reader) =>
      withClock(Clock.fixed(shareNow), reader.drain);

  group('draining into a share', () {
    test(
      'a staged share becomes the payload an Android intent would',
      () async {
        final container = _FakeContainer()
          ..blobs['abc'] = blob(
            'abc',
            text: 'look at this',
            files: [file('holiday.jpg')],
            targetChatId: '!design:example.org',
          );
        final harness = readerOver(container);

        await drain(harness.reader);

        final payload = harness.delivered.single;
        expect(payload.text, 'look at this');
        expect(payload.targetChatId, '!design:example.org');
        expect(payload.uris, ['file:///cache/weft-share/abc/holiday.jpg']);
        expect(
          payload.mimeType,
          'image/jpeg',
          reason: 'a single-type batch passes its type on as the fallback hint',
        );
      },
    );

    test('the ingested path keeps the user'
        's filename, not the container'
        's', () async {
      // The extension prefixes every file with its index so a Photos
      // multi-select of two `IMG_0001.HEIC` cannot overwrite itself. That prefix
      // is a container detail; `AttachmentSource.basename` becomes the Matrix
      // event's body, and `0-IMG_0001.HEIC` is not a filename anybody chose.
      final container = _FakeContainer()
        ..blobs['abc'] = blob(
          'abc',
          files: [
            file('IMG_0001.HEIC', path: 'share/staged/abc/0-IMG_0001.HEIC'),
          ],
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.uris.single, endsWith('/IMG_0001.HEIC'));
    });

    test('a mixed batch declares */* rather than one file'
        's type', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = blob(
          'abc',
          files: [
            file('holiday.jpg', path: 'share/staged/abc/0-holiday.jpg'),
            file(
              'notes.pdf',
              path: 'share/staged/abc/1-notes.pdf',
              mimeType: 'application/pdf',
            ),
          ],
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.mimeType, '*/*');
      expect(harness.delivered.single.uris, hasLength(2));
    });

    test('the extension'
        's octet-stream guess is not passed off as a type', () async {
      // Below iOS 14 the extension has no `UTType` and writes
      // `application/octet-stream` for everything. Handing that on as the
      // batch's declared type would tell `sniffMimeType` a lie it has no reason
      // to doubt; the filename extension is the better hint and it is already on
      // the path.
      final container = _FakeContainer()
        ..blobs['abc'] = blob(
          'abc',
          files: [file('holiday.jpg', mimeType: kFallbackStagedMimeType)],
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.mimeType, kFallbackStagedMimeType);
    });

    test('a text-only share needs no files at all', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = blob('abc', text: 'https://example.org/article');
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.text, 'https://example.org/article');
      expect(harness.delivered.single.uris, isEmpty);
      expect(harness.delivered.single.mimeType, isNull);
    });

    test('several shares arrive oldest capture first', () async {
      // A container holding three holds them in the order they were made, and
      // that is the order the user will be asked about them in.
      final container = _FakeContainer()
        ..blobs['newest'] = blob(
          'newest',
          text: 'third',
          capturedAt: shareAgo(const Duration(minutes: 1)),
        )
        ..blobs['oldest'] = blob(
          'oldest',
          text: 'first',
          capturedAt: shareAgo(const Duration(hours: 3)),
        )
        ..blobs['middle'] = blob(
          'middle',
          text: 'second',
          capturedAt: shareAgo(const Duration(hours: 1)),
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.map((p) => p.text), [
        'first',
        'second',
        'third',
      ]);
    });

    test('a share with nothing left after ingestion opens no sheet', () async {
      // Every file failed to move and there was no text beside them. The blob is
      // already gone; an empty sheet on top of whatever the user was doing adds
      // nothing but a dismissal.
      final container = _FakeContainer()
        ..blobs['abc'] = blob('abc', files: [file('holiday.jpg')])
        ..unmovable.add('share/staged/abc/0-holiday.jpg');
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered, isEmpty);
      expect(container.ingested, ['abc']);
      expect(container.blobs, isEmpty);
    });

    test('one lost attachment is not a lost share', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = blob(
          'abc',
          text: 'two photos',
          files: [
            file('one.jpg', path: 'share/staged/abc/0-one.jpg'),
            file('two.jpg', path: 'share/staged/abc/1-two.jpg'),
          ],
        )
        ..unmovable.add('share/staged/abc/1-two.jpg');
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.uris, hasLength(1));
      expect(harness.delivered.single.text, 'two photos');
    });

    test('an unwired reader still clears the container', () async {
      // The drain runs before the app has anywhere to put a share only if
      // something is misordered — but a share left behind because of it would be
      // re-offered on every resume for a day.
      final container = _FakeContainer()
        ..blobs['abc'] = blob('abc', text: 'hi');
      final reader = StagedShareReader(gateway: container);

      await drain(reader);

      expect(container.blobs, isEmpty);
    });
  });

  group('idempotency', () {
    test('a second drain finds nothing to deliver', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = blob('abc', text: 'hello');
      final harness = readerOver(container);

      await drain(harness.reader);
      await drain(harness.reader);

      expect(harness.delivered, hasLength(1));
      expect(container.ingested, ['abc']);
    });

    test(
      'a drain that starts mid-ingest does not deliver the same share',
      () async {
        // The resume racing the launch. The blob is deleted before the files move,
        // so the second reader cannot see it — and the id is recorded before the
        // first `await`, so it could not act on it even if the platform were
        // slower than that.
        final container = _FakeContainer()
          ..blobs['abc'] = blob('abc', text: 'hello');
        final harness = readerOver(container);
        final second = Completer<void>();
        container.interleave = second.future;

        final first = drain(harness.reader);
        // Runs while the first drain is inside `ingestStagedShare`.
        await drain(harness.reader);
        second.complete();
        await first;

        expect(harness.delivered, hasLength(1));
        expect(container.ingested, ['abc']);
      },
    );

    test('an overlapping drain is dropped, not queued', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = blob('abc', text: 'hello');
      final harness = readerOver(container);
      final gate = Completer<void>();
      container.interleave = gate.future;

      final first = drain(harness.reader);
      expect(harness.reader.isDraining, isTrue);
      await drain(harness.reader);
      gate.complete();
      await first;

      expect(harness.delivered, hasLength(1));
    });

    test(
      'a blob that reappears under a handled id is dropped, not resent',
      () async {
        // Belt and braces: the platform deletes the blob, so this needs the
        // platform to have failed. The share was already offered once, and
        // offering it again is the thing this run knows not to do.
        final container = _FakeContainer()
          ..blobs['abc'] = blob('abc', text: 'hello');
        final harness = readerOver(container);

        await drain(harness.reader);
        container.blobs['abc'] = blob('abc', text: 'hello');
        await drain(harness.reader);

        expect(harness.delivered, hasLength(1));
        expect(container.removed, ['abc']);
      },
    );
  });

  group('expiry', () {
    test('a share older than a day is deleted unopened', () async {
      // Sharing a photo at 11pm and being shown a compose sheet for it four days
      // later, on top of something else entirely, is worse than losing it.
      final container = _FakeContainer()
        ..blobs['stale'] = blob(
          'stale',
          text: 'from last week',
          capturedAt: shareAgo(const Duration(days: 7)),
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered, isEmpty);
      expect(container.removed, ['stale']);
      expect(container.ingested, isEmpty);
    });

    test('a share just inside the day still opens', () async {
      final container = _FakeContainer()
        ..blobs['fresh'] = blob(
          'fresh',
          text: 'last night',
          capturedAt: shareAgo(const Duration(hours: 23, minutes: 59)),
        );
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered, hasLength(1));
    });

    test('the expiry the reader applies is the one it asks the platform to '
        'sweep with', () async {
      // Two sweeps, one number. The platform's collects orphaned bytes — an
      // extension killed after copying files and before writing the blob — and
      // only the reader can judge `capturedAt`. A drift between them is a share
      // whose files are gone and whose blob is not, or the reverse.
      final container = _FakeContainer()
        ..blobs['stale'] = blob(
          'stale',
          text: 'old',
          capturedAt: shareAgo(const Duration(minutes: 90)),
        );
      final harness = readerOver(container, ttl: const Duration(hours: 1));

      await drain(harness.reader);

      expect(container.sweptWith, const Duration(hours: 1));
      expect(harness.delivered, isEmpty);
      expect(container.removed, ['stale']);
    });
  });

  group('corrupt blobs', () {
    test('every truncation of a valid blob is dropped and deleted', () async {
      // The property `ShareStagingCodec` is tested on in its own package,
      // asserted here as the behaviour the *drain* has to show for it: nothing
      // delivered, nothing left behind, nothing thrown on a launch path.
      final valid = blob('abc', text: 'hello', files: [file('holiday.jpg')]);

      for (var length = 0; length < valid.length; length++) {
        final container = _FakeContainer()
          ..blobs['abc'] = valid.substring(0, length);
        final harness = readerOver(container);

        await drain(harness.reader);

        expect(harness.delivered, isEmpty, reason: 'prefix of length $length');
        expect(container.removed, ['abc'], reason: 'prefix of length $length');
      }
    });

    test('a wrong-typed field is dropped rather than thrown', () async {
      final container = _FakeContainer()
        ..blobs['abc'] = jsonEncode({
          'version': 1,
          'id': 'abc',
          'capturedAt': shareNow.toIso8601String(),
          'text': 'hello',
          // A hand-written Swift encoder with no compiler checking these names.
          'files': 'oops',
        });
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.text, 'hello');
      expect(harness.delivered.single.uris, isEmpty);
    });

    test('a file the platform could not read is deleted', () async {
      // A null blob is the platform saying so: unreadable, or too large to be a
      // staged share at all.
      final container = _FakeContainer()..blobs['abc'] = null;
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered, isEmpty);
      expect(container.removed, ['abc']);
    });

    test('a corrupt blob does not stop the share beside it', () async {
      final container = _FakeContainer()
        ..blobs['broken'] = '{"id": "broken", "capt'
        ..blobs['good'] = blob('good', text: 'hello');
      final harness = readerOver(container);

      await drain(harness.reader);

      expect(harness.delivered.single.text, 'hello');
      expect(container.removed, ['broken']);
    });

    test('a gateway that throws does not take the launch with it', () async {
      final harness = readerOver(_ThrowingContainer());

      await expectLater(drain(harness.reader), completes);
      expect(harness.delivered, isEmpty);
    });

    test('a blob that will not delete does not abandon the rest', () async {
      // The removal is the one call in the drain with nothing riding on its
      // success: a blob that stays is a blob re-read on the next resume, which
      // is a wasted read. Letting it out of `_remove` would instead cost the
      // shares queued behind it — a corrupt capture the user has forgotten
      // about silently eating the photo they shared a second ago.
      final container = _FakeContainer()
        ..blobs['stuck'] = '{"id": "stuck", "capt'
        ..blobs['good'] = blob('good', text: 'hello')
        ..undeletable.add('stuck');
      final harness = readerOver(container);

      await expectLater(drain(harness.reader), completes);

      expect(harness.delivered.single.text, 'hello');
      expect(container.removed, contains('stuck'));
      expect(
        container.blobs.keys,
        ['stuck'],
        reason:
            'the good share was ingested; the stuck one is still there to '
            'be tried again',
      );
    });

    test('a blob that will not delete is retried, not delivered', () async {
      // The other half of the same choice. `_handled` records the id before the
      // ingest, but this share was never decodable and so never reached it —
      // the next drain has to be free to try the delete again without the blob
      // becoming a share on the way past.
      final container = _FakeContainer()
        ..blobs['stuck'] = '{"id": "stuck", "capt'
        ..undeletable.add('stuck');
      final harness = readerOver(container);

      await drain(harness.reader);
      await drain(harness.reader);

      expect(harness.delivered, isEmpty);
      expect(container.removed, ['stuck', 'stuck']);
    });
  });

  group('the target list the extension picker reads', () {
    /// One `ShareTargetSlot.toJson()` with the resolved `iconPath` added, which
    /// is exactly what `ShareShortcutService` hands a publisher.
    Map<String, Object?> slotMap(String chatId, {String? iconPath}) => {
      ...ShareTargetSlot.forChat(
        shareChat(id: chatId, title: 'Grace Hopper'),
        rank: 0,
      ).toJson(),
      'iconPath': iconPath,
    };

    test('a published slot map survives the round trip to the picker', () async {
      // `ShareShortcutService` hands a publisher maps, not slots, so the iOS
      // publisher reads them back into slots and re-encodes through the codec
      // rather than writing them out as they came. This is that round trip: what
      // `ShareTarget.decodeAll` in Swift reads has to be what the ranker decided.
      final container = _FakeContainer();
      await container.writeShareTargets(
        codec.encodeTargets([
          ?ShareTargetSlot.fromJson(slotMap('!design:example.org')),
        ]),
      );

      final decoded = codec.decodeTargets(container.targetWrites.single);
      expect(decoded.single.chatId, '!design:example.org');
      expect(decoded.single.longLabel, 'Grace Hopper');
      expect(decoded.single.link, 'weft://chat/!design%3Aexample.org');
    });

    test('iconPath is dropped on the way through', () async {
      // It points into the app's own container, which the extension is not
      // entitled to read — the picker draws initials for exactly that reason.
      final round = codec.decodeTargets(
        codec.encodeTargets([
          ?ShareTargetSlot.fromJson(
            slotMap('!design:example.org', iconPath: '/cache/grace.png'),
          ),
        ]),
      );

      expect(round.single.chatId, '!design:example.org');
      expect(
        jsonDecode(codec.encodeTargets(round)),
        isA<Map<String, Object?>>().having(
          (json) => (json['targets']! as List).single,
          'the written slot',
          isNot(contains('iconPath')),
        ),
      );
    });
  });

  group('over the method channel', () {
    const channel = MethodChannel('weft-test/share');
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? answer;

    setUp(() {
      calls.clear();
      answer = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return answer?.call(call);
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    WeftStagedShares shares() => WeftStagedShares(channel: channel);

    test('reading asks for the sweep TTL in seconds', () async {
      answer = (_) => [
        {'id': 'abc', 'blob': '{"id":"abc"}'},
        {'id': 'broken', 'blob': null},
        // Not a blob at all — the platform is Swift and nothing checks it.
        'nonsense',
      ];

      final blobs = await shares().readStagedShares(ttl: kStagedShareTtl);

      expect(calls.single.method, 'readStagedShares');
      expect((calls.single.arguments as Map)['ttlSeconds'], 86400);
      expect(blobs.map((b) => b.id), ['abc', 'broken']);
      expect(blobs.last.json, isNull);
    });

    test('ingestion sends the path and the name, and nothing else', () async {
      // The path is how the platform finds the file; the name is what it is
      // called once it is somewhere the app owns. Sending the whole
      // `StagedFile` would send a size and a mime type the platform has no use
      // for and no way to check.
      answer = (_) => {
        'share/staged/abc/0-a.jpg': '/cache/weft-share/abc/a.jpg',
      };

      final moved = await shares().ingestStagedShare('abc', [
        const StagedFile(
          relativePath: 'share/staged/abc/0-a.jpg',
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 10,
        ),
      ]);

      expect(calls.single.method, 'ingestStagedShare');
      final arguments = calls.single.arguments as Map;
      expect(arguments['id'], 'abc');
      expect(arguments['files'], [
        {'path': 'share/staged/abc/0-a.jpg', 'name': 'a.jpg'},
      ]);
      expect(moved, {
        'share/staged/abc/0-a.jpg': '/cache/weft-share/abc/a.jpg',
      });
    });

    test('publishing writes the encoded target list', () async {
      answer = (_) => true;

      final count = await shares().publishShareTargets([
        ShareTargetSlot.forChat(shareChat(id: 'chat_0')).toJson(),
      ]);

      expect(count, 1);
      expect(calls.single.method, 'writeShareTargets');
      final json = (calls.single.arguments as Map)['json'] as String;
      expect(codec.decodeTargets(json).single.chatId, 'chat_0');
    });

    test('clearing writes an empty list rather than deleting the file', () async {
      // The extension reads a missing file and an empty list as the same thing,
      // and writing is the operation that is atomic.
      answer = (_) => true;

      await shares().clearShareTargets();

      final json = (calls.single.arguments as Map)['json'] as String;
      expect(codec.decodeTargets(json), isEmpty);
    });

    test(
      'a container that refuses publishes nothing and does not throw',
      () async {
        answer = (_) => false;
        expect(
          await shares().publishShareTargets([
            ShareTargetSlot.forChat(shareChat(id: 'chat_0')).toJson(),
          ]),
          0,
          reason: 'read by the caller as a refusal to retry, not as a cap',
        );
      },
    );

    test('a platform with no container at all is quiet', () async {
      // Every platform except iOS, and an iOS build signed without the App
      // Group entitlement. The drain is called unconditionally from main.dart
      // and this is why it can be.
      answer = (_) => throw MissingPluginException();
      expect(await shares().readStagedShares(ttl: kStagedShareTtl), isEmpty);
      expect(await shares().ingestStagedShare('abc', const []), isEmpty);
      await shares().removeStagedShare('abc');
      expect(await shares().writeShareTargets('{}'), isFalse);

      answer = (_) => throw PlatformException(code: 'no_container');
      expect(await shares().readStagedShares(ttl: kStagedShareTtl), isEmpty);
      expect(await shares().writeShareTargets('{}'), isFalse);
    });
  });
}

/// A container behind a channel that is failing, rather than absent.
class _ThrowingContainer implements StagedShareGateway {
  @override
  Future<List<StagedShareBlob>> readStagedShares({
    required Duration ttl,
  }) async {
    throw StateError('the container went away mid-drain');
  }

  @override
  Future<Map<String, String>> ingestStagedShare(
    String id,
    List<StagedFile> files,
  ) async => const {};

  @override
  Future<void> removeStagedShare(String id) async {}

  @override
  Future<bool> writeShareTargets(String json) async => false;
}
