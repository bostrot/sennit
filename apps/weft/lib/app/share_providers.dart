import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_share/weft_share.dart';

import '../services/notifications/push_registration.dart';
import '../services/share/shortcut_service.dart';
import '../services/share/staged_share_reader.dart';
import 'intents.dart';
import 'notification_providers.dart';

/// The app's one [ShareTargetRanker], and the capability table inside it.
///
/// A provider for a `const` object, which is only worth it because two surfaces
/// have to agree: the launcher shortcuts published from
/// [shareShortcutServiceProvider], and the in-app share sheet's own list. Those
/// are the same four faces twice — Android's share sheet row is a prefix of
/// what the sheet shows — and two independently constructed rankers would drift
/// the moment either grew a tuned weight or a network override.
///
/// The sheet also reads [ShareTargetRanker.capabilities] directly, to ask which
/// legs of a merged chat can carry the file in hand. That is the same table the
/// ranking filtered on, so a chat offered by the list cannot then be told every
/// one of its networks refuses the share.
final shareTargetRankerProvider = Provider<ShareTargetRanker>(
  (ref) => const ShareTargetRanker(),
);

/// The app's one [ShareShortcutService].
///
/// One because it holds the answer to "what is currently published", and two of
/// them would each believe they had published a different set — which is the
/// same launcher thrash the diff exists to prevent, only harder to see.
///
/// A synchronous provider over an asynchronous cache: the avatar loader needs
/// the cache directory and so cannot be constructed without awaiting, but the
/// chat-list listener that drives this has no `await` to spend. The closure
/// resolves [avatarFileLoaderProvider] on the first slot that actually has an
/// avatar to fetch, and the notification path is fetching from the same cache.
final shareShortcutServiceProvider = Provider<ShareShortcutService>((ref) {
  return ShareShortcutService(
    publisher: ref.watch(shareTargetSurfaceProvider),
    ranker: ref.watch(shareTargetRankerProvider),
    avatarLoader: (url) async {
      final loader = await ref.read(avatarFileLoaderProvider.future);
      return loader == null ? null : await loader(url);
    },
  );
});

/// The app's one [WeftStagedShares]: the iOS App Group container.
///
/// Stateless — every method is a channel call — so one is for tidiness rather
/// than correctness, and a test overrides it with an instance over its own
/// channel or with a fake.
final stagedSharesProvider = Provider<WeftStagedShares>(
  (ref) => WeftStagedShares(),
);

/// Where the ranked target list actually goes, which is not the same place on
/// both platforms.
///
/// Android publishes it to the launcher as conversation shortcuts, over the
/// `/intents` channel `WeftIntents` owns. iOS writes it into the App Group
/// container, because the surface reading it is the Share Extension's own
/// picker in another process. Everything above this line — the ranking, the
/// diff, the avatar resolution, the cap — is identical, which is the point of
/// having the seam at all.
///
/// Composed rather than branched inside [shareTargetPublisherProvider] so that
/// `app/intents.dart` does not have to import a service that imports it back.
/// A test can override either: this one to replace the choice, that one to
/// replace what Android does with it.
///
/// [NotificationPlatform] is read for the platform answer despite the name. It
/// is the app's one place for "which platform is this", it reads
/// `defaultTargetPlatform` rather than `dart:io` — which is the only way this
/// branch is reachable from `flutter test` at all — and a second copy of one
/// getter is worth less than the confusion it would save.
final shareTargetSurfaceProvider = Provider<ShareTargetPublisher>(
  (ref) => NotificationPlatform.isIOS
      ? ref.watch(stagedSharesProvider)
      : ref.watch(shareTargetPublisherProvider),
);

/// The app's one [StagedShareReader].
///
/// One because it remembers which shares this run has already committed to, and
/// a second reader would happily offer the same capture again.
final stagedShareReaderProvider = Provider<StagedShareReader>(
  (ref) => StagedShareReader(gateway: ref.watch(stagedSharesProvider)),
);
