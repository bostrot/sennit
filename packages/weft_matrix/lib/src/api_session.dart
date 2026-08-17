import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as sdk;

/// The slice of a signed-in Matrix session that a raw client-server call needs.
///
/// Three getters rather than an `sdk.Client`, and that is a testing decision
/// with a real cost attached: a `Client` cannot be constructed without a
/// database, so taking one here would put a sqflite instance between every test
/// and the things actually worth asserting — which URI an upload lands on,
/// whether a pusher registration sends `event_id_only`, whether a 413 is
/// retried. None of those need a session; they need a base URL and a token.
///
/// Read per call rather than captured, because the SDK refreshes access tokens
/// underneath us on soft logout: a request made an hour after the caller was
/// built must use the token the client holds *now*.
///
/// Shared by the upload transport and the pusher registry. Two identical
/// interfaces would mean two fakes to keep in step, and a difference between
/// them would read as a real difference between the two paths when it is not.
abstract class MatrixApiSession {
  /// Reads straight through to a live client.
  const factory MatrixApiSession.forClient(sdk.Client client) =
      _ClientApiSession;

  /// The homeserver's client-server API root, or null before login.
  Uri? get baseUrl;

  /// The current access token, or null before login.
  String? get accessToken;

  /// The client to put requests on. Sharing the SDK's own means sharing its
  /// timeouts and its connection pool rather than opening a second one.
  http.Client get httpClient;
}

class _ClientApiSession implements MatrixApiSession {
  const _ClientApiSession(this._client);

  final sdk.Client _client;

  @override
  Uri? get baseUrl => _client.homeserver;

  @override
  String? get accessToken => _client.accessToken;

  @override
  http.Client get httpClient => _client.httpClient;
}
