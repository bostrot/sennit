import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/session_providers.dart';
import 'settings_section.dart';

/// The recovery key, and what happens to your history without one.
///
/// Everything on this screen exists to make one fact arrive before it is
/// needed: Matrix keeps no copy of the keys that decrypt your messages, so a
/// homeserver cannot hand your history back the way every other messenger
/// would. The recovery key is the only substitute, it is shown exactly once,
/// and an account with neither a backup nor a second signed-in device is one
/// dropped phone away from losing everything. That last case is called out in
/// as many words rather than left to be inferred from an absent tick.
class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

/// Which of the screen's four faces is showing.
///
/// A step field rather than four routes: the setup steps are only meaningful in
/// order, and a key on a route the user can navigate back to is a key that can
/// be reached again after they said they had saved it.
enum _Stage { status, showKey, confirmKey, restore }

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  KeyBackupStatus? _status;
  int _otherDevices = 0;
  String? _error;
  bool _busy = false;

  _Stage _stage = _Stage.status;

  /// The key just created, held only until the user confirms they have it.
  String? _newKey;
  String? _stepError;

  final TextEditingController _entry = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await ref.read(keyBackupProvider).status();
      // The device count is what separates "no backup, but your laptop can
      // vouch for a new phone" from "no backup and nothing else". It comes from
      // the same list the devices screen shows rather than a second count of
      // its own.
      final devices = await ref.read(deviceManagerProvider).devices();
      if (!mounted) return;
      setState(() {
        _status = status;
        _otherDevices = devices.where((device) => !device.isCurrent).length;
      });
    } catch (error) {
      // Deliberately broad, as on the devices screen: a session that was never
      // initialised throws a StateError rather than an Exception, and "not
      // signed in" must render as a message instead of as a healthy account
      // with nothing in it.
      if (!mounted) return;
      setState(() => _error = _sentence(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _sentence(Object error) {
    final raw = error.toString();
    // The SDK reports an unreachable or erroring homeserver as a bare
    // "http error response" (a 502 from a restarting reverse proxy, most
    // often). Say what that means and what to do about it.
    if (raw.contains('http error response') ||
        raw.contains('SocketException') ||
        raw.contains('Connection closed') ||
        raw.contains('has not connection')) {
      return context.l10n.devicesUnreachableHomeserver;
    }
    return switch (error) {
      KeyBackupException(:final message) => message,
      DeviceActionException(:final message) => message,
      _ => raw,
    };
  }

  void _say(String message) {
    // "Recovery key saved", "Restored" and every failure below reach the user
    // through this and nothing else — the screen just goes back to its status
    // page looking exactly as it did before.
    showWeftMessage(context, message);
  }

  /// Moves to [next] and says where the user now is.
  ///
  /// Each stage replaces the whole body with a different one — a key to write
  /// down, a field to type it back into, a field to restore from. Nothing about
  /// that swap is announced, so a reader who pressed a button is left on a page
  /// that has silently become a different page, with the focus wherever the old
  /// one left it. [heading] is the sentence the new stage would have led with.
  void _goTo(_Stage next, String heading, {VoidCallback? also}) {
    setState(() {
      _stage = next;
      also?.call();
    });
    announce(context, heading);
  }

  Future<void> _setUp({required bool replaceExisting}) async {
    if (replaceExisting) {
      final confirmed = await _confirmReplace();
      if (!confirmed || !mounted) return;
    }

    final l10n = context.l10n;
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: l10n.securityPassphraseTitle,
        message: l10n.securityPassphraseMessage,
        fieldLabel: l10n.securityPassphraseField,
        confirmLabel: l10n.commonContinue,
        helperText: l10n.securityPassphraseHelper,
      ),
    );
    // Backing out of the passphrase prompt cancels the whole setup: it is the
    // last step before keys are minted and uploaded, so treating a dismissal as
    // "no passphrase, carry on" would set recovery up on a shrug.
    if (passphrase == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final key = await ref
          .read(keyBackupProvider)
          .createRecovery(
            passphrase: passphrase.trim().isEmpty ? null : passphrase.trim(),
            replaceExisting: replaceExisting,
          );
      if (!mounted) return;
      _goTo(
        _Stage.showKey,
        l10n.securityAnnounceShowKey,
        also: () {
          _newKey = key;
          _stepError = null;
          _entry.clear();
        },
      );
    } catch (error) {
      if (mounted) _say(_sentence(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.securityReplaceTitle),
        content: Text(context.l10n.securityReplaceMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.securityReplace),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _confirmSaved() async {
    final expected = _newKey;
    if (expected == null) return;

    if (!recoveryKeyMatches(_entry.text, expected)) {
      setState(() => _stepError = context.l10n.securityWrongKey);
      return;
    }

    setState(() {
      _newKey = null;
      _stepError = null;
      _stage = _Stage.status;
      _entry.clear();
    });
    _say(context.l10n.securityKeySaved);
    await _load();
  }

  Future<void> _restore() async {
    final input = _entry.text.trim();
    if (input.isEmpty) {
      setState(() => _stepError = context.l10n.securityEnterKeyOrPassphrase);
      return;
    }

    setState(() {
      _busy = true;
      _stepError = null;
    });
    try {
      await ref.read(keyBackupProvider).restore(input);
      if (!mounted) return;
      setState(() {
        _stage = _Stage.status;
        _entry.clear();
      });
      _say(context.l10n.securityRestored);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _stepError = _sentence(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.securityTitle),
        actions: [
          if (_stage == _Stage.status)
            IconButton(
              tooltip: context.l10n.commonRefresh,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy ? null : _load,
            ),
        ],
      ),
      body: switch (_stage) {
        _Stage.status => _statusBody(context),
        _Stage.showKey => _showKeyBody(context),
        _Stage.confirmKey => _confirmKeyBody(context),
        _Stage.restore => _restoreBody(context),
      },
    );
  }

  Widget _statusBody(BuildContext context) {
    if (_error case final message?) {
      return SettingsMessage(message: message, onRetry: _busy ? null : _load);
    }
    final status = _status;
    if (status == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final risk = recoveryRiskFrom(
      state: status.state,
      otherDeviceCount: _otherDevices,
    );

    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        SettingsSectionHeader(
          title: context.l10n.securityRecoveryTitle,
          subtitle: context.l10n.securityRecoverySubtitle,
        ),
        const SizedBox(height: WeftSpace.md),
        _StatusCard(status: status),
        if (riskMessage(context.l10n, risk) case final message?) ...[
          const SizedBox(height: WeftSpace.lg),
          if (risk == RecoveryRisk.unrecoverable)
            PrivacyNotice(message: message)
          else
            _Note(message: message),
        ],
        const SizedBox(height: WeftSpace.lg),
        if (!status.state.exists)
          FilledButton.icon(
            onPressed: _busy ? null : () => _setUp(replaceExisting: false),
            icon: const Icon(Icons.key_rounded, size: 18),
            label: Text(context.l10n.securitySetUpKey),
          ),
        if (status.state == KeyBackupState.locked) ...[
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _goTo(
                    _Stage.restore,
                    context.l10n.securityEnterKeyOrPassphrase,
                    also: () {
                      _stepError = null;
                      _entry.clear();
                    },
                  ),
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: Text(context.l10n.securityEnterKey),
          ),
          const SizedBox(height: WeftSpace.sm),
        ],
        if (status.state.exists)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: context.colors.error,
            ),
            onPressed: _busy ? null : () => _setUp(replaceExisting: true),
            icon: const Icon(Icons.autorenew_rounded, size: 18),
            label: Text(context.l10n.securityReplaceKeyButton),
          ),
      ],
    );
  }

  Widget _showKeyBody(BuildContext context) {
    final key = _newKey;
    if (key == null) return const SizedBox.shrink();

    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        SettingsSectionHeader(
          title: context.l10n.securityYourKeyTitle,
          subtitle: context.l10n.securityYourKeySubtitle,
        ),
        const SizedBox(height: WeftSpace.lg),
        Container(
          padding: const EdgeInsets.all(WeftSpace.md),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allMd,
          ),
          // Spelled out. This is the one string in Sennit a user has to
          // reproduce character for character and will never be shown again,
          // and as a single monospace run a screen reader announced it as one
          // word — which makes the screen whose entire purpose is "write this
          // down" the screen a blind user cannot complete. `letterSpacing` is
          // the sighted half of the same intent.
          child: Semantics(
            label: context.l10n.securityKeySpelledOut(
              spelledOut(formatRecoveryKey(key)),
            ),
            excludeSemantics: true,
            child: SelectableText(
              formatRecoveryKey(key),
              key: const Key('recovery-key'),
              style: context.text.titleMedium?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: WeftSpace.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () async {
              final copied = context.l10n.securityKeyCopied;
              await Clipboard.setData(ClipboardData(text: key));
              if (mounted) _say(copied);
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(context.l10n.commonCopy),
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: () => _goTo(
            _Stage.confirmKey,
            context.l10n.securityAnnounceConfirmKey,
            also: () {
              _stepError = null;
              _entry.clear();
            },
          ),
          child: Text(context.l10n.securityIHaveSavedIt),
        ),
      ],
    );
  }

  Widget _confirmKeyBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        SettingsSectionHeader(
          title: context.l10n.securityCheckTitle,
          subtitle: context.l10n.securityCheckSubtitle,
        ),
        const SizedBox(height: WeftSpace.lg),
        TextField(
          controller: _entry,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          decoration: InputDecoration(
            labelText: context.l10n.securityKeyField,
            helperText: context.l10n.securitySpacingHelper,
          ),
        ),
        if (_stepError case final message?) ...[
          const SizedBox(height: WeftSpace.md),
          _ErrorBox(message: message),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: _confirmSaved,
          child: Text(context.l10n.commonConfirm),
        ),
        const SizedBox(height: WeftSpace.sm),
        TextButton(
          onPressed: () => _goTo(
            _Stage.showKey,
            context.l10n.securityAnnounceShowAgain,
            also: () => _stepError = null,
          ),
          child: Text(context.l10n.securityShowAgain),
        ),
      ],
    );
  }

  Widget _restoreBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        SettingsSectionHeader(
          title: context.l10n.securityRestoreTitle,
          subtitle: context.l10n.securityRestoreSubtitle,
        ),
        const SizedBox(height: WeftSpace.lg),
        TextField(
          controller: _entry,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: context.l10n.securityKeyOrPassphraseField,
          ),
        ),
        if (_stepError case final message?) ...[
          const SizedBox(height: WeftSpace.md),
          _ErrorBox(message: message),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: _busy ? null : _restore,
          child: Text(context.l10n.securityRestore),
        ),
        const SizedBox(height: WeftSpace.sm),
        TextButton(
          onPressed: _busy
              ? null
              : () => _goTo(
                  _Stage.status,
                  context.l10n.securityAnnounceCancelled,
                  also: () {
                    _stepError = null;
                    _entry.clear();
                  },
                ),
          child: Text(context.l10n.commonCancel),
        ),
      ],
    );
  }
}

