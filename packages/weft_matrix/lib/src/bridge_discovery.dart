import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_domain/weft_domain.dart';

import 'mapping.dart';

/// A bridge found by looking at the rooms the account is already in.
class DetectedBridge {
  const DetectedBridge({
    required this.network,
    this.botUserId,
    this.roomCount = 0,
  });

  final ChatNetwork network;

  /// The bridge bot, when a state event named one.
  final String? botUserId;

  /// How many joined rooms this bridge is serving — evidence it is real and
  /// active, shown so the user can tell a live bridge from a leftover.
  final int roomCount;
}

/// Networks that reach the account some other way than through a mautrix bot,
/// and so have no bot account to look for.
const _unbridgeable = {
  ChatNetwork.matrix,
  ChatNetwork.sms,
  ChatNetwork.email,
  ChatNetwork.unknown,
};

/// Bridges running on the homeserver that no joined room reveals.
///
/// [detectBridges] can only see a bridge you already share a room with, and a
/// bridge you have installed but never spoken to shares none: no portals, and
/// no management chat either, since mautrix creates that only when you first
/// message the bot. It leaves no trace in the room list whatsoever — which is
/// the state *every* bridge is in at the moment you go looking for it in this
/// screen.
///
/// What it does have is a bot account, named by convention after the protocol.
/// Asking the homeserver whether that account exists is one small profile
/// lookup, and an account that answers is a bridge. Anything [detectBridges]
/// already found belongs in [skip]; the rest are asked for together.
///
/// Plain HTTP rather than the SDK's `getUserProfile`, which caches every answer
/// for a day in the client database: these are guesses, most of them wrong, and
/// a wrong guess should cost nothing and leave nothing behind.
Future<List<DetectedBridge>> probeBridgeBots({
  required Uri homeserver,
  required String ownUserId,
  required http.Client httpClient,
  String? accessToken,
  Set<ChatNetwork> skip = const {},
}) async {
  final server = ownUserId.split(':').last;
  if (server.isEmpty || server == ownUserId) return const [];

  final candidates = ChatNetwork.values
      .where((network) => !_unbridgeable.contains(network))
      .where((network) => !skip.contains(network));

  final found = await Future.wait(
    candidates.map((network) async {
      final botUserId = '@${network.id}bot:$server';
      try {
        final response = await httpClient
            .get(
              homeserver.resolve(
                '/_matrix/client/v3/profile/${Uri.encodeComponent(botUserId)}',
              ),
              headers: {
                if (accessToken != null) 'authorization': 'Bearer $accessToken',
              },
            )
            // Short: this is a background embellishment of a list the screen
            // has already drawn from the rooms.
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) return null;
        if (jsonDecode(response.body) is! Map) return null;
        return DetectedBridge(network: network, botUserId: botUserId);
      } on Object {
        // No such account, an unparsable answer, or a server that will not
        // answer for strangers. Either way there is nothing to show, and
        // nothing worth saying.
        return null;
      }
    }),
  );

  return found.nonNulls.toList();
}

/// Scans joined rooms for `m.bridge` / `uk.half-shot.bridge` state events and
/// groups them per network.
///
/// This is how "your server already has bridges" is discovered without any
/// provisioning API: every mautrix bridge stamps the rooms it manages. What
/// state events cannot provide is the provisioning URL — bridges do not
/// advertise it — so detection tells the user *what exists* and the URL is
/// the one thing left to type.
List<DetectedBridge> detectBridges(sdk.Client client) {
  final byNetwork = <ChatNetwork, ({Set<String> rooms, String? bot})>{};

  /// Notes that [network] is bridged here, without claiming a chat for it.
  void note(ChatNetwork network, String? bot) {
    final existing = byNetwork[network] ?? (rooms: <String>{}, bot: null);
    byNetwork[network] = (rooms: existing.rooms, bot: existing.bot ?? bot);
  }

  void record(ChatNetwork network, String roomId, String? bot) {
    note(network, bot);
    byNetwork[network]!.rooms.add(roomId);
  }

  for (final room in client.rooms) {
    var stamped = false;
    for (final type in bridgeStateEventTypes) {
      final states = room.states[type];
      if (states == null) continue;

      for (final event in states.values) {
        final network = networkFromBridgeStateContent(event.content);
        if (network == ChatNetwork.unknown) continue;

        stamped = true;
        final bot = event.content['bridgebot'];
        record(network, room.id, bot is String ? bot : null);
      }
    }

    if (stamped) continue;

    // No `m.bridge` state — not every bridge writes it (mautrix-gmessages
    // among them), and a bridge whose rooms are all unmistakably its own
    // ghosts must not be invisible in the bridges screen for the missing
    // stamp. The ghost-localpart heuristic that already classifies these
    // rooms for the inbox classifies them here too, and the bot — whose
    // localpart names the network with a `bot` suffix — is picked out of the
    // membership when it is present.
    final bot = bridgeBotIn(room);
    final network = networkForRoom(room);
    if (network == ChatNetwork.matrix || network == ChatNetwork.unknown) {
      // The room is nobody's portal — but a bridge bot in it still proves the
      // bridge exists on this account, and this is the shape of the one room a
      // bridge you have *not* signed into has: its management chat, with no
      // stamp, no ghosts and nothing else to go on. Discovering only bridges
      // that already carry chats hid exactly the bridges the screen is for.
      // Noted without a room, so the count keeps meaning "chats bridged".
      if (bot != null) note(bot.network, bot.userId);
      continue;
    }
    record(network, room.id, bot?.network == network ? bot!.userId : null);
  }

  final detected = byNetwork.entries
      .map(
        (entry) => DetectedBridge(
          network: entry.key,
          botUserId: entry.value.bot,
          roomCount: entry.value.rooms.length,
        ),
      )
      .toList();
  // Busiest first: the bridge carrying the user's chats is the one they came
  // here to manage. The ones carrying nothing yet fall to the bottom in a
  // stable order rather than whatever order the rooms happened to sync in.
  detected.sort((a, b) {
    final byRooms = b.roomCount.compareTo(a.roomCount);
    return byRooms != 0 ? byRooms : a.network.label.compareTo(b.network.label);
  });
  return detected;
}
