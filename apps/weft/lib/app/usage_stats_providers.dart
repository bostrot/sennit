import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:weft_store/weft_store.dart' show WeftSettings;

import '../services/analytics/do_not_track.dart';
import '../services/analytics/usage_stats.dart';
import '../services/backup/backup_service.dart' show kSennitVersion;
import 'session_providers.dart';
import 'stores.dart';

/// Whether the user said yes to anonymous usage statistics. Off until they
/// do, and off in the demo build, which is what store reviewers and
/// screenshots run.
final usageStatsEnabledProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  if (kDemoMode) return false;
  return storesOrNull(ref)?.settings.getBool(WeftSettings.usageStats) ?? false;
});

/// Where events go. Only a release build reaches Plausible: `flutter run` and
/// tests would otherwise count as users. Overridden in tests.
final usageSenderProvider = Provider<UsageSender>((ref) {
  if (!kReleaseMode) return _drop;
  final plausible = Plausible(
    kUsageStatsServer,
    kUsageStatsDomain,
    // Logical pixels, from which Plausible tells phone, tablet and desktop.
    screenWidth: _screenWidth,
  );
  return ({required name, required page, required props}) =>
      plausible.event(name: name, page: page, props: props);
});

Future<void> _drop({
  required String name,
  required String page,
  required Map<String, String> props,
}) async {}

final usageStatsProvider = Provider<UsageStats>((ref) {
  return UsageStats(
    allowed: () =>
        ref.read(usageStatsEnabledProvider) && !platformAsksNotToTrack(),
    send: ref.watch(usageSenderProvider),
    props: {'app_version': kSennitVersion, 'platform': _platform},
  );
});

String get _screenWidth {
  final view = PlatformDispatcher.instance.implicitView;
  if (view == null) return '';
  return (view.physicalSize.width / view.devicePixelRatio).round().toString();
}

String get _platform => kIsWeb ? 'web' : defaultTargetPlatform.name;
