import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;

import '../services/backup/backup_service.dart' show kSennitVersion;
import '../services/review/review_prompt.dart';
import 'call_providers.dart';
import 'stores.dart';

/// The store-rating prompt for this build, or null before the stores are
/// open. Overridden in tests.
final reviewPrompterProvider = Provider<ReviewPrompter?>((ref) {
  final stores = storesOrNull(ref);
  if (stores == null) return null;
  return ReviewPrompter(
    stores.settings,
    store: ReviewStore.current,
    version: kSennitVersion,
  );
});

/// What is going on right now, as far as the rating prompt cares; the
/// caller adds whether the user is typing.
ReviewMoment currentReviewMoment(
  WidgetRef ref,
  SettingsStore settings, {
  required bool composing,
}) {
  return ReviewMoment(
    crashedThisSession: reviewSessionHadError,
    onboarding:
        !settings.getBool(WeftSettings.onboardingDone) ||
        settings.getBool(WeftSettings.walkthroughPending),
    inCall: ref.read(currentCallProvider).hasCall,
    composing: composing,
  );
}
