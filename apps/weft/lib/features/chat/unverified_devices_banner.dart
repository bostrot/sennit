import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart' show RoomTrust;

import '../../app/localisation.dart';

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

    // Two different facts wearing one coat of paint, until now.
    //
    // An unverified device *of your own* is a problem you can fix in two taps,
    // and it means Braid cannot promise your messages are only reaching you.
    // Someone else's unverified device is neither: it is the ordinary state of
    // every Matrix contact you have not personally verified, there is no
    // action in this app that resolves it, and their phone count is theirs to
    // change. Painting the second one red and unclearable — eight devices,
    // permanently, with no button — is how a warning stops being read at all,
    // including the one that matters.
    final own = trust.includesOwnDevice;
    final devices = trust.unverifiedDevices;
    final people = trust.unverifiedUsers;
    final message = own
        ? context.l10n.chatUnverifiedOwnDevice
        : context.l10n.chatUnverifiedOtherDevices(devices, people);

    // A live region, because the strip *appearing* is the event. It arrives in
    // response to a trust change — someone in the room signed in on a new
    // phone — and a reader who is already in the composer gets no other sign
    // that what they are about to send has grown a new audience.
    //
    // `explicitChildNodes` keeps the Verify button reachable underneath the
    // announcement: the warning has to be read *before* the control, and the
    // control still has to be a control.
    return Semantics(
      liveRegion: true,
      container: true,
      explicitChildNodes: true,
      label: message,
      child: Material(
        // Error red for the one case with something to do about it; the
        // surface's own quiet container for the statement of fact.
        color: own
            ? context.colors.errorContainer
            : context.colors.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.lg,
            vertical: WeftSpace.sm,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  own ? Icons.gpp_maybe_rounded : Icons.lock_outline_rounded,
                  size: own ? 20 : 16,
                  color: own
                      ? context.colors.onErrorContainer
                      : context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: WeftSpace.md),
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    message,
                    style:
                        (own ? context.text.bodySmall : context.text.labelSmall)
                            ?.copyWith(
                              color: own
                                  ? context.colors.onErrorContainer
                                  : context.colors.onSurfaceVariant,
                            ),
                  ),
                ),
              ),
              if (own) ...[
                const SizedBox(width: WeftSpace.sm),
                // "Verify" alone is a verb with no object once it is read out
                // of the strip it sits in.
                Semantics(
                  label: context.l10n.chatVerifyYourDevice,
                  button: true,
                  excludeSemantics: true,
                  onTap: onVerify,
                  child: TextButton(
                    onPressed: onVerify,
                    style: TextButton.styleFrom(
                      foregroundColor: context.colors.onErrorContainer,
                    ),
                    child: Text(context.l10n.commonVerify),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
