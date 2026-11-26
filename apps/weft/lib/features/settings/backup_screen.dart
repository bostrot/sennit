/// Getting a user's history out of Sennit, and back in.
///
/// Two flows on one screen, and they are not symmetrical. Export is a decision
/// about a passphrase; restore is a decision about a *file*, made twice — once
/// on what the plaintext header says, and again on what the manifest says after
/// the passphrase has opened it. The second reveal exists because the header
/// deliberately withholds which networks the archive covers, and because the
/// moment before writing to the store is the right place for the last
/// "are you sure".
///
/// The copy follows the house rule the privacy gates set: say the cost in the
/// sentence next to the control, in the words the user would use. Here the cost
/// is unusually blunt — a lost passphrase is a lost archive, with nobody to ask
/// — so it is stated on the passphrase step rather than filed under a help
/// link, and the export cannot start without it having been on screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_backup/weft_backup.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../services/backup/backup_service.dart';
import 'settings_section.dart';

/// The shortest passphrase the export dialog will accept.
///
/// Not a strength meter, which would be theatre over a KDF that is already the
/// real defence: Argon2id at 64 MiB makes a guess expensive, and what is left
/// for a minimum to do is stop the three-character passphrase somebody types to
/// get past a dialog. Twelve is long enough that a passphrase is a phrase.
const int kMinBackupPassphraseLength = 12;

/// A text field that is still visible when it is not focused.
///
/// The app's `InputDecorationTheme` gives fields no border at all and
/// distinguishes them by their fill, `surfaceContainerHigh` — which is also
/// Material 3's default `AlertDialog` background. On a dialog the two are the
/// same colour, so an unfocused field is an invisible rectangle: the passphrase
/// confirmation rendered as a floating label over nothing, and the only cue
/// that there was a second box to type in was the first one losing its focus
/// ring.
///
/// Fixed here rather than in `WeftTheme` because the theme's borderless fields
/// are correct everywhere they sit on an ordinary surface, and changing the
/// enabled border globally would restyle every field in the app. The collision
/// is worth fixing at the theme eventually — `TextPromptDialog` has it too —
/// but not as a side effect of this screen.
InputDecoration _dialogFieldDecoration(
  BuildContext context, {
  required String label,
  String? helperText,
  String? errorText,
}) {
  final outline = OutlineInputBorder(
    borderRadius: WeftRadius.allMd,
    borderSide: BorderSide(color: context.colors.outlineVariant),
  );
  return InputDecoration(
    labelText: label,
    helperText: helperText,
    helperMaxLines: 3,
    errorText: errorText,
    errorMaxLines: 3,
    border: outline,
    enabledBorder: outline,
  );
}

