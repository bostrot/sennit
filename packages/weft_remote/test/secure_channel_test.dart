import 'dart:async';

import 'package:test/test.dart';
import 'package:weft_remote/weft_remote.dart';

class _Socket implements FrameSocket {
  _Socket(this.incoming, this._out);
  @override
  final Stream<Object?> incoming;
  final StreamController<Object?> _out;
  final List<Object> sent = [];
  Object Function(Object)? tamper;

  @override
  void add(Object frame) {
    sent.add(frame);
    if (!_out.isClosed) _out.add(tamper?.call(frame) ?? frame);
  }

  @override
  Future<void> close() => _out.close();
}

({_Socket browser, _Socket phone}) _sockets() {
  // ignore: close_sinks
  final toPhone = StreamController<Object?>();
  // ignore: close_sinks
  final toBrowser = StreamController<Object?>();
  return (
    browser: _Socket(toBrowser.stream, toPhone),
    phone: _Socket(toPhone.stream, toBrowser),
  );
}

void main() {
  late StaticKey phone;
  late StaticKey browser;

  setUp(() async {
    phone = await StaticKey.generate();
    browser = await StaticKey.generate();
  });

  Future<(SecureSession, SecureSession)> handshake({
    required Future<bool> Function(String, String, String?) admit,
    List<int>? phoneKeyInQr,
    String? token,
  }) async {
    final initiator = HandshakeInitiator(
      self: browser,
      phonePublicKey: phoneKeyInQr ?? phone.publicKey,
      name: 'Firefox',
      pairingToken: token,
    );
    final first = await initiator.start();
    final answer = await HandshakeResponder(
      self: phone,
      name: 'Pixel',
    ).respond(first, admit: admit);
    final browserSession = await initiator.finish(answer.reply);
    return (browserSession, answer.session);
  }

  test('a paired browser and the phone agree on keys both ways', () async {
    final (b, p) = await handshake(
      admit: (key, _, _) async => key == browser.publicId,
    );
    expect(b.peerName, 'Pixel');
    expect(p.peerName, 'Firefox');
    expect(p.peerKey, browser.publicId);
    expect(await p.decrypt(await b.encrypt({'hi': 1})), {'hi': 1});
    expect(await b.decrypt(await p.encrypt({'yo': 2})), {'yo': 2});
  });

  test('pairing passes the token to the phone, encrypted', () async {
    String? seen;
    await handshake(
      token: 'one-time',
      admit: (_, _, token) async {
        seen = token;
        return token == 'one-time';
      },
    );
    expect(seen, 'one-time');
  });

  test('an unknown browser without a token is refused', () async {
    await expectLater(
      handshake(admit: (_, _, _) async => false),
      throwsA(
        isA<HandshakeException>().having(
          (e) => e.failure,
          'failure',
          HandshakeFailure.notPaired,
        ),
      ),
    );
  });

  test('a QR code with another phone key cannot talk to this phone', () async {
    final impostor = await StaticKey.generate();
    await expectLater(
      handshake(
        admit: (_, _, _) async => true,
        phoneKeyInQr: impostor.publicKey,
      ),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('a tampered, replayed or reordered frame is refused', () async {
    final (b, p) = await handshake(admit: (_, _, _) async => true);
    final one = await b.encrypt({'n': 1});
    final two = await b.encrypt({'n': 2});
    final flipped = [...one]..[0] ^= 1;
    await expectLater(p.decrypt(flipped), throwsA(isA<HandshakeException>()));
    // Out of order: frame two under frame one's counter.
    await expectLater(p.decrypt(two), throwsA(isA<HandshakeException>()));
    expect(await p.decrypt(one), {'n': 1});
    // Replay of frame one.
    await expectLater(p.decrypt(one), throwsA(isA<HandshakeException>()));
  });

  test(
    'an RPC peer runs over a SecureLink; the wire carries only bytes',
    () async {
      final (b, p) = await handshake(admit: (_, _, _) async => true);
      final sockets = _sockets();
      final phoneLink = SecureLink(sockets.phone, p);
      final browserLink = SecureLink(sockets.browser, b);
      RpcPeer(phoneLink, handlers: {'echo': (params) async => params['text']});
      final client = RpcPeer(browserLink);
      expect(
        await client.call('echo', {'text': 'secret words'}),
        'secret words',
      );
      await phoneLink.authenticated;
      for (final frame in [...sockets.browser.sent, ...sockets.phone.sent]) {
        expect(frame, isA<List<int>>());
        expect(
          String.fromCharCodes(frame as List<int>),
          isNot(contains('secret')),
        );
      }
    },
  );

  test('a link closes when a frame in flight is altered', () async {
    final (b, p) = await handshake(admit: (_, _, _) async => true);
    final sockets = _sockets();
    sockets.browser.tamper = (f) => [...(f as List<int>)]..[3] ^= 0xff;
    final phoneLink = SecureLink(sockets.phone, p);
    final browserLink = SecureLink(sockets.browser, b);
    final server = RpcPeer(phoneLink);
    final client = RpcPeer(browserLink);
    unawaited(client.call('anything').catchError((_) => null));
    await server.done.timeout(const Duration(seconds: 2));
    expect(server.isClosed, isTrue);
  });
}
