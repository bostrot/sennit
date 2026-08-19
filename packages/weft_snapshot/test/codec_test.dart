import 'dart:convert';

import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

import 'support/fixtures.dart';

const SnapshotCodec codec = SnapshotCodec();

/// [snapshot] encoded and read straight back.
InboxSnapshot? roundTrip(InboxSnapshot snapshot) =>
    codec.decode(codec.encode(snapshot));

/// A payload built from [fields] alone, so a test can leave a key out entirely
/// rather than nulling it — which is what a writer killed partway through, or a
/// build that did not have the key yet, actually produces.
String blob(Map<String, Object?> fields) => jsonEncode(fields);

/// The encoded form of [snapshot] as a map, for asserting on the wire contract
/// rather than on the Dart objects either side of it.
Map<String, Object?> wire(InboxSnapshot snapshot) =>
    (jsonDecode(codec.encode(snapshot)) as Map).cast<String, Object?>();

void main() {
  group('round trip', () {
    test('a full snapshot survives encode and decode unchanged', () {
      final snapshot = build([
        chat(
          id: '!room:example.org',
          title: 'Grace Hopper',
          unreadCount: 3,
          avatarUrl: 'mxc://example.org/grace',
          lastMessage: msg(body: 'on my way'),
        ),
        mergedChat(
          contactId: 'contact_17',
          unreadCount: 120,
          lastMessage: msg(body: 'and me', network: ChatNetwork.signal),
        ),
      ]);

      expect(roundTrip(snapshot), snapshot);
    });

    test('the version crosses in the payload', () {
      // Load-bearing here in a way `kStagedShareFormatVersion` is not: a widget
      // process outlives an app update, so a reader older than its writer is
      // the ordinary case rather than the impossible one.
      expect(wire(build(const []))['version'], kSnapshotFormatVersion);
      expect(roundTrip(build(const []))!.version, kSnapshotFormatVersion);
      expect(roundTrip(build(const []))!.isFutureVersion, isFalse);
    });

    test('the switched-off payload round trips as switched off', () {
      // The whole reason it is written rather than deleted: the surface has to
      // be able to say "off in Settings" instead of showing a sign-in prompt to
      // someone who is already signed in.
      final off = build(const [], policy: SnapshotPolicy.off);
      final decoded = roundTrip(off)!;

      expect(decoded.enabled, isFalse);
      expect(decoded.rows, isEmpty);
      expect(decoded, off);
    });

    test(
      'an empty enabled snapshot stays distinguishable from a disabled one',
      () {
        expect(roundTrip(build(const []))!.enabled, isTrue);
        expect(
          roundTrip(build(const [], policy: SnapshotPolicy.off))!.enabled,
          isFalse,
        );
      },
    );

    test('a local-time generatedAt comes back as the same instant, in UTC', () {
      // The writer runs on the device's clock; the reader compares against its
      // own UTC now. A round trip that shifted the instant would misjudge
      // staleness by the timezone offset.
      final local = DateTime(2026, 4, 1, 9);
      final decoded = roundTrip(build(const [], at: local))!;

      expect(decoded.generatedAt.isUtc, isTrue);
      expect(decoded.generatedAt.isAtSameMomentAs(local), isTrue);
    });

    test('a row timestamp round trips to the millisecond', () {
      final at = DateTime.utc(2026, 4, 1, 8, 45, 12, 345);
      final decoded = roundTrip(
        build([chat(lastMessage: msg(timestamp: at))]),
      )!;

      expect(decoded.rows.single.timestamp, at);
    });

    test('totalUnread survives independently of the rows it outruns', () {
      // It never counted only the visible ones, so a decode that recomputed it
      // from the rows would quietly shrink the complication's badge.
      final snapshot = build([
        for (var i = 0; i < 20; i++)
          chat(id: '!room$i:example.org', unreadCount: 2),
      ], policy: fullPolicy.copyWith(maxRows: 3));

      final decoded = roundTrip(snapshot)!;
      expect(decoded.rows, hasLength(3));
      expect(decoded.totalUnread, 40);
    });

    test('every key the platforms parse by hand is in the payload', () {
      // Swift and Kotlin read this JSON with no compiler checking the spelling,
      // so a rename here is a silent break there. This test is the contract.
      final encoded = wire(build([chat(unreadCount: 3, lastMessage: msg())]));

      expect(
        encoded.keys,
        containsAll([
          'version',
          'generatedAt',
          'enabled',
          'totalUnread',
          'palette',
          'rows',
        ]),
      );
      expect((encoded['rows']! as List).single, {
        'id': '!room:example.org',
        'title': 'Grace',
        // The `!` is left alone — it is a legal path character. The colon is
        // the one that has to be escaped, and it is the one a merged id
        // carries.
        'link': 'weft://chat/!room%3Aexample.org',
        'unread': 3,
        'unreadLabel': '3',
        'networks': ['whatsapp'],
        'merged': false,
        'preview': 'hello',
        'sender': 'Grace',
        'timestamp': now.millisecondsSinceEpoch,
      });
    });

    test('the badge label is written rather than left to each platform', () {
      // Two hand-written renderers implementing one `99+` rule is one rule too
      // many, and the one that gets it wrong is the one nobody has on a wrist.
      final row =
          (wire(build([chat(unreadCount: 120)]))['rows']! as List).single
              as Map;

      expect(row['unread'], 120);
      expect(row['unreadLabel'], '99+');
    });

    test('absent optional fields are omitted rather than written as null', () {
      // Swift's JSONSerialization turns a null into NSNull, and a hand-written
      // reader then has two cases where the contract only wants one.
      final encoded = wire(
        build([chat()], policy: const SnapshotPolicy(enabled: true)),
      );
      final row = (encoded['rows']! as List).single as Map;

      expect(row.containsKey('preview'), isFalse);
      expect(row.containsKey('sender'), isFalse);
      expect(row.containsKey('avatar'), isFalse);
      expect(row.containsKey('timestamp'), isFalse);
    });

    test(
      'the palette travels once, as ints the platforms can use directly',
      () {
        final encoded = wire(
          build([
            mergedChat(
              networks: const [ChatNetwork.whatsapp, ChatNetwork.signal],
            ),
          ]),
        );

        expect(encoded['palette'], {
          'whatsapp': ChatNetwork.whatsapp.brandColor,
          'signal': ChatNetwork.signal.brandColor,
        });
      },
    );
  });

  group('version gating', () {
    test('a payload from a future build is read, not refused', () {
      // An unread count and a chat id mean the same thing in every version this
      // format will ever have. Refusing them costs the user a working widget to
      // protect them from a field that might be spelled differently.
      final decoded = codec.decode(
        blob({
          'version': kSnapshotFormatVersion + 5,
          'generatedAt': now.millisecondsSinceEpoch,
          'enabled': true,
          'totalUnread': 7,
          'rows': [
            {'id': '!room:example.org', 'title': 'Grace', 'unread': 7},
          ],
        }),
      )!;

      expect(decoded.version, kSnapshotFormatVersion + 5);
      expect(decoded.isFutureVersion, isTrue);
      expect(decoded.rows.single.chatId, '!room:example.org');
      expect(decoded.totalUnread, 7);
    });

    test('a missing or nonsense version reads as this build', () {
      // A payload that cannot say what it is, is what this build writes — a
      // reader that flagged it as "from the future" would send every surface to
      // its degraded layout for a key that was simply absent.
      for (final value in <Object?>[null, 0, -1, '2', 1.5]) {
        final decoded = codec.decode(
          blob({
            'version': ?value,
            'generatedAt': now.millisecondsSinceEpoch,
            'rows': const [],
          }),
        )!;

        expect(decoded.version, kSnapshotFormatVersion, reason: '$value');
        expect(decoded.isFutureVersion, isFalse, reason: '$value');
      }
    });

    test('unknown top-level fields from a future build are ignored', () {
      final decoded = codec.decode(
        blob({
          'version': kSnapshotFormatVersion + 1,
          'generatedAt': now.millisecondsSinceEpoch,
          'enabled': true,
          'totalUnread': 2,
          'rows': const [],
          'accentColour': '#ff0000',
          'pinnedSection': {'rows': []},
        }),
      )!;

      expect(decoded.totalUnread, 2);
      expect(decoded.rows, isEmpty);
    });

    test('unknown row fields are ignored without taking the row with them', () {
      final decoded = codec.decode(
        blob({
          'version': kSnapshotFormatVersion + 1,
          'generatedAt': now.millisecondsSinceEpoch,
          'rows': [
            {
              'id': 'merged:contact_17',
              'title': 'Grace',
              'unread': 4,
              'typing': true,
              'draft': 'half-written reply',
            },
          ],
        }),
      )!;

      final row = decoded.rows.single;
      expect(row.chatId, 'merged:contact_17');
      expect(row.unreadCount, 4);
    });

    test('unknown fields are dropped rather than carried back out', () {
      // Unlike `StagedShare`, whose reader also writes. Nothing on this side
      // ever writes the payload back — the phone writes and the surfaces read —
      // so there is nothing for an `extras` round trip to preserve.
      final decoded = codec.decode(
        blob({
          'version': kSnapshotFormatVersion,
          'generatedAt': now.millisecondsSinceEpoch,
          'rows': const [],
          'accentColour': '#ff0000',
        }),
      )!;

      expect(codec.encode(decoded), isNot(contains('accentColour')));
    });
  });

  group('a decode that must not throw', () {
    test('nothing at all decodes to null', () {
      expect(codec.decode(null), isNull);
      expect(codec.decode(''), isNull);
      expect(codec.decode('   \n '), isNull);
    });

    test('a payload truncated mid-write decodes to null rather than throwing', () {
      // The writer is a host app the system can suspend between the first byte
      // and the last. Every prefix of a real payload has to be survivable,
      // because in production they all eventually happen.
      final full = codec.encode(
        build([
          chat(unreadCount: 3, lastMessage: msg(body: 'on my way')),
          mergedChat(unreadCount: 1, lastMessage: msg(body: 'and me')),
        ]),
      );

      for (var cut = 1; cut < full.length; cut++) {
        expect(
          () => codec.decode(full.substring(0, cut)),
          returnsNormally,
          reason: 'prefix of length $cut threw',
        );
      }
      // The last complete prefix is the whole thing; every shorter one is
      // unparseable JSON and must come back as null rather than as half a list.
      expect(codec.decode(full.substring(0, full.length - 1)), isNull);
    });

    test('garbage decodes to null', () {
      expect(codec.decode('not json at all'), isNull);
      expect(codec.decode('{'), isNull);
      expect(codec.decode(' '), isNull);
    });

    test('a JSON root that is not an object decodes to null', () {
      // A hand-written Swift encoder that wrote the rows array as the root.
      expect(codec.decode('[]'), isNull);
      expect(codec.decode('"snapshot"'), isNull);
      expect(codec.decode('42'), isNull);
      expect(codec.decode('null'), isNull);
    });

    test(
      'rows arriving as the wrong type reads as no rows, not as a crash',
      () {
        for (final rows in <Object?>[
          'none',
          42,
          {'a': 1},
          null,
        ]) {
          final decoded = codec.decode(
            blob({
              'version': kSnapshotFormatVersion,
              'generatedAt': now.millisecondsSinceEpoch,
              'rows': ?rows,
            }),
          );

          expect(decoded, isNotNull, reason: '$rows');
          expect(decoded!.rows, isEmpty, reason: '$rows');
        }
      },
    );

    test('an unusable row is skipped individually', () {
      // A row with no id cannot be tapped, and a row that renders but does
      // nothing is worse than a row that is not there. The rows around it are
      // still perfectly good.
      final decoded = codec.decode(
        blob({
          'version': kSnapshotFormatVersion,
          'generatedAt': now.millisecondsSinceEpoch,
          'rows': [
            {'id': '!a:example.org', 'title': 'A'},
            {'title': 'no id'},
            {'id': '', 'title': 'empty id'},
            'not a map',
            42,
            null,
            {'id': '!b:example.org', 'title': 'B'},
          ],
        }),
      )!;

      expect(decoded.rows.map((row) => row.chatId), [
        '!a:example.org',
        '!b:example.org',
      ]);
    });

    test('a row degrades field by field rather than refusing', () {
      final row = codec
          .decode(
            blob({
              'generatedAt': now.millisecondsSinceEpoch,
              'rows': [
                {
                  'id': 'merged:contact_17',
                  'title': 42,
                  'link': '',
                  'unread': 'lots',
                  'networks': 'whatsapp',
                  'merged': 'yes',
                  'preview': '',
                },
              ],
            }),
          )!
          .rows
          .single;

      expect(row.title, kRedactedRowTitle);
      expect(row.link, chatDeepLink('merged:contact_17'));
      expect(row.unreadCount, 0);
      expect(row.networks, isEmpty);
      expect(row.preview, isNull);
      // `merged` was unusable, so it falls back to the network count — which is
      // zero here, hence false. Explicit in the payload is the only reliable
      // answer, which is why the writer always writes it.
      expect(row.isMerged, isFalse);
    });

    test('an unrecognised network id reads as unknown rather than dropping the '
        'row', () {
      // A payload from a future build that learned a network this one has not.
      final row = codec
          .decode(
            blob({
              'generatedAt': now.millisecondsSinceEpoch,
              'rows': [
                {
                  'id': '!a:example.org',
                  'networks': ['whatsapp', 'nostr', 7],
                },
              ],
            }),
          )!
          .rows
          .single;

      expect(
        row.networks,
        containsAll([ChatNetwork.whatsapp, ChatNetwork.unknown]),
      );
    });

    test('a missing generatedAt reads as the epoch, which is maximally stale', () {
      // The right answer for a payload that cannot say when it was written: the
      // surface goes to its "open Weft on your phone" state instead of showing
      // counts it cannot vouch for.
      final decoded = codec.decode(
        blob({'version': kSnapshotFormatVersion, 'rows': const []}),
      )!;

      expect(
        decoded.generatedAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(decoded.isStaleAt(now), isTrue);
    });

    test('a generatedAt written as an ISO string is accepted', () {
      // The wire form is epoch millis, because that is what Swift and Kotlin
      // parse without a formatter. The string form stays supported because a
      // hand-written fixture reaches for it first.
      final decoded = codec.decode(
        blob({'generatedAt': '2026-04-01T09:00:00Z', 'rows': const []}),
      )!;

      expect(decoded.generatedAt.isAtSameMomentAs(now), isTrue);
    });

    test('a missing enabled reads as true', () {
      // The switched-off payload is the one that states it. Defaulting the
      // other way would make every malformed payload look like a privacy
      // setting the user never touched.
      final decoded = codec.decode(
        blob({'generatedAt': now.millisecondsSinceEpoch, 'rows': const []}),
      )!;

      expect(decoded.enabled, isTrue);
    });

    test('a missing totalUnread falls back to the visible rows, not to zero', () {
      // "0 unread" beside rows carrying unread counts is wrong in the way a
      // user reads as their messages having been marked read behind their back.
      final decoded = codec.decode(
        blob({
          'generatedAt': now.millisecondsSinceEpoch,
          'rows': [
            {'id': '!a:example.org', 'unread': 3},
            {'id': '!b:example.org', 'unread': 4},
          ],
        }),
      )!;

      expect(decoded.totalUnread, 7);
    });

    test('a negative or non-integer totalUnread takes the same fallback', () {
      for (final value in <Object>[-1, 'many', 2.5]) {
        final decoded = codec.decode(
          blob({
            'generatedAt': now.millisecondsSinceEpoch,
            'totalUnread': value,
            'rows': [
              {'id': '!a:example.org', 'unread': 3},
            ],
          }),
        )!;

        expect(decoded.totalUnread, 3, reason: '$value');
      }
    });

    test('an explicit zero totalUnread is honoured', () {
      // Zero is a real answer — every conversation read — and must not be
      // mistaken for the missing key it superficially resembles.
      final decoded = codec.decode(
        blob({
          'generatedAt': now.millisecondsSinceEpoch,
          'totalUnread': 0,
          'rows': [
            {'id': '!a:example.org', 'unread': 0},
          ],
        }),
      )!;

      expect(decoded.totalUnread, 0);
    });
  });

  group('the size cap', () {
    test('the default cap is stated in bytes, not characters', () {
      expect(kMaxSnapshotBytes, 64 * 1024);
      expect(const SnapshotCodec().maxBytes, kMaxSnapshotBytes);
    });

    test('a full-cap inbox encodes well under the ceiling', () {
      // The sizing claim in `kMaxSnapshotBytes`' doc comment, checked rather
      // than asserted: sixteen rows of an 80-grapheme preview, a title, a link
      // and a timestamp.
      final encoded = codec.encode(
        build([
          for (var i = 0; i < kDefaultSnapshotRowCap; i++)
            chat(
              id: '!averylongroomidforgoodmeasure$i:example.org',
              title: 'A conversation with a fairly long title $i',
              unreadCount: 12,
              avatarUrl: 'mxc://example.org/averylongmediaidhere$i',
              lastMessage: msg(body: 'w' * 200),
            ),
        ]),
      );

      expect(utf8.encode(encoded).length, lessThan(kMaxSnapshotBytes));
    });

    test('encode never emits a payload above the cap', () {
      final small = const SnapshotCodec(maxBytes: 600);
      final encoded = small.encode(
        build([
          for (var i = 0; i < kDefaultSnapshotRowCap; i++)
            chat(
              id: '!room$i:example.org',
              title: 'Conversation number $i',
              unreadCount: i,
              lastMessage: msg(body: 'a message of some length $i'),
            ),
        ]),
      );

      expect(utf8.encode(encoded).length, lessThanOrEqualTo(600));
    });

    test(
      'an oversize snapshot loses rows from the end, not its whole self',
      () {
        // Half a list is a widget. A payload the extension refuses is a blank
        // rectangle the user eventually deletes.
        final small = const SnapshotCodec(maxBytes: 600);
        final snapshot = build([
          for (var i = 0; i < kDefaultSnapshotRowCap; i++)
            chat(
              id: '!room$i:example.org',
              title: 'Conversation number $i',
              unreadCount: 2,
              lastMessage: msg(body: 'a message of some length $i'),
            ),
        ]);

        final decoded = small.decode(small.encode(snapshot))!;
        expect(decoded.rows, isNotEmpty);
        expect(decoded.rows.length, lessThan(snapshot.rows.length));
        expect(decoded.rows.first.chatId, '!room0:example.org');
      },
    );

    test('totalUnread is not recomputed as rows are dropped', () {
      // It never counted only the visible ones — same reason the row cap does
      // not shrink it.
      final small = const SnapshotCodec(maxBytes: 600);
      final snapshot = build([
        for (var i = 0; i < kDefaultSnapshotRowCap; i++)
          chat(
            id: '!room$i:example.org',
            title: 'Conversation number $i',
            unreadCount: 2,
            lastMessage: msg(body: 'a message of some length $i'),
          ),
      ]);

      final decoded = small.decode(small.encode(snapshot))!;
      expect(decoded.totalUnread, 32);
    });

    test('a cap too small for even an empty payload terminates', () {
      // The shedding loop stops at zero rows rather than spinning. The result
      // is over the cap and the reader will refuse it, which is the correct
      // failure: a surface with no snapshot has a state, and a hung writer on
      // the UI isolate does not.
      final tiny = const SnapshotCodec(maxBytes: 1);
      final encoded = tiny.encode(build([chat(), mergedChat()]));

      expect(jsonDecode(encoded), isA<Map<String, Object?>>());
      expect((jsonDecode(encoded) as Map)['rows'], isEmpty);
      expect(tiny.decode(encoded), isNull);
    });

    test('decode refuses a payload above its own cap', () {
      // Enforced on both sides: the writer is the process with memory to spare
      // and the reader is the one that gets killed. A reader with a smaller cap
      // than the writer is exactly what an app update produces.
      final payload = codec.encode(
        build([
          for (var i = 0; i < kDefaultSnapshotRowCap; i++)
            chat(
              id: '!room$i:example.org',
              lastMessage: msg(body: 'x' * 60),
            ),
        ]),
      );

      expect(codec.decode(payload), isNotNull);
      expect(const SnapshotCodec(maxBytes: 200).decode(payload), isNull);
    });

    test('the cap counts UTF-8 bytes, not UTF-16 code units', () {
      // A preview of emoji is four bytes per cluster and two code units. A cap
      // checked in code units would let a payload through at twice the size the
      // extension budgeted for.
      final payload = jsonEncode({
        'version': kSnapshotFormatVersion,
        'generatedAt': now.millisecondsSinceEpoch,
        'rows': [
          {'id': '!a:example.org', 'preview': '🌅' * 40},
        ],
      });

      // The discriminating case: this payload is under 200 UTF-16 code units
      // and over 200 UTF-8 bytes, so a codec capped at 200 must refuse it. A
      // cap checked in code units would sail past the cheap length guard and
      // hand the extension a payload half again as large as it budgeted for.
      expect(payload.length, lessThan(200));
      expect(utf8.encode(payload).length, greaterThan(200));
      expect(const SnapshotCodec(maxBytes: 200).decode(payload), isNull);
      expect(const SnapshotCodec(maxBytes: 1024).decode(payload), isNotNull);
    });

    test('an absurdly long payload is rejected without being decoded', () {
      // The cheap length check first: a UTF-16 code unit is never worth less
      // than one UTF-8 byte, so a string longer than the cap is over it
      // whatever it contains.
      expect(codec.decode('a' * (kMaxSnapshotBytes + 1)), isNull);
    });
  });
}