/// The badge sentence for a backup state.
///
/// Public for the same reason `trustLabel` is: the security screen, a future
/// status row and any golden that pins them must not invent three names for
/// "there is no backup".
String backupLabel(AppL10n l10n, KeyBackupState state) => switch (state) {
  KeyBackupState.absent => l10n.backupStateAbsent,
  KeyBackupState.locked => l10n.backupStateLocked,
  KeyBackupState.outOfDate => l10n.backupStateOutOfDate,
  KeyBackupState.upToDate => l10n.backupStateUpToDate,
};

/// What the state means, in the words the reader would use.
String backupExplanation(AppL10n l10n, KeyBackupState state) => switch (state) {
  KeyBackupState.absent => l10n.backupExplainAbsent,
  KeyBackupState.locked => l10n.backupExplainLocked,
  KeyBackupState.outOfDate => l10n.backupExplainOutOfDate,
  KeyBackupState.upToDate => l10n.backupExplainUpToDate,
};

/// The sentence for a [RecoveryRisk], or null when there is nothing to say.
String? riskMessage(AppL10n l10n, RecoveryRisk risk) => switch (risk) {
  RecoveryRisk.none => null,
  RecoveryRisk.otherDevicesOnly => l10n.backupRiskOtherDevices,
  RecoveryRisk.unrecoverable => l10n.backupRiskUnrecoverable,
};

