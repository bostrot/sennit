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

  for (final room in client.rooms) {
    for (final type in bridgeStateEventTypes) {
      final states = room.states[type];
      if (states == null) continue;

      for (final event in states.values) {
        final network = networkFromBridgeStateContent(event.content);
        if (network == ChatNetwork.unknown) continue;

        final existing = byNetwork[network] ?? (rooms: <String>{}, bot: null);
        existing.rooms.add(room.id);
        final bot = event.content['bridgebot'];
        byNetwork[network] = (
          rooms: existing.rooms,
          bot: existing.bot ?? (bot is String ? bot : null),
        );
      }
    }
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
