import 'package:matrix/matrix.dart' as sdk;

/// How the person proves it is them before the homeserver deactivates their
/// account.
///
/// Deactivation is the one request a homeserver always guards with
/// User-Interactive Authentication, and what it asks for depends on the
/// server: a password on most, single sign-on on a server that has no
/// passwords, occasionally something else. The two methods cover every case —
/// a password is drawn by Sennit, and anything else is the homeserver's own
/// fallback page, which the spec requires every stage to have.
abstract interface class AccountReauth {
  /// The account password, or null when the person backed out.
  ///
  /// [retry] is true when the homeserver refused the previous one, so the
  /// prompt can say so instead of asking the same question again.
  Future<String?> password({bool retry = false});

  /// Opens [url], the homeserver's page for a stage Sennit cannot draw, and
  /// resolves once the person says they finished there. False when they
  /// backed out.
  Future<bool> completeInBrowser(Uri url);
}

/// The person backed out of re-authenticating. Nothing was deactivated.
class AccountDeactivationCancelled implements Exception {
  const AccountDeactivationCancelled();
}

/// The homeserver asked for something no [AccountReauth] can give it.
class AccountDeactivationUnsupported implements Exception {
  const AccountDeactivationUnsupported();
}

/// The stage to complete next for a deactivation, or null when no advertised
/// flow can be finished from where [completed] left off.
///
/// A flow whose only stages are a password and dummies wins, because it is
/// the one Sennit draws itself; otherwise the shortest flow still open does,
/// with each of its stages done on the homeserver's own page.
String? nextDeactivationStage(
  Iterable<List<String>> flows, {
  List<String> completed = const [],
}) {
  final open = [
    for (final stages in flows)
      if (stages.length > completed.length && _startsWith(stages, completed))
        stages,
  ];
  if (open.isEmpty) return null;

  bool drawable(List<String> stages) => stages.every(
    (stage) =>
        stage == sdk.AuthenticationTypes.password ||
        stage == sdk.AuthenticationTypes.dummy,
  );

  open.sort((a, b) {
    final byDrawable = (drawable(a) ? 0 : 1) - (drawable(b) ? 0 : 1);
    return byDrawable != 0 ? byDrawable : a.length - b.length;
  });
  return open.first[completed.length];
}

bool _startsWith(List<String> stages, List<String> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (stages[i] != prefix[i]) return false;
  }
  return true;
}

/// Where the homeserver serves its own page for [stage] in [session].
Uri authFallbackUrl(Uri homeserver, String stage, String session) =>
    homeserver.replace(
      path:
          '${_trimSlash(homeserver.path)}/_matrix/client/v3/auth/'
          '${Uri.encodeComponent(stage)}/fallback/web',
      queryParameters: {'session': session},
    );

String _trimSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

/// Deactivates [userId]'s account on the homeserver [api] talks to.
///
/// [erase] asks the server to forget what it can of the account as well:
/// Synapse and tuwunel both honour it by erasing the account data and serving
/// the account's messages redacted to anyone who did not already have them.
/// A server that ignores the flag still deactivates.
///
/// The first request carries no auth on purpose: it is how the server says
/// which stages it wants. One round per stage after that, bounded, so a server
/// that keeps answering with another challenge is not followed forever.
Future<void> deactivateAccount(
  sdk.MatrixApi api, {
  required String userId,
  required AccountReauth reauth,
  bool erase = true,
}) async {
  sdk.AuthenticationData? auth;
  String? submitted;
  for (var round = 0; round < 8; round++) {
    try {
      await api.deactivateAccount(auth: auth, erase: erase);
      return;
    } on sdk.MatrixException catch (e) {
      final session = e.session;
      final flows = e.authenticationFlows;
      if (session == null || flows == null) rethrow;

      final stage = nextDeactivationStage(
        flows.map((flow) => flow.stages),
        completed: e.completedAuthenticationFlows,
      );
      if (stage == null) throw const AccountDeactivationUnsupported();

      // The stage just submitted is being asked for again: it was refused.
      final retry = submitted == stage;
      submitted = stage;

      if (stage == sdk.AuthenticationTypes.password) {
        final password = await reauth.password(retry: retry);
        if (password == null) throw const AccountDeactivationCancelled();
        auth = sdk.AuthenticationPassword(
          session: session,
          password: password,
          identifier: sdk.AuthenticationUserIdentifier(user: userId),
        );
      } else if (stage == sdk.AuthenticationTypes.dummy) {
        auth = sdk.AuthenticationData(
          type: sdk.AuthenticationTypes.dummy,
          session: session,
        );
      } else {
        final homeserver = api.homeserver;
        if (homeserver == null) throw const AccountDeactivationUnsupported();
        final finished = await reauth.completeInBrowser(
          authFallbackUrl(homeserver, stage, session),
        );
        if (!finished) throw const AccountDeactivationCancelled();
        // After a fallback page the spec has the client send the session
        // alone: the server already knows the stage is done.
        auth = sdk.AuthenticationData(session: session);
      }
    }
  }
  throw const AccountDeactivationUnsupported();
}

/// Deactivation for a session signed in through an OAuth server, which keeps
/// it for its own account page at [page]: the homeserver refuses the request
/// from a session that never had a password to confirm it with.
///
/// The page does the deactivation, so all that is left here is to find out
/// whether it happened. A token that still works means it did not — the
/// person closed the page, or changed their mind there — and the account and
/// this device's copy of it are left alone.
Future<void> deactivateOnAccountPage(
  sdk.MatrixApi api, {
  required Uri page,
  required AccountReauth reauth,
}) async {
  if (!await reauth.completeInBrowser(page)) {
    throw const AccountDeactivationCancelled();
  }
  try {
    await api.getTokenOwner();
  } on sdk.MatrixException catch (e) {
    if (e.error == sdk.MatrixError.M_UNKNOWN_TOKEN ||
        e.error == sdk.MatrixError.M_USER_DEACTIVATED ||
        e.response?.statusCode == 401) {
      return;
    }
    rethrow;
  }
  throw const AccountDeactivationCancelled();
}
