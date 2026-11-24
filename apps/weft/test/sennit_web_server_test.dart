import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/remote_chat_repository.dart';
import 'package:weft/services/web/pairing_registry.dart';
import 'package:weft/services/web/sennit_web_server.dart';
import 'package:weft_remote/weft_remote.dart';
import 'package:weft_store/weft_store.dart';

/// dart:io's WebSocket as the browser would use it.
class _ClientSocket implements FrameSocket {
  _ClientSocket(this._socket) : incoming = _socket.asBroadcastStream();
  final WebSocket _socket;
  @override
  final Stream<Object?> incoming;
  @override
  void add(Object frame) => _socket.add(frame);
  @override
  Future<void> close() => _socket.close();
}

void main() {
  late Directory bundle;
  late WeftDatabase db;
  late PairingRegistry registry;
  late SennitWebServer server;
  late StaticKey phoneKey;

  setUp(() async {
    bundle = Directory.systemTemp.createTempSync('sennit-web-bundle');
    File('${bundle.path}/index.html').writeAsStringSync('<html>Sennit</html>');
    File('${bundle.path}/.sennit-web.json').writeAsStringSync('{}');
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
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    db.dispose();
    bundle.deleteSync(recursive: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.boundPort}$path');

  Future<HttpClientResponse> get(String path) async {
    final client = HttpClient();
    final request = await client.getUrl(at(path));
    return request.close();
  }

  test('serves the bundle and nothing outside it', () async {
    final index = await get('/');
    expect(index.statusCode, 200);
    expect(index.headers.contentType?.mimeType, 'text/html');
    await index.drain<void>();
    for (final path in [
      '/../pubspec.yaml',
      '/%2e%2e/etc/passwd',
      '/.sennit-web.json',
    ]) {
      final response = await get(path);
      expect(response.statusCode, 404, reason: path);
      await response.drain<void>();
    }
  });

  Future<(RemoteChatRepository, SecureLink)> connect(
    StaticKey browser, {
    String? token,
  }) async {
    final socket = _ClientSocket(
      await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws'),
    );
    final initiator = HandshakeInitiator(
      self: browser,
      phonePublicKey: phoneKey.publicKey,
      name: 'Test browser',
      pairingToken: token,
    );
    socket.add(await initiator.start());
    final iterator = StreamIterator(socket.incoming);
    await iterator.moveNext();
    final session = await initiator.finish(iterator.current! as String);
    final rest = StreamController<Object?>();
    unawaited(() async {
      while (await iterator.moveNext()) {
        rest.add(iterator.current);
      }
      await rest.close();
    }());
    final link = SecureLink(socket, session, incoming: rest.stream);
    final repository = RemoteChatRepository(link);
    await repository.connect();
    return (repository, link);
  }

  test('a browser pairs with the token, then reconnects without it', () async {
    final browser = await StaticKey.generate();
    final token = registry.issueToken();
    final (first, _) = await connect(browser, token: token);
    expect(await first.watchChats().first, isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(registry.isPaired(browser.publicId), isTrue);
    await first.dispose();

    // The token was spent; the key is what counts now.
    expect(registry.tokenMatches(token), isFalse);
    final (second, _) = await connect(browser);
    expect(await second.watchChats().first, isNotEmpty);
    await second.dispose();
  });

  test('an unpaired browser without a token is turned away', () async {
    final stranger = await StaticKey.generate();
    await expectLater(
      connect(stranger),
      throwsA(
        isA<HandshakeException>().having(
          (e) => e.failure,
          'failure',
          HandshakeFailure.notPaired,
        ),
      ),
    );
  });

  test('revoking a browser ends its session and its next attempt', () async {
    final browser = await StaticKey.generate();
    final (repository, _) = await connect(
      browser,
      token: registry.issueToken(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    registry.revoke(browser.publicId);
    server.disconnect(browser.publicId);
    await repository.done.timeout(const Duration(seconds: 2));
    await expectLater(connect(browser), throwsA(isA<HandshakeException>()));
  });
}