/// Export and restore.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _includeMedia = true;
  BackupEstimate? _estimate;
  Object? _estimateError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEstimate());
  }

  /// Counts what an export would hold.
  ///
  /// Recomputed when the media toggle moves, because the size next to it is the
  /// entire reason anyone touches that switch. Failures are kept rather than
  /// thrown: a database that cannot be counted is still one that can usually be
  /// exported, and refusing to draw the screen over a `COUNT(*)` would take the
  /// feature away for a worse reason than it exists.
  Future<void> _loadEstimate() async {
    try {
      final estimate = await ref
          .read(backupServiceProvider)
          .estimate(includeMedia: _includeMedia);
      if (mounted) {
        setState(() {
          _estimate = estimate;
          _estimateError = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _estimateError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final estimate = _estimate;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.backupTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            Text(
              l10n.backupIntro,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.lg),

            SettingsSectionHeader(
              title: l10n.backupExportSectionTitle,
              subtitle: l10n.backupExportSectionSubtitle,
            ),

            SwitchListTile(
              title: Text(l10n.backupIncludeMediaTitle),
              subtitle: Text(
                estimate == null
                    ? l10n.backupIncludeMediaSubtitle
                    : l10n.backupIncludeMediaSize(
                        l10n.fileSize(estimate.estimatedBytes),
                      ),
              ),
              value: _includeMedia,
              onChanged: (value) {
                setState(() => _includeMedia = value);
                unawaited(_loadEstimate());
              },
              contentPadding: EdgeInsets.zero,
            ),

            if (estimate != null)
              Padding(
                padding: const EdgeInsets.only(bottom: WeftSpace.md),
                child: Text(
                  l10n.backupEstimateContents(
                    estimate.chatCount,
                    estimate.messageCount,
                  ),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (_estimateError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: WeftSpace.md),
                child: Text(
                  l10n.backupEstimateUnavailable,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.error,
                  ),
                ),
              ),

            Align(
              alignment: AlignmentDirectional.centerStart,
              child: WeftTapTarget(
                child: FilledButton.icon(
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: Text(l10n.backupExportAction),
                  onPressed: _startExport,
                ),
              ),
            ),

            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: l10n.backupRestoreSectionTitle,
              subtitle: l10n.backupRestoreSectionSubtitle,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: WeftTapTarget(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: Text(l10n.backupRestoreAction),
                  onPressed: _startRestore,
                ),
              ),
            ),

            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: l10n.backupExcludedTitle,
              subtitle: l10n.backupExcludedSubtitle,
            ),
            Text(
              l10n.backupExcludedBody,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ export

  Future<void> _startExport() async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(),
    );
    if (passphrase == null || !mounted) return;

    final progress = _ProgressController();
    final running = ref
        .read(backupServiceProvider)
        .export(
          passphrase: passphrase,
          includeMedia: _includeMedia,
          onProgress: progress.report,
          shouldContinue: progress.shouldContinue,
        );

    final l10n = context.l10n;
    try {
      final destination = await _runWithProgress(
        title: l10n.backupExportProgressTitle,
        controller: progress,
        work: running,
      );
      if (!mounted) return;

      if (destination == null) {
        // The save dialog was dismissed. Nothing was written anywhere the user
        // can see, and telling them off for it would be wrong.
        return;
      }
      showWeftMessage(
        context,
        destination.isEmpty
            ? l10n.backupExportShared
            : l10n.backupExportSaved(destination),
      );
    } on BackupCancelledException {
      if (mounted) showWeftMessage(context, l10n.backupExportCancelled);
    } on Object catch (error) {
      if (mounted) showWeftMessage(context, _describeFailure(context, error));
    }
  }

  // ----------------------------------------------------------------- restore

  Future<void> _startRestore() async {
    final service = ref.read(backupServiceProvider);
    final l10n = context.l10n;

    final PickedArchive? picked;
    try {
      picked = await service.pickArchive();
    } on Object catch (error) {
      if (mounted) showWeftMessage(context, _describeFailure(context, error));
      return;
    }
    if (picked == null || !mounted) return;

    // First reveal: what the plaintext header says, before a passphrase is
    // asked for. This is the step that turns "you picked the wrong file" into
    // its own sentence instead of five failed passphrase attempts.
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => _ArchivePreviewDialog(archive: picked!),
    );
    if (proceed != true || !mounted) return;

    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _RestorePassphraseDialog(),
    );
    if (passphrase == null || !mounted) return;

    // Second reveal: the manifest, which needed the passphrase and carries the
    // network list the header withheld. Opening the archive here also means a
    // wrong passphrase is reported before any mode has been chosen.
    final ArchiveManifest manifest;
    try {
      manifest = await service.readManifest(picked, passphrase);
    } on Object catch (error) {
      if (mounted) showWeftMessage(context, _describeFailure(context, error));
      return;
    }
    if (!mounted) return;

    final mode = await showDialog<ImportMode>(
      context: context,
      builder: (_) => _RestoreModeDialog(manifest: manifest),
    );
    if (mode == null || !mounted) return;

    final progress = _ProgressController();
    final running = service.restore(
      archive: picked,
      passphrase: passphrase,
      mode: mode,
      onProgress: progress.report,
      shouldContinue: progress.shouldContinue,
    );

    try {
      final outcome = await _runWithProgress(
        title: l10n.backupRestoreProgressTitle,
        controller: progress,
        work: running,
      );
      if (!mounted || outcome == null) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _RestoreSummaryDialog(outcome: outcome),
      );
    } on BackupCancelledException {
      if (mounted) showWeftMessage(context, l10n.backupRestoreCancelled);
    } on Object catch (error) {
      if (mounted) showWeftMessage(context, _describeFailure(context, error));
    }
  }

  // ---------------------------------------------------------------- plumbing

  /// Shows a modal progress dialog until [work] settles, then closes it.
  ///
  /// The dialog is dismissed in a `finally` and by a route reference captured
  /// before the await, not by `Navigator.pop` afterwards: an export that fails
  /// while the user has already navigated away would otherwise pop whatever
  /// they are looking at now.
  Future<T?> _runWithProgress<T>({
    required String title,
    required _ProgressController controller,
    required Future<T> work,
  }) async {
    final navigator = Navigator.of(context);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(title: title, controller: controller),
    );
    unawaited(navigator.push(route));

    try {
      return await work;
    } finally {
      if (route.isActive) navigator.removeRoute(route);
      controller.dispose();
    }
  }
}

