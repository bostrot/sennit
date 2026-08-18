import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart' show RoomTrust;

/// Says, in the chat it applies to, that something here can read what you send
/// and has not been checked.
///
/// In the conversation rather than in settings because that is where the
/// decision is made: the moment worth interrupting is the one before a message
/// is typed, not a screen the user visits once a year. It is a strip and not a
/// dialog for the same reason — it must not be dismissible-and-forgotten, and
/// it must not stop anyone sending.
///
/// Renders nothing at all when there is nothing to say, so the caller can place
/// it unconditionally and never reason about whether a room is encrypted.
class UnverifiedDevicesBanner extends StatelessWidget {
  const UnverifiedDevicesBanner({
    super.key,
    required this.trust,
    required this.onVerify,
  });

  final RoomTrust trust;

  /// Opens the one verification flow Weft has. Only offered when one of the
  /// unverified devices is the user's own, because that is the only case with
  /// an action behind the warning — another person's new phone is theirs to
  /// verify, and a button that could not fix it would be a button that lies.
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    if (!trust.hasWarning) return const SizedBox.shrink();

    final devices = trust.unverifiedDevices;
    final message = trust.includesOwnDevice
        ? 'One of your own devices is not verified, so Weft cannot promise the '
              'messages here are only reaching you.'
        : devices == 1
        ? 'Someone in this chat is using a device nobody has verified. It can '
              'read what you send from now on.'
        : '$devices unverified devices across ${trust.unverifiedUsers} people '
              'can read what you send here.';

    return Material(
      color: context.colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.lg,
          vertical: WeftSpace.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.gpp_maybe_rounded,
              size: 20,
              color: context.colors.onErrorContainer,
            ),
            const SizedBox(width: WeftSpace.md),
            Expanded(
              child: Text(
                message,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onErrorContainer,
                ),
              ),
            ),
            if (trust.includesOwnDevice) ...[
              const SizedBox(width: WeftSpace.sm),
              TextButton(
                onPressed: onVerify,
                style: TextButton.styleFrom(
                  foregroundColor: context.colors.onErrorContainer,
                ),
                child: const Text('Verify'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
