import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import '../../app/localisation.dart';

/// The buttons a business message carried, under the words of the bubble.
///
/// Read off the bridge's text stand-in by [splitBridgeButtons]: the event says
/// nothing else about them, and nothing can be sent back that the business
/// would read as a press. So a link or call button works — it only ever went
/// somewhere — and a quick reply is shown greyed out, with the way to answer it
/// next to it: the conversation in the network's own app.
class BridgeButtonsBar extends StatelessWidget {
  const BridgeButtonsBar({
    super.key,
    required this.buttons,
    required this.senderId,
    required this.accent,
    this.onTapLink,
  });

  final List<BridgeButton> buttons;

  /// The business's Matrix id, whose phone number — when the bridge put one in
  /// it — opens the right conversation rather than the app's chat list.
  final String senderId;

  final Color accent;

  /// How a link or call button opens, the same handler the bubble's links use.
  final void Function(String url, String label)? onTapLink;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final network = ChatNetwork.whatsapp.label;
    final answersInApp = buttons.any((b) => b.answersInApp);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: WeftSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: WeftSpace.xs,
            runSpacing: WeftSpace.xs,
            children: [
              for (final button in buttons)
                if (button.url case final url?)
                  ActionChip(
                    avatar: Icon(
                      url.startsWith('tel:')
                          ? Icons.call_rounded
                          : Icons.open_in_new_rounded,
                      size: 16,
                      color: accent,
                    ),
                    label: Text(button.label),
                    side: BorderSide(color: accent.withValues(alpha: 0.5)),
                    onPressed: onTapLink == null
                        ? null
                        : () => onTapLink!(url, button.label),
                  )
                else
                  // Disabled rather than hidden: which options the business
                  // offered is part of what it said.
                  ActionChip(label: Text(button.label), onPressed: null),
            ],
          ),
          if (answersInApp)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: WeftSpace.xs),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: WeftSpace.xs,
                children: [
                  Text(
                    l10n.bridgeButtonsHint(network),
                    style: context.text.bodySmall?.copyWith(
                      color: accent.withValues(alpha: 0.8),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: accent),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text(l10n.bridgeButtonsOpenApp(network)),
                    onPressed: () => unawaited(
                      launchUrl(
                        whatsAppChatUri(senderId),
                        mode: LaunchMode.externalApplication,
                      ).onError((_, _) => false),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Where "open in WhatsApp" goes for a message from [senderId].
///
/// The bridge names its ghosts after the phone number — `@whatsapp_4930…:hs` —
/// and wa.me opens that conversation. A ghost named after anything else (a
/// hidden-number id) gets the app itself, which is the best that can be said
/// about where the conversation is.
Uri whatsAppChatUri(String senderId) {
  final digits = RegExp(r'^@\w*?whatsapp\w*?_(\d{6,15}):').firstMatch(senderId);
  return digits == null
      ? Uri.parse('whatsapp://')
      : Uri.parse('https://wa.me/${digits.group(1)}');
}