/// The sentence for [error], in the user's language.
///
/// Every branch is a distinct piece of advice, which is the entire reason
/// `weft_backup` returns typed failures rather than one exception: "you picked
/// the wrong file", "update Sennit", "check the passphrase" and "this copy is
/// damaged, try another" are four different next actions, and a single
/// "could not restore" would be none of them.
String _describeFailure(BuildContext context, Object error) {
  final l10n = context.l10n;
  return switch (error) {
    NotAnArchiveFailure() => l10n.backupErrorNotAnArchive,
    MalformedArchiveFailure() => l10n.backupErrorMalformed,
    UnsupportedVersionFailure(:final version) =>
      l10n.backupErrorUnsupportedVersion(version.toString()),
    WrongPassphraseFailure() => l10n.backupErrorWrongPassphrase,
    TruncatedArchiveFailure() => l10n.backupErrorTruncated,
    DamagedArchiveFailure() => l10n.backupErrorDamaged,
    _ => l10n.backupErrorUnknown,
  };
}

/// Progress and cancellation, shared between the dialog and the work.
///
/// A `ChangeNotifier` rather than `setState` on the screen: the dialog is a
/// route of its own, and rebuilding the settings list forty times a second to
/// move a bar inside it would be work nobody sees.
class _ProgressController extends ChangeNotifier {
  BackupProgress? progress;
  bool cancelled = false;

  void report(BackupProgress value) {
    progress = value;
    notifyListeners();
  }

  void cancel() {
    cancelled = true;
    notifyListeners();
  }

  Future<bool> shouldContinue() async => !cancelled;
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title, required this.controller});

  final String title;
  final _ProgressController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final progress = controller.progress;
          final fraction = progress?.fraction;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A live region, because this is a label that changes on a
              // surface the reader is already on — the case the `announce`
              // channel is explicitly not for.
              Semantics(
                liveRegion: true,
                label: context.l10n.backupProgressSemantics(
                  progress?.records ?? 0,
                ),
                excludeSemantics: true,
                child: LinearProgressIndicator(value: fraction),
              ),
              const SizedBox(height: WeftSpace.md),
              Text(
                context.l10n.backupProgressRecords(progress?.records ?? 0),
                style: context.text.bodySmall,
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: controller.cancel,
          child: Text(context.l10n.commonCancel),
        ),
      ],
    );
  }
}

/// Asks for a passphrase twice, and says what losing it costs.
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final value = _first.text;

    // Length before match: told both at once, someone fixes the mismatch and
    // is then told the result is too short, which reads as the dialog moving
    // the goalposts.
    if (value.length < kMinBackupPassphraseLength) {
      setState(() => _error = l10n.backupPassphraseTooShort);
      return;
    }
    if (value != _second.text) {
      setState(() => _error = l10n.backupPassphraseMismatch);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.backupPassphraseTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The same red box the privacy gates use, and for a comparable
            // reason: this is the one sentence that must have been on screen
            // before the button can be pressed.
            PrivacyNotice(message: l10n.backupNoRecoveryWarning),
            const SizedBox(height: WeftSpace.md),
            Text(l10n.backupPassphraseBody),
            const SizedBox(height: WeftSpace.md),
            TextField(
              controller: _first,
              autofocus: true,
              obscureText: true,
              decoration: _dialogFieldDecoration(
                context,
                label: l10n.backupPassphraseLabel,
                helperText: l10n.backupPassphraseHelper(
                  kMinBackupPassphraseLength,
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.md),
            TextField(
              controller: _second,
              obscureText: true,
              decoration: _dialogFieldDecoration(
                context,
                label: l10n.backupPassphraseConfirmLabel,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.backupExportStart)),
      ],
    );
  }
}

/// The passphrase step of a restore. One field — there is nothing to confirm
/// against, and a second box would only make a correct passphrase harder to
/// type.
class _RestorePassphraseDialog extends StatefulWidget {
  const _RestorePassphraseDialog();

  @override
  State<_RestorePassphraseDialog> createState() =>
      _RestorePassphraseDialogState();
}

class _RestorePassphraseDialogState extends State<_RestorePassphraseDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.backupRestorePassphraseTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupRestorePassphraseBody),
          const SizedBox(height: WeftSpace.md),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: _dialogFieldDecoration(
              context,
              label: l10n.backupPassphraseLabel,
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.backupRestoreContinue),
        ),
      ],
    );
  }
}

