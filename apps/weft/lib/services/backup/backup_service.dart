/// Wiring the `.braid` archive to the app: the stores it reads, the media
/// directory it walks, and the platform dialogs at either end.
///
/// `weft_backup` decides the format and `weft_store` supplies the SQL. What is
/// left — and what lives here — is the part that needs a running app: which
/// directory the attachments are in, what to call the file, and how a file gets
/// out of Braid and back in on five platforms.
///
/// A class behind a provider rather than free functions, for the reason
/// [MediaExporter] and [AttachmentPicker] are interfaces: everything at the
/// edges is a method channel, and a widget test that reaches one gets a
/// `MissingPluginException`. Overriding [backupServiceProvider] replaces the
/// file dialogs, the share sheet and the disk in one move, and leaves the
/// format, the crypto and the merge rules real.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_backup/weft_backup.dart';
// `StoreBackupSource` and `StoreBackupSink` — the SQL half of the archive,
// which lives with the schema rather than with the format.
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';
import '../attachments/media_exporter.dart';

/// The extension, and the only one the restore picker offers.
///
/// Its own extension rather than `.zip` or `.dat` because the file has to be
/// recognisable a year later in a Files app full of things, next to five other
/// backups, by someone who is having a bad day.
const String kBraidArchiveExtension = 'braid';

/// Picks an existing archive to restore from.
///
/// Separate from [MediaExporter] — which already has the save and share halves
/// this feature reuses — because opening is the one direction it does not do,
/// and widening an interface used by the media viewer for the sake of a
/// settings screen would be the wrong shape.
abstract class ArchivePicker {
  /// The file the user chose, or null if they cancelled — which is not an
  /// error and must never be reported as one.
  Future<File?> pickArchive();
}

/// `file_selector`, filtered to `.braid`.
class PlatformArchivePicker implements ArchivePicker {
  const PlatformArchivePicker();

  @override
  Future<File?> pickArchive() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Braid backup', extensions: [kBraidArchiveExtension]),
      ],
    );
    return file == null ? null : File(file.path);
  }
}

/// What the export screen shows before anything is written.
@immutable
class BackupEstimate {
  const BackupEstimate({required this.summary, required this.includeMedia});

  final BackupSummary summary;
  final bool includeMedia;

  int get messageCount => summary.messageCount;
  int get chatCount => summary.chatCount;
  int get mediaCount => includeMedia ? summary.mediaCount : 0;

  /// The size to show next to the media toggle.
  int get estimatedBytes => summary.estimatedBytes;
}

/// An archive the user has picked but not yet unlocked.
@immutable
class PickedArchive {
  const PickedArchive({required this.file, required this.preview});

  final File file;

  /// What the plaintext header says. Deliberately the *only* thing known at
  /// this point — see [ArchivePreview] for what is held back and why.
  final ArchivePreview preview;

  String get fileName => p.basename(file.path);
}

/// Export and restore, as the settings screen needs them.
class BackupService {
  BackupService({
    required WeftStores stores,
    required MediaExporter exporter,
    required ArchivePicker picker,
    required this.appVersion,
    Future<Directory> Function()? mediaDirectory,
    Future<Directory> Function()? stagingDirectory,
    DateTime Function()? now,
  }) : _stores = stores,
       _exporter = exporter,
       _picker = picker,
       _mediaDirectory = mediaDirectory ?? _defaultMediaDirectory,
       _stagingDirectory = stagingDirectory ?? _defaultStagingDirectory,
       _now = now ?? DateTime.now;

  final WeftStores _stores;
  final MediaExporter _exporter;
  final ArchivePicker _picker;
  final Future<Directory> Function() _mediaDirectory;
  final Future<Directory> Function() _stagingDirectory;
  final DateTime Function() _now;

  /// Recorded in the manifest, for a support conversation. Never parsed.
  final String appVersion;

