/// A [BackupService] the widget tests can drive.
///
/// The real one reaches a file dialog, a share sheet and the disk. This one is
/// three scripted answers and a record of what it was asked — which is what
/// lets the screen's *decisions* be tested: that a passphrase mismatch never
/// reaches the export, that cancelling really cancels, and that each typed
/// archive failure comes out as its own sentence.
library;

import 'dart:async';
import 'dart:io';

import 'package:weft/services/backup/backup_service.dart';
import 'package:weft_backup/weft_backup.dart';

/// A recorded call to [FakeBackupService.export].
typedef ExportCall = ({String passphrase, bool includeMedia});

class FakeBackupService implements BackupService {
  FakeBackupService({
    this.estimateResult = const BackupEstimate(
      summary: BackupSummary(
        networks: ['whatsapp', 'sms'],
        chatCount: 12,
        messageCount: 4300,
        mediaCount: 88,
        mediaBytes: 120 * 1024 * 1024,
        otherRecordCount: 40,
      ),
      includeMedia: true,
    ),
    this.estimateError,
    this.exportResult = '/tmp/sennit-2026-08-28.sennit',
    this.exportError,
    this.pickResult,
    this.pickError,
    this.manifestError,
    this.restoreError,
    this.manifestResult,
    this.restoreResult,

    /// How many progress ticks to emit before finishing, so a test can see the
    /// dialog mid-run and press Cancel.
    this.progressTicks = 0,

    /// The gap between ticks.
    ///
    /// A real timer, not a microtask: without one the whole export resolves
    /// inside a single frame, the progress route is pushed and removed before
    /// it can animate in, and a test that means to look at the dialog finds
    /// nothing. `tester.pump(tickDelay)` is then how a test steps the work.
    this.tickDelay = const Duration(milliseconds: 10),
  });

  BackupEstimate estimateResult;
  Object? estimateError;

  String? exportResult;
  Object? exportError;

  PickedArchive? pickResult;
  Object? pickError;

  ArchiveManifest? manifestResult;
  Object? manifestError;

  ImportOutcome? restoreResult;
  Object? restoreError;

  int progressTicks;
  Duration tickDelay;

  final List<ExportCall> exports = [];
  final List<ImportMode> restores = [];
  int estimateCalls = 0;

  @override
  String get appVersion => '1.4.0-test';

  @override
  Future<BackupEstimate> estimate({required bool includeMedia}) async {
    estimateCalls++;
    if (estimateError != null) throw estimateError!;
    return BackupEstimate(
      summary: estimateResult.summary,
      includeMedia: includeMedia,
    );
  }

  @override
  String suggestedFileName([DateTime? at]) => 'sennit-2026-08-28.sennit';

  @override
  Future<String?> export({
    required String passphrase,
    required bool includeMedia,
    void Function(BackupProgress progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  }) async {
    exports.add((passphrase: passphrase, includeMedia: includeMedia));
    await _tick(onProgress, shouldContinue);
    if (exportError != null) throw exportError!;
    return exportResult;
  }

  @override
  Future<PickedArchive?> pickArchive() async {
    if (pickError != null) throw pickError!;
    return pickResult;
  }

  @override
  Future<ArchiveManifest> readManifest(
    PickedArchive archive,
    String passphrase,
  ) async {
    if (manifestError != null) throw manifestError!;
    return manifestResult ??
        ArchiveManifest(
          createdAt: DateTime.utc(2026, 8, 28),
          appVersion: '1.4.0',
          networks: const ['whatsapp', 'sms'],
          chatCount: 12,
          messageCount: 4300,
          mediaIncluded: true,
        );
  }

  @override
  Future<ImportOutcome> restore({
    required PickedArchive archive,
    required String passphrase,
    ImportMode mode = ImportMode.merge,
    void Function(BackupProgress progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  }) async {
    restores.add(mode);
    await _tick(onProgress, shouldContinue);
    if (restoreError != null) throw restoreError!;
    return restoreResult ??
        ImportOutcome(
          manifest: await readManifest(archive, passphrase),
          applied: 4300,
          skippedExisting: 0,
          skippedUnknownType: 0,
          mediaWritten: 88,
          mediaSkipped: 0,
          unknownTypes: const {},
        );
  }

  /// Emits [progressTicks] progress reports, honouring cancellation between
  /// them the way the real export does.
  Future<void> _tick(
    void Function(BackupProgress progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  ) async {
    for (var i = 0; i < progressTicks; i++) {
      await Future<void>.delayed(tickDelay);
      onProgress?.call(
        BackupProgress(bytes: i * 1000, totalBytes: 10000, records: i),
      );
      if (shouldContinue != null && !await shouldContinue()) {
        throw const BackupCancelledException();
      }
    }
  }
}

/// A picked archive with no file behind it.
///
/// The path never opened: every test that uses one has the service faked, so
/// the file is a name for the preview dialog to print and nothing more.
PickedArchive fakePickedArchive({
  String name = 'sennit-2026-08-28.sennit',
  DateTime? createdAt,
  String appVersion = '1.4.0',
  int chatCount = 12,
  int messageCount = 4300,
  bool mediaIncluded = true,
}) => PickedArchive(
  file: File('/nowhere/$name'),
  preview: ArchivePreview(
    createdAt: createdAt ?? DateTime.utc(2026, 8, 28, 9, 30),
    appVersion: appVersion,
    chatCount: chatCount,
    messageCount: messageCount,
    mediaIncluded: mediaIncluded,
    totalBytes: 120 * 1024 * 1024,
  ),
);
