import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/a11y.dart';
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

  static String _sentence(Object error) {
    final raw = error.toString();
    // The SDK reports an unreachable or erroring homeserver as a bare
    // "http error response" (a 502 from a restarting reverse proxy, most
    // often). Say what that means and what to do about it.
    if (raw.contains('http error response') ||
        raw.contains('SocketException') ||
        raw.contains('Connection closed') ||
        raw.contains('has not connection')) {
      return 'Your homeserver could not be reached — it may be restarting. '
          'Try again in a moment.';
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

    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const TextPromptDialog(
        title: 'Add a passphrase?',
        message:
            'A passphrase is a second way in, for the times the key itself is '
            'not to hand. It never leaves this device, and it does not replace '
            'the key.',
        fieldLabel: 'Passphrase (optional)',
        confirmLabel: 'Continue',
        helperText: 'Leave this empty to use the recovery key alone.',
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
        'Your recovery key. Write it down now — it cannot be shown again.',
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
        title: const Text('Replace the recovery key?'),
        content: const Text(
          'The old key stops working, the backup is made again from scratch, '
          'and your other devices have to be verified again. Do this if the '
          'old key is lost or somebody else has seen it — not to tidy up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
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
      setState(
        () => _stepError =
            'That is not the key that was just shown. Go back and copy it '
            'again — a single wrong character makes it useless.',
      );
      return;
    }

    setState(() {
      _newKey = null;
      _stepError = null;
      _stage = _Stage.status;
      _entry.clear();
    });
    _say('Recovery key saved. Your messages can be restored from it.');
    await _load();
  }

  Future<void> _restore() async {
    final input = _entry.text.trim();
    if (input.isEmpty) {
      setState(() => _stepError = 'Enter your recovery key or passphrase.');
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
      _say('Restored. Older messages will decrypt as they load.');
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
      appBar: AppBar(
        title: const Text('Encryption'),
        actions: [
          if (_stage == _Stage.status)
            IconButton(
              tooltip: 'Refresh',
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
        const SettingsSectionHeader(
          title: 'Message recovery',
          subtitle:
              'Your homeserver stores your messages encrypted and cannot read '
              'them. The keys that can are on your devices — and, if you set '
              'one up, in a backup only your recovery key opens.',
        ),
        const SizedBox(height: WeftSpace.md),
        _StatusCard(status: status),
        if (riskMessage(risk) case final message?) ...[
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
            label: const Text('Set up a recovery key'),
          ),
        if (status.state == KeyBackupState.locked) ...[
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _goTo(
                    _Stage.restore,
                    'Enter your recovery key or passphrase.',
                    also: () {
                      _stepError = null;
                      _entry.clear();
                    },
                  ),
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: const Text('Enter your recovery key'),
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
            label: const Text('Replace the recovery key'),
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
        const SettingsSectionHeader(
          title: 'Your recovery key',
          subtitle:
              'Write it down or put it in a password manager now. Weft cannot '
              'show it again, and nobody — not your homeserver, not us — can '
              'reissue it.',
        ),
        const SizedBox(height: WeftSpace.lg),
        Container(
          padding: const EdgeInsets.all(WeftSpace.md),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allMd,
          ),
          // Spelled out. This is the one string in Weft a user has to
          // reproduce character for character and will never be shown again,
          // and as a single monospace run a screen reader announced it as one
          // word — which makes the screen whose entire purpose is "write this
          // down" the screen a blind user cannot complete. `letterSpacing` is
          // the sighted half of the same intent.
          child: Semantics(
            label:
                'Recovery key. Copy it with the button below, or write it '
                'down: ${spelledOut(formatRecoveryKey(key))}',
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
              await Clipboard.setData(ClipboardData(text: key));
              if (mounted) _say('Recovery key copied.');
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
          ),
        ),
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: () => _goTo(
            _Stage.confirmKey,
            'Type the recovery key back in to confirm you have it.',
            also: () {
              _stepError = null;
              _entry.clear();
            },
          ),
          child: const Text('I have saved it'),
        ),
      ],
    );
  }

  Widget _confirmKeyBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        const SettingsSectionHeader(
          title: 'Check you have it',
          subtitle:
              'Paste the key back in. This is the only chance to find out that '
              'what you saved is not what Weft generated.',
        ),
        const SizedBox(height: WeftSpace.lg),
        TextField(
          controller: _entry,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'Recovery key',
            helperText: 'Spacing does not matter.',
          ),
        ),
        if (_stepError case final message?) ...[
          const SizedBox(height: WeftSpace.md),
          _ErrorBox(message: message),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton(onPressed: _confirmSaved, child: const Text('Confirm')),
        const SizedBox(height: WeftSpace.sm),
        TextButton(
          onPressed: () => _goTo(
            _Stage.showKey,
            'Your recovery key, shown again.',
            also: () => _stepError = null,
          ),
          child: const Text('Show it again'),
        ),
      ],
    );
  }

  Widget _restoreBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(WeftSpace.lg),
      children: [
        const SettingsSectionHeader(
          title: 'Restore from your backup',
          subtitle:
              'Enter the recovery key you saved, or the passphrase you set '
              'with it. This device then decrypts the history it has been '
              'missing.',
        ),
        const SizedBox(height: WeftSpace.lg),
        TextField(
          controller: _entry,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Recovery key or passphrase',
          ),
        ),
        if (_stepError case final message?) ...[
          const SizedBox(height: WeftSpace.md),
          _ErrorBox(message: message),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: _busy ? null : _restore,
          child: const Text('Restore'),
        ),
        const SizedBox(height: WeftSpace.sm),
        TextButton(
          onPressed: _busy
              ? null
              : () => _goTo(
                  _Stage.status,
                  'Cancelled. Back to your encryption settings.',
                  also: () {
                    _stepError = null;
                    _entry.clear();
                  },
                ),
          child: const Text('Cancel'),
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
String backupLabel(KeyBackupState state) => switch (state) {
  KeyBackupState.absent => 'No backup',
  KeyBackupState.locked => 'Backup locked',
  KeyBackupState.outOfDate => 'Backup out of date',
  KeyBackupState.upToDate => 'Backed up',
};

/// What the state means, in the words the reader would use.
String backupExplanation(KeyBackupState state) => switch (state) {
  KeyBackupState.absent =>
    'Nothing is stored on the server. Messages you can read today stay '
        'readable only on the devices that received them.',
  KeyBackupState.locked =>
    'A backup exists, but this device cannot open it. Enter your recovery '
        'key to unlock the history it holds.',
  KeyBackupState.outOfDate =>
    'This device is holding keys the backup does not have yet. They upload '
        'on their own; leave Weft open for a minute.',
  KeyBackupState.upToDate =>
    'Everything this device knows how to decrypt is in the backup, and your '
        'recovery key opens it on any new device.',
};

/// The sentence for a [RecoveryRisk], or null when there is nothing to say.
String? riskMessage(RecoveryRisk risk) => switch (risk) {
  RecoveryRisk.none => null,
  RecoveryRisk.otherDevicesOnly =>
    'There is no backup, but another device is signed in. It can verify a '
        'replacement and pass your keys to it — as long as you still have it. '
        'A recovery key is the version of that which survives losing them all.',
  RecoveryRisk.unrecoverable =>
    'No backup, and this is the only device signed in. If you lose it or sign '
        'out, every encrypted message you have is gone: your homeserver still '
        'has them, but nothing anywhere can decrypt them again. Nobody can '
        'undo this for you afterwards.',
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
                  backupLabel(status.state),
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
            backupExplanation(status.state),
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          if (status.state.exists) ...[
            const SizedBox(height: WeftSpace.sm),
            Text(
              [
                '${status.keyCount} keys',
                if (status.version case final version?) 'version $version',
                status.crossSigningEnabled
                    ? 'cross-signing on'
                    : 'cross-signing off',
              ].join(' · '),
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
              label: 'Suggestion. $message',
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
