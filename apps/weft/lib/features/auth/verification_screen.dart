import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart';

import '../../app/session_providers.dart';

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
  });

  /// Invoked when the user proceeds, verified or not.
  final VoidCallback onContinue;

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

  @override
  void dispose() {
    _verification?.cancel();
    super.dispose();
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
      verification.onUpdate = () {
        if (mounted) setState(() {});
      };
      setState(() => _verification = verification);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.read(matrixSessionProvider);
    final verification = _verification;

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
                      ? 'Verify this device'
                      : 'Verify ${widget.deviceId}',
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.sm),
                Text(
                  widget.deviceId != null
                      ? 'Compare the emoji below on both devices. Once they '
                            'match, each trusts the other and your encrypted '
                            'chats stop warning about it.'
                      : session.crossSigningExists
                      ? 'Confirm it is really you from a device you already '
                            'use. Until you do, Weft cannot read messages sent '
                            'before this device signed in.'
                      : 'This is your first device. Setting up encryption now '
                            'means you can verify future devices and recover your '
                            'messages if you lose this one.',
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: WeftSpace.xl),

                if (verification != null)
                  _VerificationBody(
                    verification: verification,
                    onDone: widget.onContinue,
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

                if (verification == null)
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
                          ? 'Verify with another device'
                          : 'Start verification',
                    ),
                  ),

                const SizedBox(height: WeftSpace.sm),
                TextButton(
                  onPressed: widget.onContinue,
                  child: Text(
                    widget.deviceId == null
                        ? 'Continue without verifying'
                        : 'Not now',
                  ),
                ),
                Text(
                  'You can verify later from Settings.',
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
  const _VerificationBody({required this.verification, required this.onDone});

  final KeyVerification verification;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return switch (verification.state) {
      KeyVerificationState.waitingAccept => const _Waiting(
        message: 'Waiting for your other device to accept…',
      ),
      KeyVerificationState.askAccept => _Prompt(
        message: 'Your other device wants to verify this one.',
        confirmLabel: 'Accept',
        onConfirm: verification.acceptVerification,
        onReject: verification.rejectVerification,
      ),
      KeyVerificationState.askSas || KeyVerificationState.waitingSas =>
        _EmojiCompare(verification: verification),
      KeyVerificationState.done => _Result(
        icon: Icons.check_circle_rounded,
        message: 'This device is verified. Your history is unlocking now.',
        onDone: onDone,
        success: true,
      ),
      KeyVerificationState.error => _Result(
        icon: Icons.error_rounded,
        message: 'Verification failed or was cancelled.',
        onDone: onDone,
        success: false,
      ),
      _ => const _Waiting(message: 'Working…'),
    };
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
          'Do these appear, in this order, on your other device?',
          textAlign: TextAlign.center,
          style: context.text.bodyMedium,
        ),
        const SizedBox(height: WeftSpace.lg),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: WeftSpace.md,
          runSpacing: WeftSpace.md,
          children: [
            for (final emoji in emojis)
              Container(
                width: 74,
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
                    Text(emoji.emoji, style: const TextStyle(fontSize: 30)),
                    const SizedBox(height: WeftSpace.xs),
                    Text(
                      emoji.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelSmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: WeftSpace.xl),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: verification.rejectSas,
                child: const Text("They don't match"),
              ),
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: FilledButton(
                onPressed: verification.acceptSas,
                child: const Text('They match'),
              ),
            ),
          ],
        ),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.lg),
      child: Column(
        children: [
          const SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: WeftSpace.md),
          Text(message, style: context.text.bodySmall),
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
                child: const Text('Reject'),
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
        FilledButton(onPressed: onDone, child: const Text('Continue')),
        const SizedBox(height: WeftSpace.lg),
      ],
    );
  }
}
