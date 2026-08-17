import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as sdk;
import 'package:meta/meta.dart';

import 'api_session.dart';

/// Where a pusher is created, updated and deleted.
///
/// One endpoint for all three: a POST with `kind: "http"` creates or replaces,
/// a POST with `kind: null` deletes. There is no DELETE verb to reach for.
const String kPushersSetPath = '_matrix/client/v3/pushers/set';

/// Where the account's current pushers are listed.
const String kPushersPath = '_matrix/client/v3/pushers';

/// The push payload format Weft registers with, and the most consequential
/// decision in this file.
///
/// With `event_id_only` the homeserver tells the push gateway — and therefore
/// Google, Apple, and whoever runs the gateway — only *that* something happened
/// in a room: an event id, a room id, and an unread count. The app then fetches
/// the event through its own authenticated session and decrypts it locally.
///
/// **The alternative hands every message away.** Omit the format and the
/// homeserver sends the event's `content` in the push, so the plaintext of a
/// message from an unencrypted room travels through the push gateway and the
/// platform's notification service, both of which log. For an *encrypted* room
/// it is worse than useless: the payload is ciphertext the gateway cannot read
/// and the app would have to fetch and decrypt anyway. There is no case in
/// which sending the body buys anything Weft wants.
///
/// The cost is real and is paid on the receiving side: a push carries no text,
/// so the app must be able to fetch and decrypt an event from whatever context
/// the platform woke it in. That is what `push_delivery.dart` is for, and it is
/// the reason the background-decrypt question (a separate isolate needs its own
/// vodozemac init and its own database handle) has to be answered before the
/// platform layer, not after.
const String kEventIdOnlyFormat = 'event_id_only';

/// The only pusher kind Weft registers. Matrix also defines `email`, which is a
/// homeserver-side concern with no app involvement.
const String kHttpPusherKind = 'http';

/// A pusher as Weft registers it.
///
/// [appId] and [pushKey] together identify a pusher on the account: registering
/// the same pair twice updates in place, and a different pair is a *different*
/// pusher. That pairing is why [pushKey] rotation has to be handled explicitly —
/// see [MatrixPusherRegistry.ensureRegistered].
@immutable
class WeftPusher {
  const WeftPusher({
    required this.appId,
    required this.pushKey,
    required this.gatewayUrl,
    this.appDisplayName = 'Weft',
    this.deviceDisplayName = 'Weft',
    this.lang = 'en',
    this.profileTag,
    this.defaultPayload = const {},
  });

  /// Reverse-DNS identifier for this app *on this platform*, max 64 chars.
  ///
  /// Per platform, not per app: the gateway routes on it to decide whether a
  /// poke becomes an FCM message or an APNs one, so Android and iOS builds of
  /// Weft register different ids even though they are the same program.
  final String appId;

  /// The platform's own token for this device — an FCM registration token or an
  /// APNs device token. Max 512 bytes, and it rotates.
  final String pushKey;

  /// The push gateway's `/_matrix/push/v1/notify` endpoint.
  final Uri gatewayUrl;

  /// Shown in the account's "where you are signed in" style lists.
  final String appDisplayName;
  final String deviceDisplayName;

  /// Preferred language for anything the gateway renders. Weft renders its own
  /// notifications, so this is nearly decorative — but the spec requires it.
  final String lang;

  final String? profileTag;

  /// Passed through by the gateway into the platform message untouched.
  ///
  /// APNs needs `{"aps": {"mutable-content": 1, "alert": {…}}}` here for the
  /// notification service extension to be given the chance to decrypt; on
  /// Android it is where a data-only message is arranged. Kept as an opaque map
  /// because it is the gateway's contract, not Matrix's.
  final Map<String, Object?> defaultPayload;

  /// The body of a `POST /pushers/set` that creates or updates this pusher.
  ///
  /// [append] false — the default — tells the homeserver to drop any *other*
  /// pusher with the same push key registered by a different app id. That is
  /// the correct default for a client: two pushers pointed at one device token
  /// mean two notifications for every message.
  Map<String, Object?> toJson({bool append = false}) => {
    'app_id': appId,
    'pushkey': pushKey,
    'kind': kHttpPusherKind,
    'app_display_name': appDisplayName,
    'device_display_name': deviceDisplayName,
    if (profileTag != null) 'profile_tag': profileTag,
    'lang': lang,
    'data': {
      'url': gatewayUrl.toString(),
      // The whole point. See [kEventIdOnlyFormat].
      'format': kEventIdOnlyFormat,
      if (defaultPayload.isNotEmpty) 'default_payload': defaultPayload,
    },
    'append': append,
  };

  /// The body that deletes this pusher: the same identity, `kind: null`.
  Map<String, Object?> deletionJson() => {
    'app_id': appId,
    'pushkey': pushKey,
    'kind': null,
  };

