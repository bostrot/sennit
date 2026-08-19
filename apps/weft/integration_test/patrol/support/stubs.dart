/// Services Weft talks to over HTTP, standing up inside the test process.
///
/// Three of the four screens this phase's last scenarios cover are screens whose
/// whole job is to talk to something that is not the homeserver — a mautrix
/// bridge's provisioning API, a Whisper endpoint, an embeddings endpoint — and
/// none of the three exists in `tooling/docker`. A bridge is a Go binary the
/// user runs; a transcription endpoint is a GPU; an embeddings endpoint is
/// either that or a paid API. Waiting for all three is waiting forever, and
/// asserting nothing is worse.
///
/// So they are answered here, by an `HttpServer` bound to loopback in the same
/// process the test runs in — which is also the app's process, because that is
/// what a Patrol test is. What that does and does not prove is worth being
/// exact about:
///
/// - **Everything on Weft's side of the socket is real.** The settings screen,
///   the provider that reads it, the `http` client, the multipart encoder, the
///   JSON decoding, the error mapping, the queue, the index, the widget that
///   draws the answer. A stub cannot make any of that pass; it can only give it
///   something to be right or wrong about.
/// - **The other side is not a bridge, a model or a GPU.** The stub decides what
///   a QR payload is, what a clip says, and which two sentences are near each
///   other in vector space. An assertion that depends on the *quality* of any of
///   those answers would be an assertion about this file, and there is none.
///
/// It is also the one thing in the suite that needs the app to be able to open a
/// cleartext socket to itself: see `android/app/src/debug/AndroidManifest.xml`,
/// and `com.apple.security.network.server` in
/// `macos/Runner/DebugProfile.entitlements`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

// ------------------------------------------------------------------ the server

/// One request a stub was asked to answer.
@immutable
class StubRequest {
  const StubRequest({
    required this.method,
    required this.path,
    required this.body,
    required this.headers,
  });

  final String method;
  final String path;

  /// The raw body, decoded as UTF-8. Multipart arrives here as-is, which is
  /// enough for [TranscriptionStub] to confirm what was uploaded.
  final String body;

  final Map<String, String> headers;

  /// The body as JSON, or an empty map when it is not.
  Map<String, Object?> get json {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  @override
  String toString() => '$method $path';
}

/// What a stub answers with.
@immutable
class StubResponse {
  const StubResponse(this.status, this.json);

  const StubResponse.ok(Map<String, Object?> json) : this(200, json);

  final int status;
  final Map<String, Object?> json;
}

/// Answers a request, or returns null to leave it unmatched.
typedef StubRoute = StubResponse? Function(StubRequest request);

/// An HTTP server on this device's own loopback, for the duration of a test.
///
/// Port zero, always: a fixed port is a port some other row of the matrix — or
/// the previous scenario, whose server is still closing — is holding, and the
/// failure is a bind error attributed to whichever test ran second.
class LocalStubServer {
  LocalStubServer._(this._server, this._route, this.label) {
    unawaited(_serve());
  }

  /// Binds and starts answering.
  static Future<LocalStubServer> start(
    StubRoute route, {
    String label = 'stub',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return LocalStubServer._(server, route, label);
  }

  final HttpServer _server;
  final StubRoute _route;

  /// Named in the 404 body and in `debugPrint`, so an unmatched path in a
  /// device log says which stub did not recognise it.
  final String label;

  /// Every request received, in order. The assertion surface for "did the app
  /// actually call this?", which is a different question from "did the screen
  /// draw the answer".
  final List<StubRequest> received = [];

  Uri get baseUrl =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: '/');

  /// [baseUrl] with a path, which is what every caller actually wants: an
  /// OpenAI-compatible root ends in `/v1`, a mautrix one in `/_matrix/provision`.
  Uri rootedAt(String path) => baseUrl.replace(path: path);

  Future<void> _serve() async {
    await for (final request in _server) {
      try {
        await _answer(request);
      } on Object catch (error) {
        // A stub that throws must not take the test down with an unhandled
        // async error from a socket nobody is awaiting.
        debugPrint('weft e2e: $label failed to answer ${request.uri}: $error');
      }
    }
  }

  Future<void> _answer(HttpRequest request) async {
    final stubRequest = StubRequest(
      method: request.method,
      path: request.uri.path,
      body: await utf8.decoder.bind(request).join(),
      headers: {
        for (final name in _headerNames(request))
          name: request.headers.value(name) ?? '',
      },
    );
    received.add(stubRequest);

    final response =
        _route(stubRequest) ??
        StubResponse(404, {
          'errcode': 'M_UNRECOGNIZED',
          'error':
              '$label has no route for ${stubRequest.method} '
              '${stubRequest.path}',
        });

    request.response
      ..statusCode = response.status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response.json));
    await request.response.close();
  }

  static List<String> _headerNames(HttpRequest request) {
    final names = <String>[];
    request.headers.forEach((name, _) => names.add(name));
    return names;
  }

  Future<void> close() => _server.close(force: true);
}

