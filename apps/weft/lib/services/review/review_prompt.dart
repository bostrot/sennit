import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;

/// Which store's own rating sheet this build may show, if any.
///
/// Chosen at build time with `--dart-define=SENNIT_STORE=play` or
/// `=appstore`, which only the pipelines that upload to Play and the App
/// Store pass. Everything else — the release page, Homebrew, F-Droid-style
/// rebuilds, a source checkout — is [none] and never asks: a rating sheet
/// pointing at a store the app did not come from is no use to anyone.
enum ReviewStore {
  none,
  play,
  appStore;

  static ReviewStore parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'play' => play,
        'appstore' => appStore,
        _ => none,
      };

  /// [parse]'s answer, kept only on a platform that store serves: the
  /// define says where the build was meant to go, the platform says whether
  /// this is that build.
  static ReviewStore resolve(
    String value, {
    required TargetPlatform platform,
    required bool isWeb,
  }) {
    if (isWeb) return none;
    return switch ((parse(value), platform)) {
      (play, TargetPlatform.android) => play,
      (appStore, TargetPlatform.iOS || TargetPlatform.macOS) => appStore,
      _ => none,
    };
  }

  static final ReviewStore current = resolve(
    const String.fromEnvironment('SENNIT_STORE'),
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
  );
}

/// When a happy user may be asked for a store rating.
///
/// Every threshold is here so tuning one is a one-line change. The store may
/// still decide not to show its sheet — both cap how often an app can ask —
/// so these only decide when Sennit *asks*, never whether anything appears.
abstract final class ReviewPolicy {
  /// How long Sennit has been installed before it asks.
  static const Duration minInstallAge = Duration(days: 5);

  /// Distinct days the app was used on.
  static const int minActiveDays = 3;

  /// Messages the user sent from Sennit.
  static const int minMessagesSent = 20;

  /// The least time between two asks, whatever the version.
  static const Duration minInterval = Duration(days: 90);
}

/// The local counters the decision is made from. Nothing here leaves the
/// device.
@immutable
class ReviewCounters {
  const ReviewCounters({
    required this.firstSeen,
    required this.activeDays,
    required this.messagesSent,
    this.lastPrompt,
    this.lastPromptVersion,
  });

  final DateTime firstSeen;
  final int activeDays;
  final int messagesSent;
  final DateTime? lastPrompt;
  final String? lastPromptVersion;
}

/// What is going on right now that rules a prompt out regardless of the
/// counters.
@immutable
class ReviewMoment {
  const ReviewMoment({
    this.crashedThisSession = false,
    this.onboarding = false,
    this.inCall = false,
    this.composing = false,
  });

  final bool crashedThisSession;
  final bool onboarding;
  final bool inCall;
  final bool composing;
}

/// Whether to ask for a rating now. Pure, so the rules can be tested without
/// a store, a clock or a platform.
bool shouldRequestReview({
  required ReviewStore store,
  required ReviewCounters counters,
  required ReviewMoment moment,
  required DateTime now,
  required String version,
}) {
  if (store == ReviewStore.none) return false;
  if (moment.crashedThisSession ||
      moment.onboarding ||
      moment.inCall ||
      moment.composing) {
    return false;
  }
  if (now.difference(counters.firstSeen) < ReviewPolicy.minInstallAge) {
    return false;
  }
  if (counters.activeDays < ReviewPolicy.minActiveDays) return false;
  if (counters.messagesSent < ReviewPolicy.minMessagesSent) return false;
  if (counters.lastPromptVersion == version) return false;
  final last = counters.lastPrompt;
  if (last != null && now.difference(last) < ReviewPolicy.minInterval) {
    return false;
  }
  return true;
}

/// Set by the app's error hooks when anything went wrong this run, so a
/// session that just showed the user a failure never ends in a rating sheet.
bool reviewSessionHadError = false;

/// Keeps the counters in the settings table and asks the store when
/// [shouldRequestReview] says so.
class ReviewPrompter {
  ReviewPrompter(
    this.settings, {
    required this.store,
    required this.version,
    DateTime Function()? clock,
    Future<void> Function()? request,
  }) : _clock = clock ?? DateTime.now,
       _request = request ?? _requestFromStore;

  final SettingsStore settings;
  final ReviewStore store;
  final String version;
  final DateTime Function() _clock;
  final Future<void> Function() _request;

  static Future<void> _requestFromStore() async {
    final review = InAppReview.instance;
    if (await review.isAvailable()) await review.requestReview();
  }

  /// Counts today as a day the app was used, and starts the install clock
  /// on the first call. Cheap enough for every start and every send.
  void recordActive() {
    final now = _clock();
    if (settings.getInt(WeftSettings.reviewFirstSeenMs) == null) {
      settings.setInt(
        WeftSettings.reviewFirstSeenMs,
        now.millisecondsSinceEpoch,
      );
    }
    final today = _dayKey(now);
    if (settings.getString(WeftSettings.reviewLastActiveDay) != today) {
      settings
        ..setString(WeftSettings.reviewLastActiveDay, today)
        ..setInt(
          WeftSettings.reviewActiveDays,
          (settings.getInt(WeftSettings.reviewActiveDays) ?? 0) + 1,
        );
    }
  }

  /// A message went out: counts it, and — this being a good moment — asks
  /// for a rating if everything else agrees. Returns whether it asked.
  Future<bool> noteMessageSent(ReviewMoment moment) async {
    recordActive();
    settings.setInt(
      WeftSettings.reviewMessagesSent,
      (settings.getInt(WeftSettings.reviewMessagesSent) ?? 0) + 1,
    );
    return maybeAsk(moment);
  }

  /// Asks if [shouldRequestReview] agrees, and records the ask first so a
  /// store that throws or never answers is not asked again this version.
  Future<bool> maybeAsk(ReviewMoment moment) async {
    final now = _clock();
    if (!shouldRequestReview(
      store: store,
      counters: counters(),
      moment: moment,
      now: now,
      version: version,
    )) {
      return false;
    }
    settings
      ..setInt(WeftSettings.reviewLastPromptMs, now.millisecondsSinceEpoch)
      ..setString(WeftSettings.reviewLastPromptVersion, version);
    try {
      await _request();
    } on Object catch (error) {
      debugPrint('weft: review request failed: $error');
    }
    return true;
  }

  ReviewCounters counters() {
    final firstSeen = settings.getInt(WeftSettings.reviewFirstSeenMs);
    final lastPrompt = settings.getInt(WeftSettings.reviewLastPromptMs);
    return ReviewCounters(
      firstSeen: firstSeen == null
          ? _clock()
          : DateTime.fromMillisecondsSinceEpoch(firstSeen),
      activeDays: settings.getInt(WeftSettings.reviewActiveDays) ?? 0,
      messagesSent: settings.getInt(WeftSettings.reviewMessagesSent) ?? 0,
      lastPrompt: lastPrompt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastPrompt),
      lastPromptVersion: settings.getString(
        WeftSettings.reviewLastPromptVersion,
      ),
    );
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