  /// Reads a pusher out of `GET /pushers`.
  ///
  /// Returns null for anything that is not an HTTP pusher with a gateway URL:
  /// an `email` pusher on the same account is not this app's and must not be
  /// mistaken for a stale copy of it.
  static WeftPusher? fromJson(Object? json) {
    if (json is! Map) return null;
    final appId = json['app_id'];
    final pushKey = json['pushkey'];
    final data = json['data'];
    if (appId is! String || pushKey is! String || data is! Map) return null;

    final url = Uri.tryParse(data['url'] as String? ?? '');
    if (url == null || !url.hasScheme) return null;

    final payload = data['default_payload'];
    return WeftPusher(
      appId: appId,
      pushKey: pushKey,
      gatewayUrl: url,
      appDisplayName: json['app_display_name'] as String? ?? '',
      deviceDisplayName: json['device_display_name'] as String? ?? '',
      lang: json['lang'] as String? ?? 'en',
      profileTag: json['profile_tag'] as String?,
      defaultPayload: payload is Map
          ? {
              for (final entry in payload.entries)
                if (entry.key is String) entry.key as String: entry.value,
            }
          : const {},
    );
  }

  /// The `event_id_only` format, read back off a pusher the server returned.
  ///
  /// Not part of [WeftPusher] itself because Weft only ever *writes* that one
  /// format; this exists so [MatrixPusherRegistry.ensureRegistered] can notice
  /// a pusher registered by an older build that still sends bodies.
  static String? formatOf(Object? json) {
    if (json is! Map) return null;
    final data = json['data'];
    return data is Map ? data['format'] as String? : null;
  }

  WeftPusher copyWith({String? pushKey, Uri? gatewayUrl}) => WeftPusher(
    appId: appId,
    pushKey: pushKey ?? this.pushKey,
    gatewayUrl: gatewayUrl ?? this.gatewayUrl,
    appDisplayName: appDisplayName,
    deviceDisplayName: deviceDisplayName,
    lang: lang,
    profileTag: profileTag,
    defaultPayload: defaultPayload,
  );

  /// Whether [other] is the same pusher *slot* — same app, same device token.
  ///
  /// Deliberately not `==`: two pushers can share an identity and disagree
  /// about their display name or gateway, which is exactly the case that needs
  /// a rewrite rather than a second registration.
  bool hasSameIdentity(WeftPusher other) =>
      other.appId == appId && other.pushKey == pushKey;

  @override
  bool operator ==(Object other) =>
      other is WeftPusher &&
      other.appId == appId &&
      other.pushKey == pushKey &&
      other.gatewayUrl == gatewayUrl &&
      other.appDisplayName == appDisplayName &&
      other.deviceDisplayName == deviceDisplayName &&
      other.lang == lang &&
      other.profileTag == profileTag;

  @override
  int get hashCode => Object.hash(
    appId,
    pushKey,
    gatewayUrl,
    appDisplayName,
    deviceDisplayName,
    lang,
    profileTag,
  );

  @override
  String toString() =>
      'WeftPusher($appId, ${pushKey.length} byte key, $gatewayUrl)';
}

/// A pusher registration that did not happen.
///
/// [retryable] separates "the network was bad" from "the server said no": an
/// unretryable failure means the caller should surface it rather than schedule
/// another attempt, because trying again produces the same refusal.
class PusherRegistrationException implements Exception {
  const PusherRegistrationException(
    this.message, {
    this.statusCode,
    this.retryable = false,
  });

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() =>
      'PusherRegistrationException($message, status: $statusCode)';
}

/// Creates, updates and deletes this device's pusher on the homeserver.
///
/// Raw HTTP rather than the SDK's `postPusher`, for the reason set out on
/// [MatrixApiSession]: the SDK call needs a `Client`, a `Client` needs a
/// database, and none of that is required to assert that the registration body
/// carries `format: event_id_only`.
class MatrixPusherRegistry {
  const MatrixPusherRegistry({required MatrixApiSession session})
    : _session = session;

  /// The common case: registration over a live SDK client.
  factory MatrixPusherRegistry.forClient(sdk.Client client) =>
      MatrixPusherRegistry(session: MatrixApiSession.forClient(client));

  final MatrixApiSession _session;

  /// Creates or replaces [pusher] on the account.
  Future<void> register(WeftPusher pusher, {bool append = false}) =>
      _post(pusher.toJson(append: append), 'register this device for push');

  /// Removes the pusher identified by [appId] and [pushKey].
  ///
  /// Takes the identity rather than a [WeftPusher] because the pusher being
  /// deleted is usually one this process never built — the previous run's
  /// token, read back from storage.
  Future<void> unregister({required String appId, required String pushKey}) =>
      _post({
        'app_id': appId,
        'pushkey': pushKey,
        'kind': null,
      }, 'unregister this device from push');

  /// The account's HTTP pushers, across every device.
  ///
  /// Anything that is not an HTTP pusher with a usable gateway URL — an `email`
  /// pusher, a malformed entry — is dropped rather than represented, because
  /// every caller of this is asking "is *my* pusher there".
  Future<List<WeftPusher>> list() async {
    return [for (final raw in await _rawPushers()) ?WeftPusher.fromJson(raw)];
  }

