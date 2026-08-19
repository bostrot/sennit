import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/snapshot/snapshot_writer.dart';
import '../services/snapshot/watch_reply_handler.dart';
import 'providers.dart';
import 'stores.dart';

/// The companion-surface gate as the app reads it.
///
/// Fails closed, the same way [linkPreviewSettingsProvider] does: until the
/// database is open nobody can say whether the user opted into writing message
/// previews outside the encrypted store, and the honest answer to that is
/// "they did not".
final snapshotSettingsProvider = Provider<SnapshotSettings>((ref) {
  ref.watch(settingsRevisionProvider);
  final stores = storesOrNull(ref);
  return stores == null
      ? SnapshotSettings.off
      : SnapshotSettings.fromStore(stores.settings);
});

/// Where the snapshot actually goes.
///
/// Stateless — every method is a channel call — so one instance is for tidiness
/// rather than correctness. A test overrides it with a fake, or with an instance
/// over its own `MethodChannel`.
final snapshotGatewayProvider = Provider<SnapshotGateway>(
  (ref) => WeftSnapshotContainer(),
);

/// The app's one [SnapshotWriter].
///
/// One because it holds the answer to "what does the container currently hold",
/// and two of them would each believe they had written a different payload —
/// which is the same home screen re-layout on every inbox tick that the diff
/// exists to prevent, only harder to see.
///
/// Deliberately does *not* watch [snapshotSettingsProvider]: a provider rebuilt
/// on every settings bump would be a new writer with no memory of what it had
/// written, so changing the theme would rewrite the snapshot. The gate reaches
/// it through [SnapshotWriter.applySettings] instead, from the one listener in
/// `main.dart` that already knows when the session is up.
final snapshotWriterProvider = Provider<SnapshotWriter>(
  (ref) => SnapshotWriter(gateway: ref.watch(snapshotGatewayProvider)),
);

/// Where a watch reply arrives from, and where its result goes back to.
///
/// The same shape as [snapshotGatewayProvider] and for the same reason: the
/// thing behind it is a `WCSession` on one platform and a `MessageClient` on
/// another, and neither exists in a widget test.
final watchReplyGatewayProvider = Provider<WatchReplyGateway>(
  (ref) => WeftWatchBridge(),
);

/// The app's one [WatchReplyHandler].
///
/// One, for the reason [snapshotWriterProvider] is one and one sharper: it holds
/// the queue and the set of reply ids already handled, and a second instance
/// would be a second set — which is a duplicate delivery becoming a second
/// message rather than a second acknowledgement.
///
/// `read` rather than `watch` on the repository, deliberately. Watching would
/// rebuild the handler — and empty its queue — whenever the repository provider
/// was invalidated, which is every sign-in. The send is resolved per call
/// instead, so a reply queued before a reconnection is sent through the
/// repository that exists when it finally goes.
final watchReplyHandlerProvider = Provider<WatchReplyHandler>(
  (ref) => WatchReplyHandler(
    gateway: ref.watch(watchReplyGatewayProvider),
    send: (chatId, body, {via}) =>
        ref.read(chatRepositoryProvider).send(chatId, body, via: via),
  ),
);
