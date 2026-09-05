import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Client for the mautrix **bridgev2 provisioning API v3**.
///
/// This is the API Beeper's own GUI login drives, and any bridge built on
/// mautrix-go's bridgev2 framework serves it. Weft prefers it over automating
/// the admin room because the flows are declarative: the bridge describes its
/// steps and fields, so a new login method works without a Weft release.
///
/// Authentication is the user's Matrix access token — bridges validate it
/// against the homeserver they are attached to.
class BridgeProvisioningClient {
  BridgeProvisioningClient({
    required this.baseUrl,
    required this.accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Provisioning root, e.g. `https://bridge.example.org/_matrix/provision`.
  final Uri baseUrl;

  /// Matrix access token for the logged-in user.
  final String accessToken;

  final Duration timeout;
  final http.Client _http;
  final bool _ownsClient;

  Map<String, String> get _headers => {
    'authorization': 'Bearer $accessToken',
    'content-type': 'application/json',
  };

  Uri _v3(String path) => baseUrl.replace(
    path: '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}/v3$path',
  );

  /// Identifies the bridge and lists the user's logins.
  ///
  /// Also the reachability probe: a bridge that cannot answer this is offline,
  /// and the UI says so rather than implying the user is signed out.
  Future<BridgeWhoami> whoami() async {
    final json = await _get(_v3('/whoami'));

    final network = json['network'];
    final logins = <BridgeLogin>[];
    if (json['logins'] is List) {
      for (final entry in json['logins'] as List) {
        if (entry is! Map) continue;
        final stateEvent = entry['state_event'] ?? entry['state'];
        logins.add(
          BridgeLogin(
            id: entry['id'] as String? ?? '',
            state: BridgeLoginState.fromWire(stateEvent as String?),
            name: entry['name'] as String?,
            remoteProfileName: entry['profile'] is Map
                ? (entry['profile'] as Map)['name'] as String?
                : null,
            errorMessage: entry['error'] as String?,
          ),
        );
      }
    }

    return BridgeWhoami(
      networkId: network is Map
          ? network['beeper_bridge_type'] as String? ??
                network['id'] as String? ??
                network['displayname'] as String?
          : null,
      networkName: network is Map ? network['displayname'] as String? : null,
      logins: logins,
    );
  }

  /// Login methods this bridge offers.
  Future<List<BridgeLoginFlow>> loginFlows() async {
    final json = await _get(_v3('/login/flows'));

    final flows = json['flows'];
    if (flows is! List) return const [];

    return flows
        .whereType<Map>()
        .map(
          (flow) => BridgeLoginFlow(
            id: flow['id'] as String? ?? '',
            name: flow['name'] as String? ?? flow['id'] as String? ?? 'Sign in',
            description: flow['description'] as String?,
          ),
        )
        .where((flow) => flow.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Begins [flowId], returning its first step.
  Future<LoginStep> startLogin(String flowId) async {
    final json = await _post(_v3('/login/start/$flowId'), null);
    return LoginStep.fromJson(json);
  }

  /// Submits a step and returns the next one.
  ///
  /// [stepType] is echoed back in the path exactly as the bridge reported it —
  /// the server uses it to confirm the client rendered the step it meant.
  Future<LoginStep> submitStep({
    required String loginId,
    required String stepId,
    required String stepType,
    Map<String, Object?>? body,
  }) async {
    final json = await _post(
      _v3('/login/step/$loginId/$stepId/$stepType'),
      body ?? const {},
    );
    return LoginStep.fromJson(json);
  }

  /// Polls a `display_and_wait` step until the remote side responds.
  Future<LoginStep> waitForStep({
    required String loginId,
    required String stepId,
  }) async {
    final json = await _post(
      _v3('/login/step/$loginId/$stepId/display_and_wait'),
      const {},
    );
    return LoginStep.fromJson(json);
  }

  /// Signs a remote account out of the bridge.
  Future<void> logout(String loginId) async {
    await _post(_v3('/logout/$loginId'), const {});
  }

  Future<Map<String, Object?>> _get(Uri uri) async {
    final http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(timeout);
    } on Exception catch (e) {
      throw BridgeException('Could not reach the bridge: $e');
    }
    return _decode(response);
  }

  Future<Map<String, Object?>> _post(Uri uri, Object? body) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: _headers,
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw BridgeException('Could not reach the bridge: $e');
    }
    return _decode(response);
  }

  static Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      json = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (json == null) {
        throw const BridgeException(
          'The bridge returned an unreadable response',
        );
      }
      return json;
    }

    // Matrix-style errors carry errcode/error; surface those rather than a
    // bare status code, since bridges write genuinely useful messages.
    final errcode = json?['errcode'] as String?;
    final error = json?['error'] as String?;

    final failure = error == null ? _failureFor(response.statusCode) : null;
    throw BridgeException(
      error ?? _describeStatus(response.statusCode),
      statusCode: response.statusCode,
      errorCode: errcode,
      failure: failure,
    );
  }

  static BridgeFailure _failureFor(int status) => switch (status) {
    401 || 403 => BridgeFailure.rejected,
    404 => BridgeFailure.notFound,
    502 || 503 || 504 => BridgeFailure.unavailable,
    _ => BridgeFailure.other,
  };

  /// The English fallback, kept for logs and for a caller with no translations
  /// of its own. The app words [BridgeFailure] itself.
  static String _describeStatus(int status) => switch (_failureFor(status)) {
    BridgeFailure.rejected =>
      'The bridge rejected your Matrix account. Check that it is configured '
          'to serve your homeserver and that your user is permitted.',
    BridgeFailure.notFound =>
      'No provisioning API at that URL. It usually ends in /_matrix/provision.',
    BridgeFailure.unavailable =>
      'The bridge is not responding. It may be starting up or offline.',
    BridgeFailure.other => 'The bridge returned an error ($status).',
  };

  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// Result of `/whoami`.
class BridgeWhoami {
  const BridgeWhoami({
    this.networkId,
    this.networkName,
    this.logins = const [],
  });

  final String? networkId;
  final String? networkName;
  final List<BridgeLogin> logins;
}
