import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../../features/bridges/bridges_screen.dart';

/// One bridge to sign out of before the account goes, and the network it
/// serves, for the sentence that says which one would not answer.
typedef BridgeSignOutTarget = ({String network, BridgeLoginBackend backend});

/// Deleting the account, in the order that leaves nothing running behind it.
///
/// Bridges first. A bridge keeps its remote session — the WhatsApp pairing,
/// the Signal device, the Telegram login — on the server, under the Matrix
/// account it relays for, and deactivating that account does not tell it to
/// stop: it would go on receiving someone's messages for a user who no longer
/// exists. Signing out through the bridge is what ends those sessions.
///
/// Then the account, which is the step that cannot be undone. Then this
/// device, which is the step that has no reason to wait: once the account is
/// gone, nothing stored here can be used for anything but reading it.
///
/// Every dependency is a function so a test can run the whole sequence
/// against fakes, and so the order is the one thing this class decides.
class AccountDeletion {
  AccountDeletion({
    required Future<List<BridgeSignOutTarget>> Function() bridges,
    required Future<void> Function(AccountReauth reauth) deactivate,
    required Future<void> Function() wipe,
  }) : _bridges = bridges,
       _deactivate = deactivate,
       _wipe = wipe;

  final Future<List<BridgeSignOutTarget>> Function() _bridges;
  final Future<void> Function(AccountReauth reauth) _deactivate;
  final Future<void> Function() _wipe;

  /// Signs out of every login on every bridge this account uses.
  ///
  /// Returns the networks that could not be signed out — a bridge that did
  /// not answer, or refused — so the person can decide whether to delete
  /// anyway. Every bridge is tried; one failing does not stop the rest.
  Future<BridgeSignOutReport> signOutBridges() async {
    final failed = <String>[];
    var signedOut = 0;
    for (final (:network, :backend) in await _bridges()) {
      try {
        final whoami = await backend.whoami();
        for (final login in whoami.logins) {
          await backend.logout(login.id);
          signedOut++;
        }
      } on Object {
        if (!failed.contains(network)) failed.add(network);
      } finally {
        backend.dispose();
      }
    }
    return BridgeSignOutReport(signedOut: signedOut, failed: failed);
  }

  /// Deactivates the account, then clears this device.
  ///
  /// Throws what the deactivation throws — [AccountDeactivationCancelled]
  /// when the person backed out of re-authenticating — and clears nothing
  /// then: until the server has said yes, the account is still theirs and so
  /// is everything on this device.
  Future<void> deleteAccount(AccountReauth reauth) async {
    await _deactivate(reauth);
    await _wipe();
  }
}

/// What signing out of the bridges came to.
class BridgeSignOutReport {
  const BridgeSignOutReport({required this.signedOut, required this.failed});

  /// Logins signed out, across every bridge.
  final int signedOut;

  /// Networks that could not be signed out, by name.
  final List<String> failed;
}

/// The bridges worth signing out of: the ones this account is visibly using.
///
/// Detection from joined rooms, the provisioning APIs the server publishes,
/// and any bridge added by hand. Not the bot probe the Bridges screen runs:
/// that finds bots this account has never talked to, and asking each of them
/// who is signed in would open a chat with every bridge on the server only to
/// learn the answer is nobody.
Future<List<BridgeSignOutTarget>> bridgeSignOutTargets(Ref ref) async {
  final factory = ref.read(bridgeBackendFactoryProvider);
  final endpoints = {
    for (final MapEntry(:key, :value) in (await ref.read(
      bridgeEndpointsProvider.future,
    )).entries)
      ChatNetwork.fromBridgeProtocol(key): value,
  };
  final detected = ref.read(detectedBridgesProvider);
  final networks = {
    ...{for (final network in endpoints.keys) network: null},
    for (final bridge in detected)
      if (bridge.botUserId != null) bridge.network: bridge.botUserId,
  };
  final targets = <BridgeSignOutTarget>[];
  for (final MapEntry(key: network, value: botUserId) in networks.entries) {
    final backend = factory(
      network,
      botUserId: botUserId,
      provisioningUrl: endpoints[network],
    );
    if (backend != null) {
      targets.add((network: network.label, backend: backend));
    }
  }

  final client = ref.read(matrixSessionProvider).client;
  for (final bridge in configuredBridges(ref.read(storesProvider).settings)) {
    final url = Uri.tryParse(bridge.url);
    if (url == null || url.host.isEmpty) continue;
    targets.add((
      network: ChatNetwork.fromId(bridge.networkId).label,
      backend: BridgeProvisioningClient(
        baseUrl: url,
        accessToken: client.accessToken ?? '',
        userId: client.userID,
      ),
    ));
  }
  return targets;
}

/// Everything Sennit keeps on this device for the account, gone.
///
/// The Matrix session first: its clear-out stops the sync, and with it the
/// indexer that would otherwise write the next message into a database that
/// was just emptied. It also signs the app out, which is what puts the welcome
/// screen back. Then Sennit's own database, emptied in place — settings, the
/// merge graph, the search index — the credentials in the platform keychain,
/// and the downloaded attachments and notification avatars.
///
/// Downloaded on-device AI models stay. They are the same files for everyone,
/// hold nothing about the account, and are gigabytes to fetch again.
Future<void> wipeLocalData(Ref ref) async {
  await ref.read(matrixSessionProvider).clearLocalData();
  final stores = ref.read(storesProvider);
  stores.db.wipe();
  stores
    ..embeddingApiKey = null
    ..transcriptionApiKey = null
    ..homeAssistantToken = null
    ..paperlessToken = null
    ..llmApiKey = null
    ..calendarIcsUrl = null;
  try {
    await stores.secrets.deleteAll();
  } on Object {
    // A keychain that refuses is reported nowhere useful at this point; the
    // account the credentials were set up for is already gone.
  }
  await _deleteDirectories();
  ref.read(settingsRevisionProvider.notifier).bump();
}

Future<void> _deleteDirectories() async {
  try {
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    for (final directory in [
      Directory(p.join(support.path, 'media')),
      Directory(p.join(cache.path, 'notification-avatars')),
    ]) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  } on Object {
    // Best effort, for the same reason as the keychain above.
  }
}

/// The deletion as the app runs it: the live session, the live bridges, this
/// device's stores.
final accountDeletionProvider = Provider<AccountDeletion>((ref) {
  return AccountDeletion(
    bridges: () => bridgeSignOutTargets(ref),
    deactivate: (reauth) {
      final client = ref.read(matrixSessionProvider).client;
      final userId = client.userID;
      if (userId == null) throw StateError('No account is signed in');
      return deactivateAccount(client, userId: userId, reauth: reauth);
    },
    wipe: () => wipeLocalData(ref),
  );
});

/// The signed-in account's Matrix ID, or null when there is none.
final ownUserIdProvider = Provider<String?>((ref) {
  if (kDemoMode) return '@you:example.org';
  ref.watch(sessionStateProvider);
  try {
    return ref.read(matrixSessionProvider).client.userID;
  } on Object {
    return null;
  }
});
