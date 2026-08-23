import 'package:weft_domain/weft_domain.dart';

/// Where a bridged conversation's call actually happens.
///
/// Braid's own calls ride Matrix, and a bridged contact's ghost will never
/// answer an `m.call.invite` — the call has to happen in the network's own
/// app. This resolves the deep link that gets the user there: the contact in
/// WhatsApp, the number in Signal, and failing anything better, the dialler.
class ExternalCallRoute {
  const ExternalCallRoute({required this.uri, required this.label});

  final Uri uri;

  /// Button/tooltip text: "Call in WhatsApp", "Call +49 171 …".
  final String label;
}

/// The best external route for [chat], or null when there is nothing to open.
///
/// Preference order is the chat's own: the active send network first, then the
/// other bridged legs, then a bare phone number for the dialler. A Matrix-native
/// chat returns null — the in-app call button already handles it.
ExternalCallRoute? externalCallRouteFor(Chat chat, UnifiedContact? contact) {
  final ordered = <ChatNetwork>[
    if (chat.sendNetwork != null) chat.sendNetwork!,
    ...chat.networks,
  ];

  String? anyPhone;
  for (final network in ordered) {
    final handle = contact?.handleFor(network);
    final phone = handle?.phoneE164;
    anyPhone ??= phone;

    final route = _routeFor(network, phone: phone, remoteId: handle?.remoteId);
    if (route != null) return route;
  }

  if (anyPhone != null) {
    return ExternalCallRoute(
      uri: Uri.parse('tel:$anyPhone'),
      label: 'Call $anyPhone',
    );
  }
  return null;
}

ExternalCallRoute? _routeFor(
  ChatNetwork network, {
  String? phone,
  String? remoteId,
}) {
  switch (network) {
    case ChatNetwork.whatsapp:
      // wa.me opens the conversation with the call button one tap away —
      // WhatsApp exposes no public start-a-call intent.
      final digits = phone?.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits == null || digits.isEmpty) return null;
      return ExternalCallRoute(
        uri: Uri.parse('https://wa.me/$digits'),
        label: 'Call in WhatsApp',
      );
    case ChatNetwork.signal:
      if (phone == null) return null;
      return ExternalCallRoute(
        uri: Uri.parse('https://signal.me/#p/$phone'),
        label: 'Call in Signal',
      );
    case ChatNetwork.telegram:
      // Telegram ids are not phone numbers; a phone is only known when the
      // contact was matched by one.
      if (phone == null) return null;
      return ExternalCallRoute(
        uri: Uri.parse('https://t.me/$phone'),
        label: 'Call in Telegram',
      );
    case ChatNetwork.sms || ChatNetwork.gmessages:
      final number = phone ?? remoteId;
      if (number == null || number.isEmpty) return null;
      return ExternalCallRoute(
        uri: Uri.parse('tel:$number'),
        label: 'Call $number',
      );
    default:
      return null;
  }
}
