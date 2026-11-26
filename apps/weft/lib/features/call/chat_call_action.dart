import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_call/weft_call.dart' show CallBlocked, CallBlocker;
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/call_providers.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart' show kRemoteClient;
import 'external_call.dart';
import 'start_call.dart';

/// A conversation's call verb: what it looks like, what it says, what it does.
///
/// A null [onPressed] is a call that cannot be placed, drawn disabled with the
/// reason as its [tooltip].
typedef ChatCallAction = ({
  IconData icon,
  String tooltip,
  VoidCallback? onPressed,
});

/// The call verb for [chat], or null where there is none to draw.
///
/// Shared by the chat's bar and the contact profile, so a call is offered on
/// both or on neither, and reaches the same place from either.
///
/// Disabled rather than hidden, with the reason in its tooltip: a
/// conversation with no Matrix-native leg cannot carry a call, and a button
/// that quietly disappeared for bridged chats would read as Sennit having lost
/// the feature.
ChatCallAction? chatCallAction(BuildContext context, WidgetRef ref, Chat chat) {
  final availability = ref.watch(callAvailabilityProvider(chat.id));
  final target = availability.target;
  // Sennit Web places no calls of its own; only the hand-off to the network's
  // app or the dialler below works from a browser.
  if (target != null) {
    if (kRemoteClient) return null;
    return (
      tooltip: context.l10n.callAvailability(availability),
      icon: Icons.call_rounded,
      onPressed: () => startCall(context, ref, target),
    );
  }
  // No Matrix leg to call over — the call lives in the network's own app, so
  // the button opens the conversation there (or the dialler, when all Weft
  // knows is a number) instead of sitting greyed out under a tooltip
  // explaining itself. Only for the *bridged* refusal: a group is refused as a
  // group whatever apps its members are on.
  final ChatCallAction? disabled = kRemoteClient
      ? null
      : (
          tooltip: context.l10n.callAvailability(availability),
          icon: Icons.call_rounded,
          onPressed: null,
        );
  if (availability is! CallBlocked ||
      availability.reason != CallBlocker.bridged) {
    return disabled;
  }
  final contact = chat.contactId == null
      ? null
      : ref
            .read(chatRepositoryProvider)
            .identityGraph
            .contacts()
            .where((c) => c.id == chat.contactId)
            .firstOrNull;
  final external = externalCallRouteFor(context.l10n, chat, contact);
  if (external == null) return disabled;
  return (
    tooltip: external.label,
    icon: Icons.phone_forwarded_rounded,
    onPressed: () async {
      final opened = await launchUrl(
        external.uri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        showWeftMessage(context, context.l10n.chatCallNoHandler);
      }
    },
  );
}
