@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_transcribe/weft_transcribe.dart';

import '../integration_test/patrol/support/stubs.dart';

/// The device suite's stub servers, driven by the same clients the app uses.
///
/// `integration_test/patrol/` cannot run without a device and `patrol_cli`, and
/// three of its scenarios stand or fall on whether the stub servers in
/// `support/stubs.dart` answer the way the real services do. That is not a claim
/// that needs a device to check: the servers are `dart:io`, and the clients that
/// talk to them — `BridgeProvisioningClient`,
/// `OpenAiCompatibleTranscriptionProvider`, `OpenAiCompatibleEmbeddingProvider`
/// — are the app's own, unchanged.
///
/// So the wire contract is checked here, in a test that runs on every push,
/// against a real socket. What is left for the device is everything above the
/// client: the screens, the settings, the index. If a scenario fails on a device
/// with a parse error, this file failing first is the difference between an
/// afternoon and a minute.
void main() {
  group('LocalStubServer', () {
    test('answers a route it knows and says so when it does not', () async {
      final server = await LocalStubServer.start(
        (request) => request.path == '/hello'
            ? StubResponse.ok({'said': request.json['name']})
            : null,
        label: 'greeting stub',
      );
      addTearDown(server.close);

      final client = BridgeProvisioningClient(
        baseUrl: server.rootedAt('/hello'),
        accessToken: 'token',
      );
      addTearDown(client.dispose);

      // Anything that speaks HTTP would do; this is the client that is
      // convenient, and it exercises the JSON encoding on both sides.
      expect(server.received, isEmpty);
      await expectLater(
        client.logout('unrouted'),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.message,
            'message',
            contains('greeting stub has no route'),
          ),
        ),
        reason:
            'an unmatched path has to name the stub and the path, or a typo in '
            'a route looks like a bug in the app',
      );
      expect(server.received.single.method, 'POST');
    });
  });

  group('BridgeStub', () {
    test('whoami carries the network and every login state', () async {
      final stub = await BridgeStub.start(
        networkId: 'whatsapp',
        networkName: 'WhatsApp',
        logins: const [
          {'id': 'a', 'state_event': 'CONNECTED', 'name': '+44 7700 900000'},
          {
            'id': 'b',
            'state_event': 'BAD_CREDENTIALS',
            'name': '+44 7700 900111',
            'error': 'Logged out elsewhere',
          },
        ],
      );
      addTearDown(stub.close);

      final whoami = await _client(stub).whoami();
      expect(whoami.networkId, 'whatsapp');
      expect(whoami.networkName, 'WhatsApp');
      expect(whoami.logins.first.state, BridgeLoginState.connected);
      expect(whoami.logins.first.label, '+44 7700 900000');
      expect(whoami.logins.last.state, BridgeLoginState.badCredentials);
      expect(whoami.logins.last.errorMessage, 'Logged out elsewhere');
      expect(stub.probed, isTrue);
    });

    test('refuses a caller with no Matrix access token', () async {
      final stub = await BridgeStub.start();
      addTearDown(stub.close);

      final client = BridgeProvisioningClient(
        baseUrl: stub.provisioningUrl,
        accessToken: '',
      );
      addTearDown(client.dispose);

      await expectLater(
        client.whoami(),
        throwsA(
          isA<BridgeException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('the QR flow starts and then polls unchanged', () async {
      final stub = await BridgeStub.start(qrPayload: 'weft-e2e://pair/abc');
      addTearDown(stub.close);
      final client = _client(stub);

      final flows = await client.loginFlows();
      expect(flows.single.id, 'qr');

      final started = await client.startLogin(flows.single.id);
      expect(started.type, LoginStepType.displayAndWait);
      expect(started.displayType, 'qr');
      expect(started.displayData, 'weft-e2e://pair/abc');
      expect(started.loginId, 'login-1');

      // `BridgeLoginSession` treats an unchanged payload as "nothing has
      // happened yet" and goes back to sleep. A stub that varied it would put
      // the login screen into a redraw loop.
      final polled = await client.waitForStep(
        loginId: started.loginId!,
        stepId: started.stepId,
      );
      expect(polled.stepId, started.stepId);
      expect(polled.displayData, started.displayData);
    });
  });

  group('TranscriptionStub', () {
    test('answers the shape the provider asks for', () async {
      final stub = await TranscriptionStub.start(
        transcript: 'meet me by the portcullis at six',
      );
      addTearDown(stub.close);

      final provider = OpenAiCompatibleTranscriptionProvider(
        baseUrl: stub.baseUrl,
      );
      addTearDown(provider.dispose);

      final transcript = await provider.transcribe(
        TranscriptionRequest(
          audio: Uint8List.fromList(List<int>.filled(64, 7)),
          filename: 'voice.ogg',
        ),
      );
      expect(transcript.text, 'meet me by the portcullis at six');
      expect(transcript.language, 'english');
      expect(transcript.durationMs, 3200);
      expect(stub.transcribed, 1);
      expect(
        stub.lastUpload,
        contains('voice.ogg'),
        reason:
            'the multipart body carries the filename the backend decodes by',
      );
    });
  });

  group('EmbeddingStub', () {
    test('two ways of saying the same thing land on the same vector', () async {
      final stub = await EmbeddingStub.start(
        concepts: const [
          ['roof', 'roofing', 'shingles'],
        ],
      );
      addTearDown(stub.close);

      final provider = OpenAiCompatibleEmbeddingProvider(
        baseUrl: stub.baseUrl,
        modelId: 'weft-e2e-concepts',
        dimensions: 8,
      );
      addTearDown(provider.dispose);

      final vectors = await provider.embed([
        'the shingles need replacing slate99',
        'roofing',
        'the tortoise escaped again',
      ]);
      expect(vectors, hasLength(3));
      expect(vectors.every((v) => v.length == 8), isTrue);
      expect(stub.embedded, 3);

      // The premise the semantic scenario rests on, and the one thing a keyword
      // index cannot do: no word in common, same point in space.
      expect(
        quantizedSimilarity(vectors[0], vectors[1]),
        closeTo(1, 0.01),
        reason: 'the message and the query have to be neighbours',
      );
      // And the other half: unrelated text must not drift into the answer, or
      // the scenario's ranking assertion is a coin toss.
      expect(
        quantizedSimilarity(vectors[2], vectors[1]),
        closeTo(0, 0.01),
        reason:
            'a message with no concept in it lands in the hashed subspace, '
            'which is orthogonal to every concept axis by construction',
      );
    });

    test('vectorFor is what the endpoint actually returns', () async {
      final stub = await EmbeddingStub.start(
        concepts: const [
          ['roof'],
        ],
      );
      addTearDown(stub.close);

      final provider = OpenAiCompatibleEmbeddingProvider(
        baseUrl: stub.baseUrl,
        modelId: 'weft-e2e-concepts',
        dimensions: 8,
      );
      addTearDown(provider.dispose);

      // A scenario states its premise by comparing two `vectorFor` results
      // without a round trip. That is only honest if the local answer is the
      // wire answer.
      final overTheWire = (await provider.embed(['a roof'])).single;
      expect(overTheWire, quantize(stub.vectorFor('a roof')));
    });
  });
}

BridgeProvisioningClient _client(BridgeStub stub) {
  final client = BridgeProvisioningClient(
    baseUrl: stub.provisioningUrl,
    accessToken: 'syt_test_token',
  );
  addTearDown(client.dispose);
  return client;
}
