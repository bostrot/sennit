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

  void record(ChatNetwork network, String roomId, String? bot) {
    final existing = byNetwork[network] ?? (rooms: <String>{}, bot: null);
    existing.rooms.add(roomId);
    byNetwork[network] = (rooms: existing.rooms, bot: existing.bot ?? bot);
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
    final network = networkForRoom(room);
    if (network == ChatNetwork.matrix || network == ChatNetwork.unknown) {
      continue;
    }
    String? bot;
    for (final participant in room.getParticipants()) {
      final localpart = participant.id.split(':').first;
      if (localpart.endsWith('bot') &&
          networkFromBridgeBotId(participant.id) == network) {
        bot = participant.id;
        break;
      }
    }
    record(network, room.id, bot);
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
  // here to manage.
  detected.sort((a, b) => b.roomCount.compareTo(a.roomCount));
  return detected;
}
