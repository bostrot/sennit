import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/share/shortcut_service.dart';
import 'intents.dart';
import 'notification_providers.dart';

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
    publisher: ref.watch(shareTargetPublisherProvider),
    avatarLoader: (url) async {
      final loader = await ref.read(avatarFileLoaderProvider.future);
      return loader == null ? null : await loader(url);
    },
  );
});
