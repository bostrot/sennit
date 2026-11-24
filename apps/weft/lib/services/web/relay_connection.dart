import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:weft_remote/weft_remote.dart';

import 'sennit_web_server.dart';

/// Where the relay connection stands.
enum RelayStatus {
  off,
  connecting,
  connected,

  /// The relay turned the secret down — not a Sennit relay, or a broken one.
  refused,

  /// The relay could not be reached; retrying.
  unreachable,
}

/// The phone's line out to a Sennit relay (`tooling/relay`), for browsers that
/// are not on its network.
///
/// The phone dials out — nothing has to reach *in* to it, which a phone on
/// mobile data or behind a router could not allow — and the relay passes each
/// browser's requests down this one socket. Files come back in the clear (they
/// are public); a browser's app socket is passed through untouched, and that
/// is end-to-end encrypted between the browser and [server], so the relay
/// carries only ciphertext.
///
/// The relay files the phone under [phoneId], derived from [secret]: only the
/// holder of the secret can answer for that address.
class RelayConnection {
  RelayConnection({
    required this.relay,
    required this.secret,
    required this.server,
    Future<WebSocket> Function(Uri, Map<String, String>)? connect,
  }) : _connect =
           connect ??
           ((uri, headers) => WebSocket.connect('$uri', headers: headers));

  /// The relay's address, `https://…`.
  final Uri relay;
  final String secret;
  final SennitWebServer server;
  final Future<WebSocket> Function(Uri, Map<String, String>) _connect;

  final _status = StreamController<RelayStatus>.broadcast();
  RelayStatus _current = RelayStatus.off;
  WebSocket? _socket;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false;
  final Map<int, _RelayedSocket> _channels = {};

  Stream<RelayStatus> get statuses => _status.stream;
  RelayStatus get status => _current;

  /// The relay's id for a secret: base64url of its SHA-256, 22 characters.
  /// The relay computes the same from the secret the phone presents.
  static String phoneId(String secret) => base64Url
      .encode(const DartSha256().hashSync(utf8.encode(secret)).bytes)
      .replaceAll('=', '')
      .substring(0, 22);

  /// Where a browser opens this phone through the relay.
  Uri get address => relay.replace(path: '/${phoneId(secret)}/');

  /// A new random secret, for the first time the relay is switched on.
  static String newSecret() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_open());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _closeChannels();
    await _socket?.close();
    _socket = null;
    _set(RelayStatus.off);
  }

  void _set(RelayStatus status) {
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }

  Future<void> _open() async {
    if (!_running) return;
    _set(RelayStatus.connecting);
    final WebSocket socket;
    try {
      socket = await _connect(
        relay.replace(
          scheme: relay.scheme == 'http' ? 'ws' : 'wss',
          path: '/phone',
        ),
        {'Authorization': 'Bearer $secret'},
      );
    } on Object {
      // dart:io does not say why an upgrade failed. A relay that turns the
      // secret down answers a plain request with 401, and retrying will not
      // change that.
      if (await _refused()) {
        _running = false;
        _set(RelayStatus.refused);
        return;
      }
      _scheduleRetry();
      return;
    }
    if (!_running) {
      await socket.close();
      return;
    }
    _socket = socket;
    _attempt = 0;
    // A ping the relay answers without waking up, so neither it nor anything
    // in between drops an idle line.
    final ping = Timer.periodic(const Duration(seconds: 30), (_) {
      if (socket.readyState == WebSocket.open) socket.add('ping');
    });
    _set(RelayStatus.connected);
    socket.listen(
      (data) => unawaited(_receive(socket, data)),
      onDone: () {
        ping.cancel();
        _closeChannels();
        if (_socket == socket) _socket = null;
        if (_running) _scheduleRetry();
      },
      cancelOnError: true,
    );
  }

  Future<bool> _refused() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(relay.replace(path: '/phone'));
      request.headers.set('Authorization', 'Bearer $secret');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.unauthorized;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _scheduleRetry() {
    if (!_running) return;
    _set(RelayStatus.unreachable);
    final seconds = min(60, 1 << min(_attempt++, 6));
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () => unawaited(_open()));
  }

  void _closeChannels() {
    for (final c in _channels.values) {
      c.ended();
    }
    _channels.clear();
  }

  Future<void> _receive(WebSocket socket, Object? data) async {
    if (data is List<int>) {
      if (data.length < 5 || data[0] != _kindData) return;
      final id = ByteData.sublistView(Uint8List.fromList(data)).getUint32(1);
      _channels[id]?.received(data.sublist(5));
      return;
    }
    if (data is! String || data == 'pong') return;
    final Map<String, Object?> m;
    try {
      m = (jsonDecode(data) as Map).cast<String, Object?>();
    } on Object {
      return;
    }
    switch (m['t']) {
      case 'get':
        await _get(
          socket,
          m['r']! as int,
          m['p']! as String,
          m['e'] as String?,
        );
      case 'open':
        final id = m['c']! as int;
        final channel = _RelayedSocket(id, socket);
        _channels[id] = channel;
        unawaited(server.serveSocket(channel, relayed: true));
      case 'text':
        _channels[m['c']]?.received(m['d']);
      case 'close':
        _channels.remove(m['c'])?.ended();
    }
  }

  static const int _kindData = 1;
  static const int _kindBody = 2;
  static const int _chunk = 256 * 1024;

  Future<void> _get(WebSocket socket, int r, String path, String? etag) async {
    final WebFile file;
    try {
      file = await server.file(path, etag: etag, base: '/${phoneId(secret)}/');
    } on Object {
      socket
        ..add(jsonEncode({'t': 'res', 'r': r, 's': 500}))
        ..add(jsonEncode({'t': 'end', 'r': r}));
      return;
    }
    socket.add(
      jsonEncode({'t': 'res', 'r': r, 's': file.status, 'h': file.headers}),
    );
    final body = file.body;
    if (body != null) {
      final buffer = BytesBuilder(copy: false);
      void flush() {
        if (buffer.isEmpty) return;
        socket.add(frame(_kindBody, r, buffer.takeBytes()));
      }

      await for (final chunk in body) {
        buffer.add(chunk);
        if (buffer.length >= _chunk) flush();
      }
      flush();
    }
    socket.add(jsonEncode({'t': 'end', 'r': r}));
  }

  /// `[kind][id: u32][payload]`, the relay's binary envelope.
  static Uint8List frame(int kind, int id, List<int> payload) {
    final out = Uint8List(5 + payload.length);
    ByteData.sublistView(out)
      ..setUint8(0, kind)
      ..setUint32(1, id);
    out.setRange(5, out.length, payload);
    return out;
  }
}

/// One browser's socket, carried inside the phone's relay socket.
class _RelayedSocket implements FrameSocket {
  _RelayedSocket(this._id, this._relay);

  final int _id;
  final WebSocket _relay;
  final _in = StreamController<Object?>();

  void received(Object? frame) {
    if (!_in.isClosed) _in.add(frame);
  }

  void ended() => unawaited(_in.close());

  @override
  Stream<Object?> get incoming => _in.stream;

  @override
  void add(Object frame) {
    if (_relay.readyState != WebSocket.open) return;
    if (frame is String) {
      _relay.add(jsonEncode({'t': 'text', 'c': _id, 'd': frame}));
    } else if (frame is List<int>) {
      _relay.add(RelayConnection.frame(RelayConnection._kindData, _id, frame));
    }
  }

  @override
  Future<void> close() async {
    if (_in.isClosed) return;
    await _in.close();
    if (_relay.readyState == WebSocket.open) {
      _relay.add(jsonEncode({'t': 'close', 'c': _id}));
    }
  }
}
