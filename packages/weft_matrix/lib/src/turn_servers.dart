import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';

import 'api_session.dart';

/// Where the homeserver hands out relay credentials.
const String kTurnServerPath = '_matrix/client/v3/voip/turnServer';

/// Whether the homeserver gave Weft a relay, and if not, why.
///
/// Four values rather than a nullable credential because the three failures
/// need three different sentences. "Your server offers no relay" is a
/// configuration fact the user may be able to do something about; "your session
/// expired" is a sign-in problem; "we could not reach the server" is a network
/// blip that may fix itself in a second.
enum TurnAvailability {
  /// The homeserver returned usable TURN URIs.
  available,

  /// The homeserver answered, and has no TURN server configured. Extremely
  /// common on a self-hosted Synapse: the default configuration ships without
  /// one, and nothing in the setup guide insists.
  notConfigured,

  /// The access token was refused.
  unauthorised,

  /// The request never got an answer, or the answer made no sense.
  unreachable,
}

/// One set of time-limited TURN credentials.
@immutable
class TurnCredentials {
  const TurnCredentials({
    required this.uris,
    required this.username,
    required this.password,
    required this.ttl,
    required this.fetchedAt,
  });

  /// `turn:` and `turns:` URIs, in the order the server listed them.
  final List<String> uris;

  final String username;
  final String password;

  /// How long the server says these are good for. Synapse's default is an
  /// hour; some deployments use a day.
  final Duration ttl;

  final DateTime fetchedAt;

  DateTime get expiresAt => fetchedAt.add(ttl);

  /// Whether these should be replaced before being handed to a peer connection.
  ///
  /// [margin] is subtracted from the expiry rather than compared against it,
  /// which is the whole of "refresh before expiry": credentials that are valid
  /// *now* but expire in ten seconds will still be in use when ICE restarts
  /// halfway through a call, and a peer connection does not re-ask.
  bool isStaleAt(DateTime now, {Duration margin = kTurnRefreshMargin}) =>
      !now.isBefore(expiresAt.subtract(margin));

  /// The `iceServers` entry a peer connection takes.
  ///
  /// One entry carrying every URI, which is the shape both `flutter_webrtc` and
  /// the Matrix SDK produce: the credentials are the same for all of them, and
  /// splitting them per URI would make WebRTC allocate against each in turn.
  Map<String, Object?> get iceServer => {
    'urls': List<String>.unmodifiable(uris),
    'username': username,
    'credential': password,
  };

  /// Reads `GET /voip/turnServer`, or null when the body carries no usable
  /// relay.
  ///
  /// A 200 with no `uris` is the ordinary answer from a homeserver with no TURN
  /// configured, so it is a value here rather than an error.
  static TurnCredentials? fromJson(
    Object? json, {
    required DateTime fetchedAt,
  }) {
    if (json is! Map) return null;

    final uris = json['uris'];
    final username = json['username'];
    final password = json['password'];
    if (uris is! List || username is! String || password is! String) {
      return null;
    }

    final parsed = [
      for (final uri in uris)
        if (uri is String && uri.isNotEmpty) uri,
    ];
    if (parsed.isEmpty) return null;

    final ttl = json['ttl'];
    return TurnCredentials(
      uris: List.unmodifiable(parsed),
      username: username,
      password: password,
      // A server that omits `ttl` is out of spec, but treating that as "no
      // relay" would be worse than assuming the shortest sensible lifetime and
      // re-asking.
      ttl: Duration(seconds: ttl is int && ttl > 0 ? ttl : 3600),
      fetchedAt: fetchedAt,
    );
  }

  @override
  String toString() =>
      'TurnCredentials(${uris.length} uri(s), expires $expiresAt)';
}

/// What to hand a peer connection, and what to tell the user.
@immutable
class IceConfiguration {
  const IceConfiguration({
    required this.availability,
    this.servers = const [],
    this.warning,
  });

  final TurnAvailability availability;

  /// `iceServers`, ready for the media engine.
  ///
  /// Empty when there is no TURN. Weft deliberately substitutes no public STUN
  /// server here: a hard-coded fallback would send every user's IP addresses to
  /// a third party they never chose, and it would not fix the failure anyway —
  /// STUN cannot get through a symmetric NAT, which is the case TURN exists
  /// for. An empty list still allows a call over the local network, which is
  /// exactly what the user is warned about.
  final List<Map<String, Object?>> servers;

  /// A sentence for the user, or null when there is nothing to say.
  ///
  /// Present whenever [availability] is not [TurnAvailability.available]. The
  /// Matrix SDK logs this case at verbose level and returns an empty list,
  /// which is how a self-hosted user ends up with calls that work at home and
  /// nowhere else, with nothing on screen to explain it.
  final String? warning;

  bool get hasTurn => availability == TurnAvailability.available;

  @override
  String toString() =>
      'IceConfiguration(${availability.name}, '
      '${servers.length} server(s))';
}

/// How long before expiry credentials are refetched.
const Duration kTurnRefreshMargin = Duration(minutes: 2);

