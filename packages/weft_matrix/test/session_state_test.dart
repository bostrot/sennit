import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_matrix/weft_matrix.dart';

/// How the SDK's login events move the session state.
///
/// What has to hold: a fresh sign-in is worked out once and lands on
/// `unverified`, and a token refresh afterwards — a soft logout and a login,
/// every few minutes on an OAuth session — leaves it there. Re-deriving after
/// the refresh answered `ready`, because by then the SDK trusts its own
/// device, and the verification step was skipped for the notification prompt.
void main() {
  /// Plays [events] from [start], with [derive] standing in for the client.
  List<WeftSessionState> play(
    WeftSessionState start,
    List<sdk.LoginState> events, {
    required WeftSessionState Function() derive,
    bool refreshable = true,
  }) {
    var current = start;
    return [
      for (final event in events)
        current = sessionStateAfterLogin(
          event,
          current: current,
          refreshable: refreshable,
          derive: derive,
        ),
    ];
  }

  test('an OAuth sign-in stays unverified through a token refresh', () {
    // The SDK's first answer is `unverified`; once it has the device's own
    // keys it would answer `ready`.
    var derived = WeftSessionState.unverified;
    final seen = play(WeftSessionState.connecting, [
      sdk.LoginState.loggedIn,
    ], derive: () => derived);
    derived = WeftSessionState.ready;
    seen.addAll(
      play(seen.last, [
        sdk.LoginState.softLoggedOut,
        sdk.LoginState.loggedIn,
      ], derive: () => derived),
    );

    expect(seen, [
      WeftSessionState.unverified,
      WeftSessionState.unverified,
      WeftSessionState.unverified,
    ]);
  });

  test('a password sign-in is worked out from connecting', () {
    expect(
      play(WeftSessionState.connecting, [
        sdk.LoginState.loggedIn,
        sdk.LoginState.loggedIn,
      ], derive: () => WeftSessionState.unverified),
      [WeftSessionState.unverified, WeftSessionState.unverified],
    );
  });

  test('a refresh does not demote a verified session either', () {
    expect(
      play(WeftSessionState.ready, [
        sdk.LoginState.softLoggedOut,
        sdk.LoginState.loggedIn,
      ], derive: () => WeftSessionState.unverified),
      [WeftSessionState.ready, WeftSessionState.ready],
    );
  });

  test('a soft logout nothing can refresh asks to sign in again', () {
    expect(
      play(
        WeftSessionState.ready,
        [sdk.LoginState.softLoggedOut, sdk.LoginState.loggedIn],
        derive: () => WeftSessionState.ready,
        refreshable: false,
      ),
      [WeftSessionState.softLoggedOut, WeftSessionState.ready],
    );
  });

  test('a failed refresh signs out', () {
    expect(
      play(WeftSessionState.unverified, [
        sdk.LoginState.softLoggedOut,
        sdk.LoginState.loggedOut,
      ], derive: () => WeftSessionState.ready),
      [WeftSessionState.unverified, WeftSessionState.loggedOut],
    );
  });
}
