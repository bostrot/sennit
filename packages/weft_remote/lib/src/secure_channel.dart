import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'rpc.dart';

/// Sennit Web's end-to-end encryption between a browser and the phone.
///
/// Whatever carries the bytes — a LAN socket, a Cloudflare tunnel, a relay —
/// sees ciphertext. The pattern is Noise IK in spirit: the browser knows the
/// phone's static key from the pairing QR code (in the URL fragment, which no
/// server is sent), and proves its own static key, which the phone keeps in
/// its list of paired browsers.
///
/// ```
/// → e, es, s, ss, {token?, name}
/// ← e, ee, se, {ok, name}
/// ```
///
/// Both directions then use ChaCha20-Poly1305 with their own key and a
/// counter nonce, so a frame cannot be reordered, replayed or moved across.
/// A browser only counts as paired once its first transport frame decrypts:
/// that is the proof it holds the private key it named.
abstract final class SecureChannel {
  static const String protocolName = 'SennitWeb_IK_25519_ChaChaPoly_SHA256';
  static const int version = 1;
}

final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _sha = Sha256();

Future<List<int>> _hash(List<int> a, [List<int> b = const []]) async =>
    (await _sha.hash([...a, ...b])).bytes;

/// One HKDF step: mixes [ikm] into the chaining key, returns (ck, k).
Future<(List<int>, List<int>)> _mix(List<int> ck, List<int> ikm) async {
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
    secretKey: SecretKey(ikm),
    nonce: ck,
    info: utf8.encode(SecureChannel.protocolName),
  );
  final bytes = await out.extractBytes();
  return (bytes.sublist(0, 32), bytes.sublist(32));
}

Future<List<int>> _dh(SimpleKeyPair mine, List<int> theirs) async =>
    (await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
    )).extractBytes();

Future<List<int>> _seal(List<int> key, List<int> plain, List<int> ad) async {
  final box = await _aead.encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: List<int>.filled(12, 0),
    aad: ad,
  );
  return box.concatenation(nonce: false);
}

Future<List<int>> _open(List<int> key, List<int> sealed, List<int> ad) async {
  final box = SecretBox.fromConcatenation(
    [...List<int>.filled(12, 0), ...sealed],
    nonceLength: 12,
    macLength: 16,
  );
  return _aead.decrypt(box, secretKey: SecretKey(key), aad: ad);
}

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _unb64(String s) => base64Url.decode(base64Url.normalize(s));

/// A static X25519 key, as stored: the phone's, or a browser's.
class StaticKey {
  StaticKey._(this.pair, this.publicKey);

  static Future<StaticKey> generate() async =>
      fromPair(await _x25519.newKeyPair());

  static Future<StaticKey> fromSeed(List<int> seed) async =>
      fromPair(await _x25519.newKeyPairFromSeed(seed));

  static Future<StaticKey> fromPair(SimpleKeyPair pair) async =>
      StaticKey._(pair, (await pair.extractPublicKey()).bytes);

  final SimpleKeyPair pair;
  final List<int> publicKey;

  /// Base64url, unpadded — as it appears in the pairing URL.
  String get publicId => _b64(publicKey);

  Future<String> exportSeed() async =>
      base64.encode(await pair.extractPrivateKeyBytes());
}

/// Why a handshake was refused.
enum HandshakeFailure {
  /// Malformed, or a version this end does not speak.
  protocol,

  /// The browser is not paired and brought no valid pairing token.
  notPaired,

  /// Decryption failed: the browser has the wrong key for this phone, or
  /// something in between altered the exchange.
  crypto,
}

class HandshakeException implements Exception {
  const HandshakeException(this.failure);
  final HandshakeFailure failure;

  @override
  String toString() => 'HandshakeException(${failure.name})';
}

/// The established session: two keys, two counters.
class SecureSession {
  SecureSession._(this._send, this._receive, this.peerKey, this.peerName);

  final List<int> _send;
  final List<int> _receive;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  /// The other end's static public key, base64url.
  final String peerKey;

  /// What the other end called itself.
  final String peerName;

  // Two 32-bit halves: the browser build has no setUint64.
  static List<int> _nonce(int n) {
    final b = ByteData(12)
      ..setUint32(4, n ~/ 0x100000000)
      ..setUint32(8, n % 0x100000000);
    return b.buffer.asUint8List();
  }

