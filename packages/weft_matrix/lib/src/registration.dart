import 'package:meta/meta.dart';

/// The interactive-auth stages registration can complete without a browser.
///
/// Everything else a server may ask for — a captcha, an emailed link, a terms
/// page — needs a web view or a second device, and a sign-up form that starts
/// one of those and cannot finish it is worse than one that says so up front.
abstract final class RegistrationStage {
  static const String dummy = 'm.login.dummy';
  static const String token = 'm.login.registration_token';

  static const Set<String> supported = {dummy, token};
}

/// What a homeserver wants from someone creating an account on it.
enum RegistrationOffer {
  /// A username and a password are enough.
  open,

  /// The server also wants a registration token — an invite code its admin
  /// hands out.
  needsToken,

  /// The server registers accounts, but only through stages this client
  /// cannot complete.
  unsupported,

  /// The server does not register accounts over this API at all.
  closed,
}

/// Why an account could not be created, when the reason is the flow rather
/// than the request — a taken username arrives as the server's own error.
enum RegistrationFailure { closed, unsupported, tokenRequired, tokenRejected }

@immutable
class RegistrationException implements Exception {
  const RegistrationException(this.reason);

  final RegistrationFailure reason;

  @override
  String toString() => 'RegistrationException(${reason.name})';
}

/// The flow to follow out of the ones a server advertises, or null when every
/// one of them has a stage this client cannot complete.
///
/// The shortest wins, and a flow without a token beats one with: a server
/// offering both is saying the token is optional.
List<String>? pickRegistrationFlow(Iterable<List<String>> flows) {
  List<String>? best;
  for (final flow in flows) {
    if (!flow.every(RegistrationStage.supported.contains)) continue;
    if (best == null || _cost(flow) < _cost(best)) best = flow;
  }
  return best;
}

int _cost(List<String> flow) =>
    flow.length + (flow.contains(RegistrationStage.token) ? flow.length : 0);

/// Reads [flows] as an answer to "can someone sign up here, and with what".
RegistrationOffer registrationOfferFor(Iterable<List<String>> flows) {
  final flow = pickRegistrationFlow(flows);
  if (flow == null) return RegistrationOffer.unsupported;
  return flow.contains(RegistrationStage.token)
      ? RegistrationOffer.needsToken
      : RegistrationOffer.open;
}

/// The next stage to submit, or null when [flows] holds nothing completable.
///
/// A flow with no stage left still answers [RegistrationStage.dummy]: the
/// server has asked again, and dummy is the stage that carries nothing.
String? nextRegistrationStage(
  Iterable<List<String>> flows, {
  Iterable<String> completed = const [],
}) {
  final flow = pickRegistrationFlow(flows);
  if (flow == null) return null;
  for (final stage in flow) {
    if (!completed.contains(stage)) return stage;
  }
  return RegistrationStage.dummy;
}