  /// The same directory `MediaFileStore` stages downloads into.
  ///
  /// Hard-coded to match rather than shared through a provider because
  /// `MediaFileStore` resolves it privately and a second opinion about where
  /// attachments live is a class of bug where the backup is silently empty.
  static Future<Directory> _defaultMediaDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'media'));
  }

  /// Where an export is written before the user says where it goes.
  ///
  /// The share sheet and the save dialog both want a file that already exists,
  /// so the archive is built here first and copied out afterwards. Under the
  /// system temporary directory, because a backup the user abandoned should not
  /// survive as a second copy of their history in application support.
  static Future<Directory> _defaultStagingDirectory() async =>
      Directory.systemTemp.createTemp('braid-backup');

  Future<BackupEstimate> estimate({required bool includeMedia}) async {
    final source = StoreBackupSource(
      database: _stores.db,
      mediaDirectory: await _mediaDirectory(),
    );
    return BackupEstimate(
      summary: await source.summarise(includeMedia: includeMedia),
      includeMedia: includeMedia,
    );
  }

  /// The name an archive is offered under.
  ///
  /// Dated, because the second thing anyone does with a backup is make another
  /// one, and two files called `braid-backup.braid` is how the wrong one gets
  /// restored. ISO order so they sort chronologically in a file list.
  String suggestedFileName([DateTime? at]) {
    final when = at ?? _now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'braid-${when.year}-${two(when.month)}-${two(when.day)}'
        '.$kBraidArchiveExtension';
  }

  /// Writes an archive and hands it to the platform.
  ///
  /// Returns null when the user cancelled the save dialog, which is not a
  /// failure. Throws [BackupCancelledException] when they cancelled the
  /// *export* — a different event, at a different point, and the one that
  /// happens with a progress bar on screen.
  ///
  /// The staging directory is deleted either way. A `.braid` left in temp is a
  /// complete, passphrase-protected copy of the user's history that nothing
  /// will ever clean up.
  Future<String?> export({
    required String passphrase,
    required bool includeMedia,
    void Function(BackupProgress progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  }) async {
    final staging = await _stagingDirectory();
    final target = File(p.join(staging.path, suggestedFileName()));

    try {
      await exportArchiveToFile(
        source: StoreBackupSource(
          database: _stores.db,
          mediaDirectory: await _mediaDirectory(),
        ),
        passphrase: passphrase,
        target: target,
        appVersion: appVersion,
        createdAt: _now(),
        includeMedia: includeMedia,
        onProgress: onProgress,
        shouldContinue: shouldContinue,
      );

      if (_exporter.canSave) {
        return await _exporter.save(
          target,
          suggestedName: p.basename(target.path),
        );
      }

      // Mobile has no save dialog; the share sheet is how a file reaches Files
      // or Drive. `share` cannot report where it went, so the destination is
      // unknown rather than absent — the screen says "shared" rather than
      // naming a path.
      await _exporter.share(target, mimeType: 'application/octet-stream');
      return '';
    } finally {
      await _sweep(staging);
    }
  }

  /// Asks the user for a file and reads its header.
  ///
  /// Returns null when they cancelled. Throws [ArchiveOpenFailure] when the
  /// file is not one this build can read — which is the whole point of doing
  /// this before the passphrase is requested.
  Future<PickedArchive?> pickArchive() async {
    final file = await _picker.pickArchive();
    if (file == null) return null;
    return PickedArchive(
      file: file,
      preview: await readArchiveFilePreview(file),
    );
  }

  /// Restores [archive] under [passphrase].
  ///
  /// Every failure is an [ArchiveOpenFailure] with a type the screen turns into
  /// its own sentence. Nothing is written unless the whole thing succeeds.
  Future<ImportOutcome> restore({
    required PickedArchive archive,
    required String passphrase,
    ImportMode mode = ImportMode.merge,
    void Function(BackupProgress progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  }) async {
    final reader = await openArchiveFile(archive.file, passphrase);
    try {
      return await importArchive(
        reader: reader,
        sink: StoreBackupSink(
          database: _stores.db,
          mediaDirectory: await _mediaDirectory(),
        ),
        mode: mode,
        onProgress: onProgress,
        shouldContinue: shouldContinue,
      );
    } finally {
      await reader.close();
    }
  }

  /// Reads the manifest without importing anything.
  ///
  /// The restore flow's second screen: the passphrase has been accepted, and
  /// this is what the archive turns out to hold — including the network list
  /// the plaintext header deliberately withholds. The last chance to back out.
  Future<ArchiveManifest> readManifest(
    PickedArchive archive,
    String passphrase,
  ) async {
    final reader = await openArchiveFile(archive.file, passphrase);
    try {
      return reader.manifest;
    } finally {
      await reader.close();
    }
  }

  Future<void> _sweep(Directory staging) async {
    if (!staging.existsSync()) return;
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // Best effort. Failing the export over a temporary directory would
      // replace a backup the user has in hand with an error about tidying.
    }
  }
}

/// Picks archives to restore. Overridden in tests; the real one is a method
/// channel.
final archivePickerProvider = Provider<ArchivePicker>(
  (ref) => const PlatformArchivePicker(),
);

/// Export and restore for the settings screen.
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    stores: ref.watch(storesProvider),
    exporter: ref.watch(mediaExporterProvider),
    picker: ref.watch(archivePickerProvider),
    appVersion: kBraidVersion,
  );
});

/// The build that writes an archive, recorded in its manifest.
///
/// A constant rather than `package_info_plus`, which is a method channel and
/// would make every widget test of this screen need a mock for a string that is
/// only ever shown back to the user in a support conversation. It is checked
/// against `pubspec.yaml` by `backup_version_test.dart`, so it cannot drift
/// silently.
const String kBraidVersion = '1.0.1';
