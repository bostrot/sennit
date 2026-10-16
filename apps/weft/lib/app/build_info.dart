import 'package:flutter/foundation.dart';

/// What a build knows about where it came from, for the About dialog.
///
/// Filled from `--dart-define`s, which `tooling/scripts/build_info.sh` writes
/// as a `--dart-define-from-file` JSON for the TestFlight and Play internal
/// builds. Those are the builds a tester reports a bug against, and "1.0.2"
/// names every one of them alike; the commit tells them apart. A build without
/// the defines — a tagged release, `flutter run` — reads empty strings.
@immutable
class BuildInfo {
  const BuildInfo({
    this.commit = '',
    this.ref = '',
    this.tag = '',
    this.builtAt = '',
    this.mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
  });

  static const BuildInfo current = BuildInfo(
    commit: String.fromEnvironment('GIT_SHA'),
    ref: String.fromEnvironment('GIT_REF'),
    tag: String.fromEnvironment('GIT_TAG'),
    builtAt: String.fromEnvironment('BUILD_TIME'),
  );

  /// The short commit sha.
  final String commit;

  /// The branch the build was made from.
  final String ref;

  /// The tag the commit carries, when it is a release.
  final String tag;

  /// ISO 8601, as `date -u +%Y-%m-%dT%H:%M:%SZ` writes it.
  final String builtAt;

  /// `debug`, `profile` or `release`.
  final String mode;

  /// One line for the About dialog: `a1b2c3d · main · 2026-10-15 05:42 UTC ·
  /// release`.
  ///
  /// Null for a tagged build, whose version already says which one it is, and
  /// for a release build that was given nothing to say. No labels, so there is
  /// nothing to translate: a sha, a branch and a date read the same in every
  /// language, and the line is for pasting into a bug report.
  String? get summary {
    if (tag.isNotEmpty) return null;
    if (commit.isEmpty && mode == 'release') return null;
    final built = DateTime.tryParse(builtAt)?.toUtc();
    return [
      if (commit.isNotEmpty) commit,
      if (ref.isNotEmpty) ref,
      if (built != null) '${_date(built)} UTC',
      mode,
    ].join(' · ');
  }

  static String _date(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