  Future<Uint8List> encrypt(Map<String, Object?> frame) async {
    final box = await _aead.encrypt(
      utf8.encode(jsonEncode(frame)),
      secretKey: SecretKey(_send),
      nonce: _nonce(_sendCounter++),
    );
    return box.concatenation(nonce: false);
  }

  /// Throws [HandshakeException] with [HandshakeFailure.crypto] on anything
  /// that does not decrypt under the next expected counter.
  Future<Map<String, Object?>> decrypt(List<int> sealed) async {
    if (sealed.length < 16) {
      throw const HandshakeException(HandshakeFailure.crypto);
    }
    try {
      final plain = await _aead.decrypt(
        SecretBox.fromConcatenation(
          [..._nonce(_receiveCounter), ...sealed],
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: SecretKey(_receive),
      );
      _receiveCounter++;
      return (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
    } on SecretBoxAuthenticationError {
      throw const HandshakeException(HandshakeFailure.crypto);
    }
  }
}

/// The browser's side.
class HandshakeInitiator {
  HandshakeInitiator({
    required this.self,
    required this.phonePublicKey,
    required this.name,
    this.pairingToken,
  });

  final StaticKey self;

  /// From the pairing URL.
  final List<int> phonePublicKey;
  final String name;

  /// Present on the first connection only.
  final String? pairingToken;

  late SimpleKeyPair _e;
  late List<int> _ck;
  late List<int> _h;

  /// The first message, to send as a text frame.
  Future<String> start() async {
    _e = await _x25519.newKeyPair();
    final ePub = (await _e.extractPublicKey()).bytes;
    _h = await _hash(utf8.encode(SecureChannel.protocolName), [
      ...phonePublicKey,
      ...ePub,
    ]);
    final (ck1, k1) = await _mix(_h, await _dh(_e, phonePublicKey));
    final payload = await _seal(
      k1,
      utf8.encode(
        jsonEncode({'s': self.publicId, 'name': name, 'token': ?pairingToken}),
      ),
      _h,
    );
    final (ck2, _) = await _mix(ck1, await _dh(self.pair, phonePublicKey));
    _ck = ck2;
    _h = await _hash(_h, payload);
    return jsonEncode({
      'v': SecureChannel.version,
      'e': _b64(ePub),
      'c': _b64(payload),
    });
  }

  /// Reads the phone's answer and derives the session.
  Future<SecureSession> finish(String reply) async {
    final Map<String, Object?> json;
    try {
      json = (jsonDecode(reply) as Map).cast<String, Object?>();
    } on Object {
      throw const HandshakeException(HandshakeFailure.protocol);
    }
    if (json['error'] == 'not_paired') {
      throw const HandshakeException(HandshakeFailure.notPaired);
    }
    final e = json['e'];
    final c = json['c'];
    if (e is! String || c is! String) {
      throw const HandshakeException(HandshakeFailure.protocol);
    }
    final pe = _unb64(e);
    final (ck3, _) = await _mix(_ck, await _dh(_e, pe));
    final (ck4, k2) = await _mix(ck3, await _dh(self.pair, pe));
    final List<int> plain;
    try {
      plain = await _open(k2, _unb64(c), _h);
    } on SecretBoxAuthenticationError {
      throw const HandshakeException(HandshakeFailure.crypto);
    }
    final answer = (jsonDecode(utf8.decode(plain)) as Map)
        .cast<String, Object?>();
    final (c2s, s2c) = await _mix(ck4, const []);
    return SecureSession._(
      c2s,
      s2c,
      _b64(phonePublicKey),
      (answer['name'] as String?) ?? '',
    );
  }
}

/// What the phone decided about the browser in a first message.
typedef PairingCheck = ({
  /// The browser's static key is on the paired list.
  bool paired,

  /// Or it brought this pairing token, which the phone may accept once.
  String? token,
});

/// The phone's side.
class HandshakeResponder {
  HandshakeResponder({required this.self, required this.name});

  final StaticKey self;
  final String name;

  /// Answers [first]. [admit] decides — from the browser's key, name and
  /// token — whether to go on; the phone checks its paired list and its
  /// pending pairing token there. Returns the reply to send and the session,
  /// or throws after producing a reply that says why.
  Future<({String reply, SecureSession session, String? token})> respond(
    String first, {
    required Future<bool> Function(
      String browserKey,
      String name,
      String? token,
    )
    admit,
  }) async {
    final Map<String, Object?> json;
    try {
      json = (jsonDecode(first) as Map).cast<String, Object?>();
    } on Object {
      throw const HandshakeException(HandshakeFailure.protocol);
    }
    final e = json['e'];
    final c = json['c'];
    if (json['v'] != SecureChannel.version || e is! String || c is! String) {
      throw const HandshakeException(HandshakeFailure.protocol);
    }
    final ce = _unb64(e);
    var h = await _hash(utf8.encode(SecureChannel.protocolName), [
      ...self.publicKey,
      ...ce,
    ]);
    final (ck1, k1) = await _mix(h, await _dh(self.pair, ce));
    final sealed = _unb64(c);
    final Map<String, Object?> payload;
    try {
      payload = (jsonDecode(utf8.decode(await _open(k1, sealed, h))) as Map)
          .cast<String, Object?>();
    } on SecretBoxAuthenticationError {
      throw const HandshakeException(HandshakeFailure.crypto);
    }
    final browserKey = payload['s'];
    if (browserKey is! String) {
      throw const HandshakeException(HandshakeFailure.protocol);
    }
    final token = payload['token'] as String?;
    final browserName = (payload['name'] as String?) ?? '';
    if (!await admit(browserKey, browserName, token)) {
      throw const HandshakeException(HandshakeFailure.notPaired);
    }
    final bs = _unb64(browserKey);
    final (ck2, _) = await _mix(ck1, await _dh(self.pair, bs));
    h = await _hash(h, sealed);
    final pe = await _x25519.newKeyPair();
    final peBytes = (await pe.extractPublicKey()).bytes;
    final (ck3, _) = await _mix(ck2, await _dh(pe, ce));
    final (ck4, k2) = await _mix(ck3, await _dh(pe, bs));
    final answer = await _seal(
      k2,
      utf8.encode(jsonEncode({'ok': true, 'name': name})),
      h,
    );
    final (c2s, s2c) = await _mix(ck4, const []);
    return (
      reply: jsonEncode({'e': _b64(peBytes), 'c': _b64(answer)}),
      session: SecureSession._(s2c, c2s, browserKey, browserName),
      token: token,
    );
  }

  /// The reply that tells a browser it has to pair again.
  static String notPairedReply() => jsonEncode({'error': 'not_paired'});
}

/// A socket-like pipe of text and binary frames — a WebSocket.
abstract interface class FrameSocket {
  Stream<Object?> get incoming;
  void add(Object frame);
  Future<void> close();
}

/// A [RemoteLink] over an established [SecureSession]: every frame is sealed
/// on the way out and opened on the way in. A frame that does not open closes
/// the link — there is no "skip the bad one" in a counter-nonce stream.
class SecureLink implements RemoteLink {
  SecureLink(this._socket, this._session, {Stream<Object?>? incoming}) {
    _sub = (incoming ?? _socket.incoming).listen((data) async {
      if (data is! List<int>) return;
      // Decryption is async and the counter must advance in order.
      _queue = _queue.then((_) async {
        try {
          final frame = await _session.decrypt(data);
          if (!_in.isClosed) _in.add(frame);
          if (!_authenticated.isCompleted) _authenticated.complete();
        } on Object {
          await close();
        }
      });
    }, onDone: () => unawaited(close()));
  }

  final FrameSocket _socket;
  final SecureSession _session;
  late final StreamSubscription<Object?> _sub;
  final _in = StreamController<Map<String, Object?>>();
  final _authenticated = Completer<void>();
  Future<void> _queue = Future.value();
  Future<void> _sendQueue = Future.value();

  /// Completes on the first frame that decrypts — the peer's proof of key.
  Future<void> get authenticated => _authenticated.future;

  SecureSession get session => _session;

  @override
  Stream<Map<String, Object?>> get incoming => _in.stream;

  @override
  void send(Map<String, Object?> frame) {
    _sendQueue = _sendQueue.then((_) async {
      if (_in.isClosed) return;
      _socket.add(await _session.encrypt(frame));
    });
  }

  @override
  Future<void> close() async {
    if (_in.isClosed) return;
    await _sub.cancel();
    await _in.close();
    await _socket.close();
  }
}
