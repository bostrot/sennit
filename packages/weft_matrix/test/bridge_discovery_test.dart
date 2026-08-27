import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// Which bridges the bridges screen can see.
///
/// Detection worked from rooms that *classify* as a bridge network — a room
/// with an `m.bridge` stamp, or one full of that bridge's ghosts. A bridge you
/// have not signed into yet has neither: its single room is the bot's
/// management chat, holding you, the bot and nothing else. So the bridges the
/// screen exists to get you signed into were the exact ones it never listed —
/// Discord sat on the homeserver, ready, and never appeared.
void main() {
  late sdk.Client client;
  var nextRoom = 0;

  setUp(() async {
    client = sdk.Client(
      'weft-bridge-discovery-test',
      database: await sdk.MatrixSdkDatabase.init(
        'weft-bridge-discovery-test',
        database: await openWeftSqfliteDatabase(inMemoryDatabasePath),
      ),
    );
  });

  /// A joined room holding [members], optionally stamped by a bridge.
  ///
  /// The account's own membership is left out: setting `client.userID` needs a
  /// login, and the only code that reads it skips that member anyway.
  sdk.Room roomWith(
    List<String> members, {
    Map<String, Object?>? bridge,
    String? createdBy,
  }) {
    final room = sdk.Room(id: '!room${nextRoom++}:example.org', client: client);
    if (createdBy != null) {
      room.setState(
        sdk.Event(
          type: sdk.EventTypes.RoomCreate,
          stateKey: '',
          content: const {},
          eventId: '\$create-${room.id}',
          senderId: createdBy,
          originServerTs: DateTime(2026, 8, 27, 9),
          room: room,
        ),
      );
    }
    if (bridge != null) {
      room.setState(
        sdk.Event(
          type: 'm.bridge',
          stateKey: 'bridge',
          content: bridge,
          eventId: '\$bridge-${room.id}',
          senderId: members.first,
          originServerTs: DateTime(2026, 8, 27, 9),
          room: room,
        ),
      );
    }
    for (final member in members) {
      room.setState(
        sdk.Event(
          type: sdk.EventTypes.RoomMember,
          stateKey: member,
          content: const {'membership': 'join'},
          eventId: '\$member-$member-${room.id}',
          senderId: member,
          originServerTs: DateTime(2026, 8, 27, 9),
          room: room,
        ),
      );
    }
    client.rooms.add(room);
    return room;
  }

  DetectedBridge? bridgeFor(ChatNetwork network) {
    final found = detectBridges(
      client,
    ).where((bridge) => bridge.network == network);
    return found.isEmpty ? null : found.single;
  }

  test('a bridge is found by its bot alone', () {
    // The whole of an unused bridge: one management chat, no stamp, no ghosts.
    roomWith(['@discordbot:example.org']);

    final discord = bridgeFor(ChatNetwork.discord);
    expect(
      discord,
      isNotNull,
      reason: 'a bridge waiting to be signed into is the point of the screen',
    );
    expect(discord!.botUserId, '@discordbot:example.org');
    expect(
      discord.roomCount,
      0,
      reason: 'the count means chats bridged, and the bot chat is not one',
    );
  });

  test('the management chat does not inflate a working bridge', () {
    roomWith(['@whatsappbot:example.org']);
    roomWith(['@whatsapp_4915112345678:example.org']);

    expect(bridgeFor(ChatNetwork.whatsapp)!.roomCount, 1);
  });

  test('a stamped room is counted, and names its bot', () {
    roomWith(
      ['@telegram_9876:example.org'],
      bridge: const {
        'bridgebot': '@telegrambot:example.org',
        'protocol': {'id': 'telegram'},
      },
    );

    final telegram = bridgeFor(ChatNetwork.telegram)!;
    expect(telegram.roomCount, 1);
    expect(telegram.botUserId, '@telegrambot:example.org');
  });

  test('a portal with no ghosts in it yet is still its bridge', () {
    // A freshly bridged channel holds the bot and nobody else until someone
    // speaks. It is a real chat, and the bot that created it says whose.
    roomWith(['@discordbot:example.org'], createdBy: '@discordbot:example.org');

    expect(bridgeFor(ChatNetwork.discord)!.roomCount, 1);
  });

  test('ghost rooms with no stamp still count', () {
    // mautrix-gmessages writes no `m.bridge`; its portals are known by the
    // ghosts in them.
    roomWith(['@gmessages_123:example.org']);
    expect(bridgeFor(ChatNetwork.gmessages)!.roomCount, 1);
  });

  test('a plain Matrix conversation invents no bridge', () {
    roomWith(['@anna:example.org']);
    expect(detectBridges(client), isEmpty);
  });

  test('a person is not a bridge for being named after one', () {
    // `@signal:hs` is somebody's account. Only a `bot` suffix makes it a
    // bridge, or anyone could be mistaken for the plumbing.
    roomWith(['@signal:example.org']);
    expect(bridgeFor(ChatNetwork.signal), isNull);
  });

  group('probeBridgeBots', () {
    late List<String> asked;

    setUp(() => asked = []);

    /// Probes a homeserver on which only [present] bot accounts exist.
    Future<List<DetectedBridge>> probe(
      Set<String> present, {
      Set<ChatNetwork> skip = const {},
    }) => probeBridgeBots(
      homeserver: Uri.parse('https://example.org'),
      ownUserId: '@me:example.org',
      accessToken: 'token',
      skip: skip,
      httpClient: MockClient((request) async {
        final userId = Uri.decodeFull(request.url.path).split('/profile/').last;
        asked.add(userId);
        return present.contains(userId)
            ? http.Response(jsonEncode({'displayname': 'bridge bot'}), 200)
            : http.Response(jsonEncode({'errcode': 'M_NOT_FOUND'}), 404);
      }),
    );

    test('finds a bridge no room mentions', () async {
      expect(
        (await probe({'@discordbot:example.org'})).map((b) => b.network),
        [ChatNetwork.discord],
        reason: 'a bridge you have never messaged leaves no room behind',
      );
    });

    test('names the bot, so the row can offer a sign-in', () async {
      final discord = (await probe({'@discordbot:example.org'})).single;

      expect(discord.botUserId, '@discordbot:example.org');
      expect(discord.roomCount, 0);
    });

    test('a homeserver running nothing yields nothing', () async {
      expect(await probe(const {}), isEmpty);
    });

    test('a bot on another server is not this account\'s bridge', () async {
      // The localpart is right, the server is not: bridges are local accounts.
      expect(await probe({'@discordbot:elsewhere.org'}), isEmpty);
    });

    test('does not ask again about a bridge the rooms already found', () async {
      await probe(const {}, skip: {ChatNetwork.whatsapp});

      expect(asked, isNot(contains('@whatsappbot:example.org')));
      expect(asked, contains('@discordbot:example.org'));
    });

    test('asks nothing about networks no bridge serves', () async {
      await probe(const {});

      // Matrix is the homeserver itself; SMS and email reach the account
      // through the phone and a mail account, not through a mautrix bot.
      expect(
        asked,
        isNot(
          anyElement(
            anyOf(
              contains('matrixbot'),
              contains('smsbot'),
              contains('emailbot'),
              contains('unknownbot'),
            ),
          ),
        ),
      );
    });

    test('a server that answers nothing is not an error', () async {
      final found = await probeBridgeBots(
        homeserver: Uri.parse('https://example.org'),
        ownUserId: '@me:example.org',
        httpClient: MockClient((_) async => throw const SocketException('no')),
      );
      expect(found, isEmpty);
    });
  });

  test('the busy bridges come first, the idle ones in a stable order', () {
    roomWith(['@discordbot:example.org']);
    roomWith(['@signalbot:example.org']);
    roomWith(['@whatsapp_49151:example.org']);
    roomWith(['@whatsapp_49152:example.org']);

    expect(detectBridges(client).map((bridge) => bridge.network), [
      ChatNetwork.whatsapp,
      ChatNetwork.discord,
      ChatNetwork.signal,
    ]);
  });
}