  /// Registers [pusher] only when the server's copy differs, returning whether
  /// it wrote anything.
  ///
  /// Two things make this more than an optimisation:
  ///
  /// **Token rotation.** FCM and APNs both reissue tokens — after a reinstall,
  /// a restore, or at the platform's whim. The old pusher does not disappear
  /// when the token does; it stays on the account and the gateway keeps poking
  /// a device that will never answer, until the gateway's own failure handling
  /// eventually removes it. [previousPushKey] is the caller's record of what
  /// this device registered last time, and it is deleted first.
  ///
  /// **[previousPushKey] cannot be inferred.** Every device of the account
  /// registers under the *same* app id with its own token, so "the other
  /// pushers with my app id" is the user's other phones, not this phone's
  /// history. Deleting them would silence push on every device the user owns.
  /// The caller must remember its own last key; there is no way to work it out
  /// from the list.
  ///
  /// A server-side pusher that is identical apart from its format — an older
  /// Weft that registered without `event_id_only` — counts as different and is
  /// rewritten, so upgrading the app stops the homeserver sending bodies to the
  /// gateway without the user doing anything.
  Future<bool> ensureRegistered(
    WeftPusher pusher, {
    String? previousPushKey,
  }) async {
    if (previousPushKey != null && previousPushKey != pusher.pushKey) {
      await unregister(appId: pusher.appId, pushKey: previousPushKey);
    }

    final existing = await _rawPushers();
    final current = existing.firstWhere(
      (raw) => WeftPusher.fromJson(raw)?.hasSameIdentity(pusher) ?? false,
      orElse: () => const <String, Object?>{},
    );
    if (current.isNotEmpty &&
        WeftPusher.fromJson(current) == pusher &&
        WeftPusher.formatOf(current) == kEventIdOnlyFormat) {
      return false;
    }

    await register(pusher);
    return true;
  }

  Future<List<Map<String, Object?>>> _rawPushers() async {
    final body = await _get(kPushersPath, 'list this account\'s pushers');
    final pushers = body?['pushers'];
    if (pushers is! List) return const [];
    return [
      for (final raw in pushers)
        if (raw is Map<String, Object?>) raw,
    ];
  }

  Future<Map<String, Object?>?> _get(String path, String what) async {
    final request = _authorised(what);
    final http.Response response;
    try {
      response = await _session.httpClient.get(
        request.url.resolveUri(Uri(path: path)),
        headers: {'authorization': 'Bearer ${request.token}'},
      );
    } on Object catch (error) {
      throw PusherRegistrationException(
        'Could not reach the server to $what: $error',
        retryable: true,
      );
    }
    if (response.statusCode != 200) throw _failureFor(response, what);
    return _decodeJson(response.body);
  }

  Future<void> _post(Map<String, Object?> body, String what) async {
    final request = _authorised(what);
    final http.Response response;
    try {
      response = await _session.httpClient.post(
        request.url.resolveUri(Uri(path: kPushersSetPath)),
        headers: {
          'authorization': 'Bearer ${request.token}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } on Object catch (error) {
      // Losing the network mid-registration is the ordinary case on a phone,
      // and the one worth retrying: nothing about the request was wrong.
      throw PusherRegistrationException(
        'Could not reach the server to $what: $error',
        retryable: true,
      );
    }

    if (response.statusCode != 200) throw _failureFor(response, what);
  }

  /// Reads the base URL and token *now*, for the reason on [MatrixApiSession].
  ({Uri url, String token}) _authorised(String what) {
    final baseUrl = _session.baseUrl;
    final token = _session.accessToken;
    if (baseUrl == null || token == null || token.isEmpty) {
      throw PusherRegistrationException(
        'You are not signed in, so Weft cannot $what.',
      );
    }
    return (url: baseUrl, token: token);
  }

  PusherRegistrationException _failureFor(http.Response response, String what) {
    final body = _decodeJson(response.body);
    final serverMessage = body?['error'];

    return switch (response.statusCode) {
      401 => PusherRegistrationException(
        'Your session has expired, so Weft cannot $what.',
        statusCode: 401,
      ),
      // M_UNKNOWN with a bad pushkey lands here. Retrying sends the same
      // rejected token again.
      400 => PusherRegistrationException(
        serverMessage is String && serverMessage.isNotEmpty
            ? serverMessage
            : 'The server rejected this pusher.',
        statusCode: 400,
      ),
      429 => PusherRegistrationException(
        'The server is busy; push registration will try again.',
        statusCode: 429,
        retryable: true,
      ),
      >= 500 => PusherRegistrationException(
        'The server had a problem registering for push.',
        statusCode: response.statusCode,
        retryable: true,
      ),
      _ => PusherRegistrationException(
        serverMessage is String && serverMessage.isNotEmpty
            ? serverMessage
            : 'The server refused to $what (${response.statusCode}).',
        statusCode: response.statusCode,
      ),
    };
  }
}

Map<String, Object?>? _decodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    // An HTML error page from a reverse proxy is a normal thing to receive.
    return null;
  }
}
