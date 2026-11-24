import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/remote_chat_repository.dart';
import 'package:weft/services/web/pairing_registry.dart';
import 'package:weft/services/web/relay_connection.dart';
import 'package:weft/services/web/sennit_web_server.dart';
import 'package:weft_remote/weft_remote.dart';
import 'package:weft_store/weft_store.dart';

/// The phone's side of the relay, against a stand-in that speaks the
/// Worker's protocol (`tooling/relay/src/index.js`) from the relay's end.
void main() {
  const secret = 'relay-test-secret-relay-test-secret-0123';
  late Directory bundle;
  late WeftDatabase db;
  late PairingRegistry registry;
  late SennitWebServer server;
  late StaticKey phoneKey;
  late HttpServer relayServer;
  late StreamController<WebSocket> phones;
  late RelayConnection relay;
  String? presented;

  setUp(() async {
    bundle = Directory.systemTemp.createTempSync('sennit-relay-bundle');
    File(
      '${bundle.path}/index.html',
    ).writeAsStringSync('<html><base href="/"></html>');
    File(
      '${bundle.path}/main.dart.js',
    ).writeAsBytesSync(List<int>.generate(600 * 1024, (i) => i % 251));
    db = WeftDatabase.openAt(':memory:');
    registry = PairingRegistry(SettingsStore(db));
    phoneKey = await StaticKey.generate();
    final demo = DemoChatRepository(uploadTick: Duration.zero);
    server = SennitWebServer(
      bundle: bundle,
      key: phoneKey,
      registry: registry,
      repository: () => demo,
      deviceName: 'Test phone',
      lan: false,
    );
    phones = StreamController<WebSocket>();
    presented = null;
    relayServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relayServer.listen((request) async {
      presented = request.headers.value('authorization');
      if (presented != 'Bearer $secret') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      phones.add(await WebSocketTransformer.upgrade(request));
    });
    relay = RelayConnection(
      relay: Uri.parse('http://127.0.0.1:${relayServer.port}'),
      secret: secret,
      server: server,
    );
  });

  tearDown(() async {
    await relay.stop();
    await server.stop();
    await relayServer.close(force: true);
    // Not awaited: with no listener left, close() never completes.
    unawaited(phones.close());
    db.dispose();
    bundle.deleteSync(recursive: true);
  });

  /// The relay's view of the phone's socket: frames in order.
  Future<(WebSocket, StreamIterator<Object?>)> phone() async {
    relay.start();
    // Closed by relay.stop() in tearDown, from the phone's end.
    // ignore: close_sinks
    final socket = await phones.stream.first;
    return (socket, StreamIterator<Object?>(socket));
  }

  Future<Map<String, Object?>> nextText(StreamIterator<Object?> frames) async {
    while (await frames.moveNext()) {
      if (frames.current case final String text) {
        return (jsonDecode(text) as Map).cast<String, Object?>();
      }
    }
    throw StateError('closed');
  }

  test('the relay id matches the Worker: SHA-256, base64url, 22 chars', () {
    // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    expect(RelayConnection.phoneId('abc'), 'ungWv48Bz-pBQUDeXa4iI7');
    expect(RelayConnection.newSecret().length, greaterThanOrEqualTo(43));
  });

  test('presents the secret and reports connected', () async {
    final statuses = <RelayStatus>[];
    relay.statuses.listen(statuses.add);
    await phone();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(presented, 'Bearer $secret');
    expect(statuses, [RelayStatus.connecting, RelayStatus.connected]);
    expect(
      relay.address.toString(),
      'http://127.0.0.1:${relayServer.port}/${RelayConnection.phoneId(secret)}/',
    );
  });

  test('a relay that refuses the secret stops the retries', () async {
    final refused = RelayConnection(
      relay: relay.relay,
      secret: 'not-the-secret',
      server: server,
    );
    final done = refused.statuses.firstWhere((s) => s == RelayStatus.refused);
    refused.start();
    await done.timeout(const Duration(seconds: 5));
    expect(refused.status, RelayStatus.refused);
  });

  test('answers file requests, under the phone\'s own path', () async {
    final (socket, frames) = await phone();
    final id = RelayConnection.phoneId(secret);

    socket.add(jsonEncode({'t': 'get', 'r': 1, 'p': '/'}));
    final head = await nextText(frames);
    expect(head, containsPair('s', 200));
    final body = BytesBuilder();
    while (await frames.moveNext()) {
      final frame = frames.current;
      if (frame is String) {
        expect(jsonDecode(frame), {'t': 'end', 'r': 1});
        break;
      }
      final bytes = frame! as List<int>;
      expect(bytes[0], 2);
      expect(ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(1), 1);
      body.add(bytes.sublist(5));
    }
    expect(utf8.decode(body.takeBytes()), contains('<base href="/$id/">'));

    // A big file arrives in several chunks, whole.
    socket.add(jsonEncode({'t': 'get', 'r': 2, 'p': '/main.dart.js'}));
    final etag = ((await nextText(frames))['h']! as Map)['ETag'];
    var chunks = 0;
    var size = 0;
    while (await frames.moveNext()) {
      if (frames.current is String) break;
      chunks++;
      size += (frames.current! as List<int>).length - 5;
    }
    expect(size, 600 * 1024);
    expect(chunks, greaterThan(1));

    // And unchanged, it costs a 304 and no body.
    socket.add(
      jsonEncode({'t': 'get', 'r': 3, 'p': '/main.dart.js', 'e': etag}),
    );
    expect(await nextText(frames), containsPair('s', 304));
    expect(await nextText(frames), {'t': 'end', 'r': 3});

    socket.add(jsonEncode({'t': 'get', 'r': 4, 'p': '/../secret'}));
    expect(await nextText(frames), containsPair('s', 404));
  });

  test('a relayed browser pairs and talks to the phone end to end', () async {
    final (socket, frames) = await phone();
    const channel = 7;

    // The browser's half, as the Worker would forward it.
    final browser = await StaticKey.generate();
    final initiator = HandshakeInitiator(
      self: browser,
      phonePublicKey: phoneKey.publicKey,
      name: 'Relayed browser',
      pairingToken: registry.issueToken(),
    );
    final toBrowser = StreamController<Object?>();
    addTearDown(toBrowser.close);
    unawaited(() async {
      while (await frames.moveNext()) {
        final frame = frames.current;
        if (frame is String) {
          final m = jsonDecode(frame) as Map;
          if (m['t'] == 'text' && m['c'] == channel) toBrowser.add(m['d']);
        } else if (frame is List<int>) {
          toBrowser.add(frame.sublist(5));
        }
      }
    }());
    socket
      ..add(jsonEncode({'t': 'open', 'c': channel}))
      ..add(
        jsonEncode({'t': 'text', 'c': channel, 'd': await initiator.start()}),
      );
    final incoming = StreamIterator(toBrowser.stream);
    expect(await incoming.moveNext(), isTrue);
    final session = await initiator.finish(incoming.current! as String);

    final rest = StreamController<Object?>();
    addTearDown(rest.close);
    unawaited(() async {
      while (await incoming.moveNext()) {
        rest.add(incoming.current);
      }
    }());
    final link = SecureLink(
      _Relayed(socket, channel),
      session,
      incoming: rest.stream,
    );
    final repository = RemoteChatRepository(link);
    await repository.connect();
    expect(await repository.watchChats().first, isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(registry.isPaired(browser.publicId), isTrue);
    expect(server.sessions.single.relayed, isTrue);
    await repository.dispose();
  });
}

/// The browser's frames, wrapped the way the Worker wraps them.
class _Relayed implements FrameSocket {
  _Relayed(this._socket, this._channel);
  final WebSocket _socket;
  final int _channel;

  @override
  Stream<Object?> get incoming => const Stream.empty();

  @override
  void add(Object frame) {
    if (frame is String) {
      _socket.add(jsonEncode({'t': 'text', 'c': _channel, 'd': frame}));
    } else {
      _socket.add(RelayConnection.frame(1, _channel, frame as List<int>));
    }
  }

  @override
  Future<void> close() async {}
}