/// What the header says, shown before the passphrase is asked for.
class _ArchivePreviewDialog extends StatelessWidget {
  const _ArchivePreviewDialog({required this.archive});

  final PickedArchive archive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = archive.preview;
    final date = MaterialLocalizations.of(
      context,
    ).formatFullDate(preview.createdAt.toLocal());

    return AlertDialog(
      title: Text(l10n.backupRestorePreviewTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(archive.fileName, style: context.text.titleSmall),
          const SizedBox(height: WeftSpace.md),
          Text(l10n.backupRestorePreviewCreated(date)),
          Text(
            l10n.backupEstimateContents(
              preview.chatCount,
              preview.messageCount,
            ),
          ),
          Text(
            preview.mediaIncluded
                ? l10n.backupRestorePreviewMediaIncluded
                : l10n.backupRestorePreviewMediaExcluded,
          ),
          if (preview.appVersion.isNotEmpty)
            Text(l10n.backupRestorePreviewVersion(preview.appVersion)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.backupRestoreContinue),
        ),
      ],
    );
  }
}

/// Merge or replace, with the manifest above it as the last thing seen before
/// anything is written.
class _RestoreModeDialog extends StatefulWidget {
  const _RestoreModeDialog({required this.manifest});

  final ArchiveManifest manifest;

  @override
  State<_RestoreModeDialog> createState() => _RestoreModeDialogState();
}

class _RestoreModeDialogState extends State<_RestoreModeDialog> {
  ImportMode _mode = ImportMode.merge;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final networks = widget.manifest.networks;

    return AlertDialog(
      title: Text(l10n.backupRestoreModeTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (networks.isNotEmpty)
              Text(l10n.backupRestoreManifestNetworks(networks.join(', '))),
            const SizedBox(height: WeftSpace.md),
            // One `RadioGroup` ancestor rather than a `groupValue` on each
            // tile: the per-tile form is deprecated, and the ancestor is what
            // gives the pair a single semantics group a reader can move
            // through as "1 of 2" instead of as two unrelated switches.
            RadioGroup<ImportMode>(
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value!),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<ImportMode>(
                    value: ImportMode.merge,
                    title: Text(l10n.backupRestoreModeMergeTitle),
                    subtitle: Text(l10n.backupRestoreModeMergeSubtitle),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<ImportMode>(
                    value: ImportMode.replace,
                    title: Text(l10n.backupRestoreModeReplaceTitle),
                    subtitle: Text(l10n.backupRestoreModeReplaceSubtitle),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _confirm, child: Text(l10n.backupRestoreStart)),
      ],
    );
  }

  /// Replace is the one mode that can lose data, so it is asked about twice.
  Future<void> _confirm() async {
    if (_mode == ImportMode.merge) {
      Navigator.of(context).pop(ImportMode.merge);
      return;
    }

    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.backupRestoreReplaceConfirmTitle),
        content: Text(l10n.backupRestoreReplaceConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            // Both halves of the pair, not just the background: `styleFrom`
            // leaves the foreground at the filled button's default, which is
            // `onPrimary` — a colour chosen to sit on the seed, not on error.
            // On the error container it lands as dark red on light red, which
            // is the one button in Sennit that deletes messages rendered in the
            // lowest contrast on the screen.
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.backupRestoreReplaceConfirmAction),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      Navigator.of(context).pop(ImportMode.replace);
    }
  }
}

/// What the restore actually did.
class _RestoreSummaryDialog extends StatelessWidget {
  const _RestoreSummaryDialog({required this.outcome});

  final ImportOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.backupRestoreSummaryTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupRestoreSummaryApplied(outcome.applied)),
          if (outcome.skippedExisting > 0)
            Text(l10n.backupRestoreSummarySkipped(outcome.skippedExisting)),
          if (outcome.mediaWritten > 0)
            Text(l10n.backupRestoreSummaryMedia(outcome.mediaWritten)),
          // Said out loud rather than swallowed. An archive from a newer Sennit
          // carrying something this build cannot store is a real gap, and a
          // user who believes they have a complete copy when they do not is
          // exactly who this feature exists to protect.
          if (!outcome.isComplete) ...[
            const SizedBox(height: WeftSpace.md),
            Text(
              l10n.backupRestoreSummaryUnknown(outcome.skippedUnknownType),
              style: context.text.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonDone),
        ),
      ],
    );
  }
}