/// Fetches and caches this account's TURN credentials.
///
/// Two things here are missing from the Matrix SDK and are the reason this
/// exists rather than a call to `VoIP.getIceServers`:
///
/// - **It never refreshes.** `voip.dart` assigns `_turnServerCredentials` on
///   first use and keeps it for the life of the process, ttl or no ttl. A
///   client left running overnight places its next call with credentials the
///   relay stopped honouring hours ago.
/// - **It fails silently.** The same code catches the error, logs it at verbose
///   level, and returns `[]`. The user gets a call that never connects and no
///   reason.
///
/// Raw HTTP rather than `client.getTurnServer()` for the reason on
/// [MatrixApiSession]: the SDK call needs a `Client`, a `Client` needs a
/// database, and none of that is required to assert that a 404 reads as "your
/// server has no relay" rather than as an outage.
class MatrixTurnServers {
  MatrixTurnServers({
    required MatrixApiSession session,
    this.refreshMargin = kTurnRefreshMargin,
    DateTime Function()? clock,
  }) : _session = session,
       _clock = clock ?? DateTime.now;

  /// The common case: credentials for a live SDK client.
  factory MatrixTurnServers.forClient(sdk.Client client) =>
      MatrixTurnServers(session: MatrixApiSession.forClient(client));

  final MatrixApiSession _session;
  final DateTime Function() _clock;

  /// How long before expiry a cached credential counts as stale.
  final Duration refreshMargin;

  TurnCredentials? _cached;
  IceConfiguration? _lastFailure;
  Future<IceConfiguration>? _inFlight;

  /// The credentials currently cached, for diagnostics.
  TurnCredentials? get cached => _cached;

  /// What to configure the next peer connection with.
  ///
  /// Refetches when the cache is missing or within [refreshMargin] of expiry,
  /// and returns rather than throws on every failure: a call with no relay is
  /// still worth attempting — on the same network it works — so the failure is
  /// a warning to show, not a reason to refuse to dial.
  Future<IceConfiguration> configuration({bool forceRefresh = false}) {
    final cached = _cached;
    if (!forceRefresh &&
        cached != null &&
        !cached.isStaleAt(_clock(), margin: refreshMargin)) {
      return Future.value(_available(cached));
    }

    // Placing a call gathers ICE from more than one place at once; without this
    // the first seconds of a call would fire several identical requests at the
    // homeserver and race over which answer wins.
    return _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
  }

  /// Drops the cache, e.g. after a logout.
  void invalidate() {
    _cached = null;
    _lastFailure = null;
  }

  Future<IceConfiguration> _fetch() async {
    final baseUrl = _session.baseUrl;
    final token = _session.accessToken;
    if (baseUrl == null || token == null || token.isEmpty) {
      return _fail(
        TurnAvailability.unauthorised,
        'You are not signed in, so Weft could not get the relay details this '
        'call needs.',
      );
    }

    final http.Response response;
    try {
      response = await _session.httpClient.get(
        baseUrl.resolveUri(Uri(path: kTurnServerPath)),
        headers: {'authorization': 'Bearer $token'},
      );
    } on Object catch (error) {
      return _fail(
        TurnAvailability.unreachable,
        'Weft could not reach your homeserver for call relay details, so this '
        'call may not connect ($error).',
      );
    }

    if (response.statusCode == 401) {
      return _fail(
        TurnAvailability.unauthorised,
        'Your session has expired, so Weft could not get the relay details '
        'this call needs.',
      );
    }
    // 404 is what a homeserver that has never been given a TURN server answers
    // with, and it is the single most common reason a self-hosted call
    // connects at home and nowhere else.
    if (response.statusCode == 404) return _noRelay();
    if (response.statusCode != 200) {
      return _fail(
        TurnAvailability.unreachable,
        'Your homeserver refused to hand out call relay details '
        '(HTTP ${response.statusCode}), so this call may not connect.',
      );
    }

    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      return _fail(
        TurnAvailability.unreachable,
        'Your homeserver sent call relay details Weft could not read, so this '
        'call may not connect.',
      );
    }

    // A 200 with `{}` means the same thing as a 404: Synapse answers this way
    // when `turn_uris` is unset.
    final credentials = TurnCredentials.fromJson(body, fetchedAt: _clock());
    if (credentials == null) return _noRelay();

    _cached = credentials;
    _lastFailure = null;
    return _available(credentials);
  }

  IceConfiguration _available(TurnCredentials credentials) => IceConfiguration(
    availability: TurnAvailability.available,
    servers: [credentials.iceServer],
  );

  IceConfiguration _noRelay() => _fail(
    TurnAvailability.notConfigured,
    'Your homeserver provides no call relay, so this call will only connect if '
    'you are both on the same network.',
  );

  /// Records the failure and returns it.
  ///
  /// The last failure is kept so that a caller which asks twice in a second —
  /// the call service does, once for the offer and once for an ICE restart —
  /// gets the same answer both times rather than a second request.
  IceConfiguration _fail(TurnAvailability availability, String warning) {
    return _lastFailure = IceConfiguration(
      availability: availability,
      warning: warning,
    );
  }

  /// The most recent failure, or null when the last fetch succeeded.
  IceConfiguration? get lastFailure => _lastFailure;
}