// ------------------------------------------------------------------- a bridge

/// A mautrix **bridgev2 provisioning API v3** server, as much of it as the
/// bridges screen actually calls.
///
/// Four endpoints: `whoami` (which is also the health probe), `login/flows`,
/// `login/start/<flow>`, and the `display_and_wait` poll. That is the whole
/// surface of `BridgeProvisioningClient` bar `logout`, and it is enough to drive
/// the screen from "add a bridge" through to a QR code on screen.
class BridgeStub {
  BridgeStub._(this.server);

  static Future<BridgeStub> start({
    String networkId = 'whatsapp',
    String networkName = 'WhatsApp',
    List<Map<String, Object?>> logins = const [],
    String flowId = 'qr',
    String flowName = 'Scan a QR code',
    String? qrPayload,
  }) async {
    late final BridgeStub stub;
    final server = await LocalStubServer.start(
      (request) => stub._route(request),
      label: 'bridge stub',
    );
    stub = BridgeStub._(server)
      .._networkId = networkId
      .._networkName = networkName
      .._logins = logins
      .._flowId = flowId
      .._flowName = flowName
      .._qrPayload = qrPayload ?? 'weft-e2e-pairing-payload';
    return stub;
  }

  final LocalStubServer server;

  late String _networkId;
  late String _networkName;
  late List<Map<String, Object?>> _logins;
  late String _flowId;
  late String _flowName;
  late String _qrPayload;

  /// The payload the QR step displays, which is also what the *text* form under
  /// it must read and what Copy must put on the clipboard.
  String get qrPayload => _qrPayload;

  /// What a user types into "Add a bridge".
  ///
  /// The path is the one the dialog's own hint suggests, so the scenario adds
  /// the bridge exactly as the screen tells the user to.
  Uri get provisioningUrl => server.rootedAt('/_matrix/provision');

  /// Whether the app has asked who this bridge is yet.
  bool get probed => server.received.any(
    (r) => r.path.endsWith('/_matrix/provision/v3/whoami'),
  );

  Future<void> close() => server.close();

  StubResponse? _route(StubRequest request) {
    const root = '/_matrix/provision/v3';
    // Every call is authenticated with the user's Matrix access token, and a
    // bridge that did not check it would be a bridge anyone could drive. The
    // header is asserted rather than ignored so that "the app forgot to send
    // the token" fails here rather than passing quietly.
    if (!request.headers['authorization']!.startsWith('Bearer ')) {
      return const StubResponse(401, {
        'errcode': 'M_MISSING_TOKEN',
        'error': 'No Matrix access token was presented',
      });
    }

    final path = request.path;
    if (path == '$root/whoami') {
      return StubResponse.ok({
        'network': {'id': _networkId, 'displayname': _networkName},
        'logins': _logins,
      });
    }
    if (path == '$root/login/flows') {
      return StubResponse.ok({
        'flows': [
          {'id': _flowId, 'name': _flowName, 'description': 'Pair this device'},
        ],
      });
    }
    // The start, and then the poll — which answers with the same step,
    // unchanged, because that is what a bridge does while the other side has
    // not scanned anything: `BridgeLoginSession._pollUntilAdvanced` compares
    // `displayData`, finds it unmoved and goes back to sleep. Advancing to
    // `complete` would be a different scenario; this one is about what the
    // waiting step draws.
    if (path == '$root/login/start/$_flowId' ||
        path == '$root/login/step/login-1/qr-step/display_and_wait') {
      return _qrStep();
    }
    return null;
  }

  StubResponse _qrStep() => StubResponse.ok({
    'step_id': 'qr-step',
    'type': 'display_and_wait',
    'login_id': 'login-1',
    'instructions': 'Open $_networkName on your phone and scan this code.',
    'display_and_wait': {'type': 'qr', 'data': _qrPayload},
  });
}

// ------------------------------------------------------------- transcription

/// An endpoint speaking OpenAI's `/v1/audio/transcriptions`.
///
/// It always says the same thing, and that is the point: the transcript is a
/// string the test chose, so a search for a word only that string contains
/// proves the transcript reached the index, and nothing about speech
/// recognition.
class TranscriptionStub {
  TranscriptionStub._(this.server, this.transcript);

  static Future<TranscriptionStub> start({required String transcript}) async {
    late final TranscriptionStub stub;
    final server = await LocalStubServer.start(
      (request) => stub._route(request),
      label: 'transcription stub',
    );
    return stub = TranscriptionStub._(server, transcript);
  }

