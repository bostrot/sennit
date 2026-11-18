import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/session_providers.dart';
import '../components/qr_card.dart';
import '../components/qr_scanner.dart';

/// Verifies this device against one the user already trusts.
///
/// This is deliberately a full screen rather than a dismissible banner. An
/// unverified device cannot decrypt anything sent before it joined, and a user
/// who skips past a notice will conclude that Weft "lost" their history. Saying
/// so plainly here is cheaper than the support conversation later.
class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({
    super.key,
    required this.onContinue,
    this.deviceId,
    this.incoming,
  });

  /// Invoked when the user proceeds, verified or not.
  final VoidCallback onContinue;

  /// A verification the *other* device started — Element on the laptop
  /// asking this phone to confirm. Non-null skips the start button: the
  /// request is already on the table and the first step is accepting it.
  final KeyVerification? incoming;

  /// Which device to verify against, or null to ask *every* other device —
  /// which is what a fresh login wants, since whichever one the user is holding
  /// can answer.
  ///
  /// Set from the devices screen, where the user has already picked the session
  /// they mean. Same flow, same machinery; only the addressee differs.
  final String? deviceId;

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  KeyVerification? _verification;
  String? _error;
  bool _starting = false;

  /// Whether the user chose to type their recovery key rather than bring in
  /// another device.
  bool _usingRecoveryKey = false;

  @override
  void initState() {
    super.initState();
    final incoming = widget.incoming;
    if (incoming != null) _attach(incoming);
  }

  @override
  void dispose() {
    _verification?.cancel();
    super.dispose();
  }

  /// Wires [verification] into this screen — ours or the other side's.
  void _attach(KeyVerification verification) {
    verification.onUpdate = () {
      if (!mounted) return;
      setState(() {});
      // Every step of this flow replaces the body with a different one, and
      // several of the transitions are driven by the *other* device rather
      // than by anything the user here did. Without this, a screen-reader
      // user watching for emoji to compare is given a page that quietly
      // became the emoji page while they were still on the previous one.
      final next = verification.state;
      if (next == _announcedState) return;
      _announcedState = next;
      announce(context, verificationStateLabel(next));
    };
    _verification = verification;
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final verification = await ref
          .read(matrixSessionProvider)
          .startVerification(deviceId: widget.deviceId);
      if (verification == null) {
        setState(
          () => _error = widget.deviceId == null
              ? 'No other device is available to verify with.'
              : 'That device has not published any encryption keys, so there '
                    'is nothing to verify against.',
        );
        return;
      }
      setState(() => _attach(verification));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Swaps the device flow for the recovery-key field.
  ///
  /// A request nobody has answered is withdrawn first: left open, a device
  /// that accepts it later would be talking to a screen that has moved on.
  void _useRecoveryKey() {
    final pending = _verification;
    pending?.onUpdate = null;
    pending?.cancel();
    setState(() {
      _verification = null;
      _error = null;
      _usingRecoveryKey = true;
    });
    announce(context, context.l10n.securityEnterKeyOrPassphrase);
  }

  /// Reads the other device's code and hands its bytes to the SDK.
  ///
  /// The scan is the whole of this side's contribution: `verifyQrData` checks
  /// the keys inside the payload against what we already hold, so a code from
  /// the wrong device fails here rather than after a user has confirmed
  /// something.
  /// The step last spoken, so a rebuild that changes nothing stays quiet.
  KeyVerificationState? _announcedState;

  Future<void> _scan(KeyVerification verification) async {
    final bytes = await ref.read(qrScannerProvider).scan(context);
    // Null is a cancelled scan, not a failure — nothing has been sent.
    if (bytes == null || !mounted) return;
    try {
      await chooseVerification(
        verification,
        VerificationChoice.scanQr,
        qrBytes: bytes,
      );
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.read(matrixSessionProvider);
    final verification = _verification;
    // The key verifies *this* device, so it is offered only where this device
    // is the one in question and the account has keys for it to unlock — and
    // only until another device has answered, after which there is a flow in
    // progress that is quicker to finish than to abandon.
    final canUseRecoveryKey =
        !_usingRecoveryKey &&
        widget.deviceId == null &&
        widget.incoming == null &&
        session.crossSigningExists &&
        session.needsVerification &&
        (verification == null ||
            verification.state == KeyVerificationState.waitingAccept);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 48,
                  color: context.colors.primary,
                ),
                const SizedBox(height: WeftSpace.lg),
                Text(
                  widget.deviceId == null
                      ? context.l10n.verifyThisDeviceTitle
                      : context.l10n.verifyNamedDeviceTitle(widget.deviceId!),
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.sm),
                Text(
                  _usingRecoveryKey
                      ? context.l10n.verifyRecoveryBody
                      : widget.deviceId != null
                      ? context.l10n.verifyOtherDeviceBody
                      : session.crossSigningExists
                      ? context.l10n.verifyExistingBody
                      : context.l10n.verifyFirstDeviceBody,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: WeftSpace.xl),

                if (_usingRecoveryKey)
                  RecoveryKeyVerification(
                    onDone: widget.onContinue,
                    onBack: () => setState(() => _usingRecoveryKey = false),
                  ),

                if (verification != null)
                  _VerificationBody(
                    verification: verification,
                    onDone: widget.onContinue,
                    canScan: ref.read(qrScannerProvider).available,
                    onScan: () => _scan(verification),
                  ),

                if (_error case final message?) ...[
                  Container(
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
                  ),
                  const SizedBox(height: WeftSpace.lg),
                ],

                if (verification == null && !_usingRecoveryKey)
                  FilledButton.icon(
                    onPressed: _starting ? null : _start,
                    icon: _starting
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: Text(
                      widget.deviceId == null
                          ? context.l10n.verifyWithAnotherDevice
                          : context.l10n.verifyStart,
                    ),
                  ),

                if (canUseRecoveryKey) ...[
                  const SizedBox(height: WeftSpace.sm),
                  OutlinedButton.icon(
                    onPressed: _starting ? null : _useRecoveryKey,
                    icon: const Icon(Icons.key_rounded, size: 18),
                    label: Text(context.l10n.verifyUseRecoveryKey),
                  ),
                ],

                const SizedBox(height: WeftSpace.sm),
                TextButton(
                  onPressed: widget.onContinue,
                  child: Text(
                    widget.deviceId == null
                        ? context.l10n.verifySkip
                        : context.l10n.commonNotNow,
                  ),
                ),
                Text(
                  context.l10n.verifyLater,
                  textAlign: TextAlign.center,
                  style: context.text.labelSmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders whichever step the verification is currently at.
class _VerificationBody extends StatelessWidget {
  const _VerificationBody({
    required this.verification,
    required this.onDone,
    required this.canScan,
    required this.onScan,
  });

  final KeyVerification verification;
  final VoidCallback onDone;

  /// Whether this build can read a code off another screen.
  final bool canScan;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return switch (verification.state) {
      KeyVerificationState.waitingAccept => _Waiting(
        message: context.l10n.verifyWaitingAccept,
      ),
      KeyVerificationState.askAccept => _Prompt(
        message: context.l10n.verifyAskAccept,
        confirmLabel: context.l10n.commonAccept,
        onConfirm: verification.acceptVerification,
        onReject: verification.rejectVerification,
      ),
      KeyVerificationState.askChoice => _Choice(
        verification: verification,
        canScan: canScan,
        onScan: onScan,
      ),
      // Cross-signing exists but its secrets are not on this device, so there
      // is nothing here to sign the other device *with* until the recovery key
      // unlocks them.
      KeyVerificationState.askSSSS => _UnlockPrompt(verification: verification),
      KeyVerificationState.askSas || KeyVerificationState.waitingSas =>
        _EmojiCompare(verification: verification),
      // We scanned their code and it checked out. They still have to confirm
      // they can see that, which is what stops a code photographed over
      // somebody's shoulder from verifying itself.
      KeyVerificationState.showQRSuccess => _Waiting(
        message: context.l10n.verifyQrSuccess,
        icon: Icons.verified_rounded,
      ),
      // They scanned ours. Confirming is a statement about the physical world,
      // so the question names what to look at rather than asking for a yes.
      KeyVerificationState.confirmQRScan => _Prompt(
        message: context.l10n.verifyConfirmQrScan,
        confirmLabel: context.l10n.verifyYesItIs,
        onConfirm: verification.acceptQRScanConfirmation,
        onReject: verification.rejectVerification,
      ),
      KeyVerificationState.done => _Result(
        icon: Icons.check_circle_rounded,
        message: context.l10n.verifyDone,
        onDone: onDone,
        success: true,
      ),
      KeyVerificationState.error => _Result(
        icon: Icons.error_rounded,
        message: context.l10n.verifyFailed,
        onDone: onDone,
        success: false,
      ),
    };
  }
}

/// Both sides are ready and the user picks how to prove it is them.
///
/// The QR code is rendered rather than offered behind a button: showing it
/// sends nothing, costs nothing, and is the option that works when only one of
/// the two devices has a camera — which is the usual case, since one of them is
/// generally a laptop.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.verification,
    required this.canScan,
    required this.onScan,
  });

  final KeyVerification verification;
  final bool canScan;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final choices = verificationChoices(verification.possibleMethods);
    final qrBytes = verificationQrBytes(verification);
    final showQr = choices.contains(VerificationChoice.showQr);

    return Column(
      children: [
        if (showQr && qrBytes != null) ...[
          Text(
            context.l10n.verifyScanThis,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: WeftSpace.md),
          // Unlike the bridge flow there is no text fallback to point at: the
          // payload is two ed25519 keys and a shared secret, and rendering it
          // as characters would be a string nobody can read out and nothing can
          // scan. The honest label says so and names the path that does work.
          QrCard.bytes(qrBytes, semanticsLabel: context.l10n.verifyQrSemantics),
          const SizedBox(height: WeftSpace.lg),
        ],
        if (choices.contains(VerificationChoice.scanQr)) ...[
          if (canScan)
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: Text(context.l10n.verifyScanOther),
            )
          else
            Text(
              context.l10n.verifyNoCamera,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: WeftSpace.md),
        ],
        if (choices.contains(VerificationChoice.emoji))
          OutlinedButton(
            onPressed: () =>
                chooseVerification(verification, VerificationChoice.emoji),
            child: Text(
              showQr
                  ? context.l10n.verifyCompareEmojiInstead
                  : context.l10n.verifyCompareEmoji,
            ),
          ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

/// Asks for the recovery key so cross-signing can be used at all.
///
/// Stateful and owning its controller for the same reason the settings dialogs
/// are: a controller built at the call site is disposed while the widget that
/// reads it is still being rebuilt.
class _UnlockPrompt extends StatefulWidget {
  const _UnlockPrompt({required this.verification});

  final KeyVerification verification;

  @override
  State<_UnlockPrompt> createState() => _UnlockPromptState();
}

class _UnlockPromptState extends State<_UnlockPrompt> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.verification.openSSSS(
        keyOrPassphrase: _controller.text.trim(),
      );
    } catch (_) {
      // The SDK throws several unrelated types for a key that does not work,
      // and none of their messages is fit to show.
      if (mounted) {
        setState(
          () => _error =
              'That is not the recovery key or passphrase for this account.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          context.l10n.verifyUnlockBody,
          textAlign: TextAlign.center,
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: WeftSpace.md),
        TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: context.l10n.securityKeyOrPassphraseField,
          ),
        ),
        if (_error case final message?) ...[
          const SizedBox(height: WeftSpace.sm),
          // Live: a wrong recovery key leaves the field, the button and the
          // whole screen exactly as they were apart from this line.
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: _busy ? null : _unlock,
          child: Text(context.l10n.verifyUnlock),
        ),
        const SizedBox(height: WeftSpace.sm),
        TextButton(
          // Skipping still verifies the two devices against each other; what it
          // gives up is signing them into the account's chain of trust.
          onPressed: _busy
              ? null
              : () => widget.verification.openSSSS(skip: true),
          child: Text(context.l10n.verifyContinueWithoutKey),
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

/// Verifies this device with the account's recovery key, no other device
/// needed.
///
/// Public for the reason [SasEmojiCell] is: the screen around it needs a live
/// session to pump, and this — the field, the wrong-key line, the result — is
/// the part worth pumping.
class RecoveryKeyVerification extends ConsumerStatefulWidget {
  const RecoveryKeyVerification({
    super.key,
    required this.onDone,
    required this.onBack,
  });

  /// Invoked from the result once the device is verified.
  final VoidCallback onDone;

  /// Returns to verifying with another device.
  final VoidCallback onBack;

  @override
  ConsumerState<RecoveryKeyVerification> createState() =>
      _RecoveryKeyVerificationState();
}

class _RecoveryKeyVerificationState
    extends ConsumerState<RecoveryKeyVerification> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _verified = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _error = context.l10n.securityEnterKeyOrPassphrase);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(keyBackupProvider).restore(input);
      if (!mounted) return;
      setState(() => _verified = true);
      announce(context, context.l10n.verifyDone);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error) {
          KeyBackupException(:final message) => message,
          _ => context.l10n.devicesUnreachableHomeserver,
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_verified) {
      return _Result(
        icon: Icons.check_circle_rounded,
        message: context.l10n.verifyDone,
        onDone: widget.onDone,
        success: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _verify(),
          decoration: InputDecoration(
            labelText: context.l10n.securityKeyOrPassphraseField,
          ),
        ),
        if (_error case final message?) ...[
          const SizedBox(height: WeftSpace.sm),
          // Live, as in [_UnlockPrompt]: a wrong key changes nothing on the
          // screen but this line.
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: WeftSpace.lg),
        FilledButton.icon(
          onPressed: _busy ? null : _verify,
          icon: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_open_rounded, size: 18),
          label: Text(context.l10n.commonVerify),
        ),
        const SizedBox(height: WeftSpace.sm),
        OutlinedButton(
          onPressed: _busy ? null : widget.onBack,
          child: Text(context.l10n.verifyWithAnotherDevice),
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

/// The SAS emoji comparison — the step the user actually performs.
class _EmojiCompare extends StatelessWidget {
  const _EmojiCompare({required this.verification});

  final KeyVerification verification;

  @override
  Widget build(BuildContext context) {
    final emojis = verification.sasEmojis;

    return Column(
      children: [
        Text(
          context.l10n.verifyEmojiQuestion,
          textAlign: TextAlign.center,
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: WeftSpace.lg),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: WeftSpace.md,
          runSpacing: WeftSpace.md,
          children: [
            for (final (index, emoji) in emojis.indexed)
              SasEmojiCell(
                emoji: emoji.emoji,
                name: emoji.name,
                index: index,
                total: emojis.length,
              ),
          ],
        ),
        const SizedBox(height: WeftSpace.xl),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: verification.rejectSas,
                child: Text(context.l10n.verifyEmojiNoMatch),
              ),
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: FilledButton(
                onPressed: verification.acceptSas,
                child: Text(context.l10n.verifyEmojiMatch),
              ),
            ),
          ],
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

/// One cell of the SAS comparison: an emoji over the name it goes by.
///
/// Public, and a widget rather than a closure inside [_EmojiCompare], because
/// it is the only way this box is measurable. A [KeyVerification] cannot be
/// built without an `Encryption` and a live client, so the screen around it
/// cannot be pumped in a widget test at all — and SCALE-11 is a question about
/// this box and nothing else.
class SasEmojiCell extends StatelessWidget {
  const SasEmojiCell({
    super.key,
    required this.emoji,
    required this.name,
    required this.index,
    required this.total,
  });

  final String emoji;
  final String name;
  final int index;
  final int total;

  /// The design width at 1.0×, before the text scaler.
  static const double extent = 74;

  @override
  Widget build(BuildContext context) {
    // SCALE-11. The cell holds two runs of real text — a 30dp emoji and a
    // caption — so it is a box around text and scales with it. Left at 74 the
    // caption had 66dp of content width to hold two lines of 22dp type at
    // 2.0×, which ellipsised most of the names the SAS table can produce; the
    // reader is being asked to compare *these words* against another screen,
    // and "screwdri…" is not a word they can compare.
    //
    // Clamped at 1.6× rather than unclamped: the cells sit in a `Wrap` seven
    // across, and past that the row breaks into a column on a phone, which
    // loses the left-to-right order the question depends on.
    final scaler = MediaQuery.textScalerOf(context);
    final width = extent * (scaler.scale(extent) / extent).clamp(1.0, 1.6);

    return Semantics(
      container: true,
      // Position and name as one node. Seven emoji and seven captions were
      // fourteen nodes, and the *order* is half of what the user is being
      // asked to check — "do these appear, in this order" is a question a
      // reader could not answer.
      label: context.l10n.verifyEmojiCell(index + 1, total, name),
      excludeSemantics: true,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(
          vertical: WeftSpace.sm,
          horizontal: WeftSpace.xs,
        ),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHigh,
          borderRadius: WeftRadius.allMd,
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 30)),
            const SizedBox(height: WeftSpace.xs),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.message, this.icon});

  final String message;

  /// Shown instead of the spinner when the wait is for the *other* device to
  /// act and this side has already succeeded — a spinner there reads as
  /// "something might still go wrong here", which is no longer true.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.lg),
      child: Column(
        children: [
          if (icon case final icon?)
            Icon(icon, size: 32, color: context.palette.online)
          else
            const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(height: WeftSpace.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onReject,
  });

  final String message;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: WeftSpace.lg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onReject,
                child: Text(context.l10n.verifyReject),
              ),
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: FilledButton(
                onPressed: onConfirm,
                child: Text(confirmLabel),
              ),
            ),
          ],
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.icon,
    required this.message,
    required this.onDone,
    required this.success,
  });

  final IconData icon;
  final String message;
  final VoidCallback onDone;
  final bool success;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          icon,
          size: 40,
          color: success ? context.palette.online : context.colors.error,
        ),
        const SizedBox(height: WeftSpace.md),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: onDone,
          child: Text(context.l10n.commonContinue),
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

/// Where the verification has got to, in one sentence.
///
/// Public so the announcement and any future banner say the same thing: this
/// flow has nine states, several of which look almost identical on screen, and
/// two descriptions of the same step is how a user ends up comparing emoji they
/// were told to scan.
String verificationStateLabel(KeyVerificationState state) => switch (state) {
  KeyVerificationState.askAccept =>
    'Your other device wants to verify this one.',
  KeyVerificationState.waitingAccept =>
    'Waiting for your other device to accept.',
  KeyVerificationState.askChoice => 'Choose how to verify.',
  KeyVerificationState.askSSSS =>
    'Enter your recovery key or passphrase to unlock verification.',
  KeyVerificationState.askSas || KeyVerificationState.waitingSas =>
    'Compare the emoji shown here with the ones on your other device.',
  KeyVerificationState.showQRSuccess =>
    'That code checked out. Confirm it on your other device.',
  KeyVerificationState.confirmQRScan =>
    'Your other device says it scanned this code. Confirm what it shows.',
  KeyVerificationState.done =>
    'This device is verified. Your history is unlocking now.',
  KeyVerificationState.error => 'Verification failed or was cancelled.',
};
