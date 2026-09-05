import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/backup/backup_service.dart';

/// One assertion, and it exists because the alternative is a lie in a file.
///
/// [kBraidVersion] is a constant rather than a `package_info_plus` lookup, so
/// that a widget test of the backup screen does not need a method-channel mock
/// for a string only ever shown back to the user in a support conversation.
/// The cost of that choice is that it can drift from `pubspec.yaml` silently,
/// and the place it would surface is inside an archive written a year ago by a
/// build claiming to be a version it was not — which is exactly the moment
/// somebody is trying to work out why a restore is failing.
void main() {
  test('kBraidVersion matches the version in pubspec.yaml', () {
    // Resolved from this file rather than from the process working directory:
    // `flutter test` runs from `apps/weft`, but the workspace root and an IDE
    // both run it from somewhere else.
    final pubspec = File('pubspec.yaml').existsSync()
        ? File('pubspec.yaml')
        : File('apps/weft/pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: 'run from apps/weft or from the workspace root',
    );

    final line = pubspec.readAsLinesSync().firstWhere(
      (l) => l.startsWith('version:'),
      orElse: () => '',
    );
    expect(line, isNotEmpty, reason: 'pubspec.yaml has no version');

    // `1.0.0+1` — the build number after `+` is not part of what an archive
    // records, because it changes on every store upload and says nothing a
    // support conversation needs.
    final declared = line.split(':').last.trim().split('+').first;
    expect(kBraidVersion, declared);
  });
}