/// The backup at a glance: what it is, and what it means.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final KeyBackupStatus status;

  @override
  Widget build(BuildContext context) {
    final colour = switch (status.state) {
      KeyBackupState.upToDate => context.palette.online,
      KeyBackupState.outOfDate => context.colors.onSurfaceVariant,
      KeyBackupState.locked => context.colors.primary,
      KeyBackupState.absent => context.colors.error,
    };

    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(switch (status.state) {
                KeyBackupState.upToDate => Icons.cloud_done_rounded,
                KeyBackupState.outOfDate => Icons.cloud_sync_rounded,
                KeyBackupState.locked => Icons.lock_rounded,
                KeyBackupState.absent => Icons.cloud_off_rounded,
              }, color: colour),
              const SizedBox(width: WeftSpace.md),
              Expanded(
                child: Text(
                  backupLabel(context.l10n, status.state),
                  style: context.text.titleSmall?.copyWith(
                    color: colour,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(
            backupExplanation(context.l10n, status.state),
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          if (status.state.exists) ...[
            const SizedBox(height: WeftSpace.sm),
            Text(
              context.l10n.securityBackupDetail(
                context.l10n.securityKeyCount(status.keyCount),
                switch (status.version) {
                  final version? =>
                    ' · ${context.l10n.securityBackupVersion(version)}',
                  null => '',
                },
                ' · ${status.crossSigningEnabled ? context.l10n.securityCrossSigningOn : context.l10n.securityCrossSigningOff}',
              ),
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A quiet advisory. Not a [PrivacyNotice] — that box is red because something
/// is about to leave the device, and spending it on "you could be safer" is how
/// a warning colour stops being read.
class _Note extends StatelessWidget {
  const _Note({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: WeftSpace.md),
          Expanded(
            child: Semantics(
              // Named as advice rather than left as prose: the grey box and the
              // info glyph are the whole signal that this is a suggestion, and
              // both are invisible to a reader.
              label: context.l10n.securitySuggestionSemantics(message),
              excludeSemantics: true,
              child: Text(
                message,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    // Live: this box is how a mistyped recovery key is reported, and it appears
    // in place with the focus still on the field or the button that produced
    // it. Without it the user presses Confirm, hears nothing, and has no reason
    // to think anything but that the button is broken.
    return Semantics(liveRegion: true, child: _box(context));
  }

  Widget _box(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.errorContainer,
        borderRadius: WeftRadius.allMd,
      ),
      child: Text(
        message,
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onErrorContainer,
        ),
      ),
    );
  }
}