  final LocalStubServer server;

  /// The words the endpoint claims to have heard.
  final String transcript;

  /// The base URL the Endpoints screen wants: a root ending in `/v1`, which is
  /// what `OpenAiCompatibleTranscriptionProvider` appends `/audio/transcriptions`
  /// to.
  Uri get baseUrl => server.rootedAt('/v1');

  /// How many clips have been sent here.
  int get transcribed =>
      server.received.where((r) => r.path == '/v1/audio/transcriptions').length;

  /// The bytes of the last upload, as the multipart body arrived.
  ///
  /// Not parsed — the assertion it supports is "something with a filename was
  /// actually posted", which is the difference between a transcript the app
  /// fetched and one it invented.
  String get lastUpload => server.received
      .lastWhere((r) => r.path == '/v1/audio/transcriptions')
      .body;

  Future<void> close() => server.close();

  StubResponse? _route(StubRequest request) {
    if (request.path != '/v1/audio/transcriptions') return null;
    // `verbose_json` is what the provider asks for, and the language is the
    // half of the answer the "re-transcribe in…" action exists for.
    return StubResponse.ok({
      'text': transcript,
      'language': 'english',
      'duration': 3.2,
    });
  }
}

// ---------------------------------------------------------------- embeddings

/// An endpoint speaking OpenAI's `/v1/embeddings`, with one idea in its head.
///
/// A real embedding model is a claim about meaning; this is a lookup table with
/// [concepts] in it. Any text containing one of a concept's words embeds onto
/// that concept's own axis, so two sentences sharing a *concept* and no *words*
/// come out identical — which is the one thing a keyword index cannot do and
/// therefore the only thing worth asserting about the semantic half of search.
///
/// Everything else lands in a hashed subspace disjoint from the concept axes, so
/// an unrelated message scores ~0 against a concept query rather than drifting
/// into the results and making the ranking assertion a coin toss.
///
/// [dimensions] is small on purpose. It has to match what the Endpoints screen
/// was told, because `OpenAiCompatibleEmbeddingProvider` refuses a vector of the
/// wrong length rather than silently mixing incomparable coordinates — and eight
/// numbers in a log line can be read.
class EmbeddingStub {
  EmbeddingStub._(this.server, this.concepts, this.dimensions, this.modelId);

  static Future<EmbeddingStub> start({
    required List<List<String>> concepts,
    int dimensions = 8,
    String modelId = 'weft-e2e-concepts',
  }) async {
    assert(
      concepts.length <= dimensions ~/ 2,
      'half the dimensions are the hashed subspace unrelated text lands in',
    );
    late final EmbeddingStub stub;
    final server = await LocalStubServer.start(
      (request) => stub._route(request),
      label: 'embedding stub',
    );
    return stub = EmbeddingStub._(server, concepts, dimensions, modelId);
  }

  final LocalStubServer server;

  /// Groups of words that mean the same thing to this endpoint.
  final List<List<String>> concepts;

  final int dimensions;
  final String modelId;

  Uri get baseUrl => server.rootedAt('/v1');

  /// How many texts have been embedded, over every batch.
  int get embedded => server.received
      .where((r) => r.path == '/v1/embeddings')
      .fold(0, (sum, r) => sum + ((r.json['input'] as List?)?.length ?? 0));

  Future<void> close() => server.close();

  StubResponse? _route(StubRequest request) {
    if (request.path != '/v1/embeddings') return null;
    final input = request.json['input'];
    if (input is! List) {
      return const StubResponse(400, {'error': 'expected an input array'});
    }

    return StubResponse.ok({
      'model': modelId,
      'data': [
        for (var i = 0; i < input.length; i++)
          {
            'index': i,
            'object': 'embedding',
            'embedding': vectorFor('${input[i]}'),
          },
      ],
    });
  }

  /// The vector this endpoint gives [text]. Exposed so a scenario can state its
  /// premise — that two strings embed identically — as an expectation rather
  /// than as a hope.
  List<double> vectorFor(String text) {
    final vector = List<double>.filled(dimensions, 0);
    final words = text.toLowerCase().split(RegExp(r'[^a-z0-9]+'));

    for (var axis = 0; axis < concepts.length; axis++) {
      if (words.any(concepts[axis].contains)) {
        vector[axis] = 1;
        return vector;
      }
    }

    // No concept: a bag of words in the upper half, orthogonal to every axis
    // above by construction.
    final base = dimensions ~/ 2;
    for (final word in words.where((w) => w.isNotEmpty)) {
      vector[base + (word.hashCode.abs() % (dimensions - base))] += 1;
    }
    return vector;
  }
}
