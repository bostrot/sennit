import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:weft_remote/weft_remote.dart';

import '../../data/chat_repository.dart';
import '../remote/remote_chat_host.dart';
import 'pairing_registry.dart';

/// One browser connected right now.
class WebSession {
  WebSession(this.browser, this.host);
  final PairedBrowser browser;
  final RemoteChatHost host;
}

/// Serves Sennit Web from this device: the verified bundle's files over plain
/// HTTP, and the app's data over one end-to-end encrypted WebSocket per
/// browser.
///
/// The files are public — they are on the release page — so serving them in
/// the clear gives nothing away. Everything else goes through the handshake in
/// `weft_remote`'s `SecureChannel`, which only a paired browser, or one
/// holding the pairing token from the QR code on this screen, gets through.
class SennitWebServer {
  SennitWebServer({
    required this.bundle,
    required this.key,
    required this.registry,
    required this.repository,
    required this.deviceName,
    this.lan = true,
    this.port = 0,
    this.extraHandlers = const {},
    this.settings,
  });

  /// The unpacked, verified bundle.
  final Directory bundle;
  final StaticKey key;
  final PairingRegistry registry;
  final ChatRepository Function() repository;
  final String deviceName;

  /// Every interface when true; loopback only otherwise (for a tunnel or a
  /// relay running on this machine).
  final bool lan;
  final int port;

  /// Calls beyond the chat repository — media, settings — wired by the app.
  final Map<String, RpcHandler> extraHandlers;

  /// The preferences each browser mirrors.
  final Map<String, String> Function()? settings;

  HttpServer? _server;
  final List<WebSession> _sessions = [];
  final _changes = StreamController<void>.broadcast();

  /// Fires when a browser connects, disconnects or pairs.
  Stream<void> get changes => _changes.stream;

  List<WebSession> get sessions => List.unmodifiable(_sessions);

  int? get boundPort => _server?.port;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(
      lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
    );
    server.listen((request) => unawaited(_handle(request)));
    _server = server;
    _changes.add(null);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final s in [..._sessions]) {
      s.host.dispose();
    }
    _sessions.clear();
    await server?.close(force: true);
    _changes.add(null);
  }

  /// Ends every live session of a browser whose pairing was just removed.
  void disconnect(String browserKey) {
    for (final s in [..._sessions]) {
      if (s.browser.key == browserKey) s.host.dispose();
    }
  }

  /// This device's addresses a browser on the same network can reach.
  static Future<List<String>> lanAddresses() async {
    final out = <String>[];
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in iface.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) out.add(a.address);
      }
    }
    return out;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        await _socket(await WebSocketTransformer.upgrade(request));
        return;
      }
      await _file(request);
    } on Object {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The connection is already gone.
      }
    }
  }

  static const Map<String, String> _types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.mjs': 'text/javascript',
    '.json': 'application/json',
    '.wasm': 'application/wasm',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
    '.svg': 'image/svg+xml',
    '.css': 'text/css',
    '.otf': 'font/otf',
    '.ttf': 'font/ttf',
    '.woff2': 'font/woff2',
    '.frag': 'application/octet-stream',
    '.bin': 'application/octet-stream',
    '.symbols': 'application/octet-stream',
  };

  Future<void> _file(HttpRequest request) async {
    final response = request.response
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.set('Referrer-Policy', 'no-referrer')
      ..headers.set('X-Robots-Tag', 'noindex');
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      return response.close();
    }
    var path = Uri.decodeComponent(request.uri.path);
    if (path == '/' || path.isEmpty) path = '/index.html';
    final file = File(p.normalize(p.join(bundle.path, path.substring(1))));
    // Nothing outside the bundle, and nothing that is not a plain file.
    if (!p.isWithin(bundle.path, file.path) ||
        p.basename(file.path).startsWith('.') ||
        !file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    // Revalidated on every load, answered with 304 while unchanged: a new
    // bundle — an app update — must never run against a cached old one, and
    // over a relay a 304 is all the second load costs.
    final stat = file.statSync();
    final etag =
        '"${stat.size.toRadixString(36)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(36)}"';
    response.headers
      ..contentType = ContentType.parse(
        _types[p.extension(file.path)] ?? 'application/octet-stream',
      )
      ..set('Cache-Control', 'no-cache')
      ..set('ETag', etag);
    if (request.headers.value('if-none-match') == etag) {
      response.statusCode = HttpStatus.notModified;
      return response.close();
    }
    if (request.method == 'HEAD') return response.close();
    await response.addStream(file.openRead());
    return response.close();
  }

  Future<void> _socket(WebSocket socket) async {
    final rest = StreamController<Object?>();
    final first = Completer<String>();
    final sub = socket.listen(
      (data) {
        if (!first.isCompleted) {
          if (data is String) {
            first.complete(data);
          } else {
            first.completeError(
              const HandshakeException(HandshakeFailure.protocol),
            );
          }
        } else {
          rest.add(data);
        }
      },
      onDone: () {
        if (!first.isCompleted) {
          first.completeError(
            const HandshakeException(HandshakeFailure.protocol),
          );
        }
        unawaited(rest.close());
      },
      cancelOnError: true,
    );

    String? pairingFor;
    try {
      final hello = await first.future.timeout(const Duration(seconds: 15));
      final result = await HandshakeResponder(self: key, name: deviceName)
          .respond(
            hello,
            admit: (browserKey, name, token) async {
              if (registry.isPaired(browserKey)) return true;
              if (registry.tokenMatches(token)) {
                pairingFor = name;
                return true;
              }
              return false;
            },
          );
      socket.add(result.reply);
      final link = SecureLink(
        _IoSocket(socket),
        result.session,
        incoming: rest.stream,
      );
      // Paired only once the browser proved its key with a frame that opens.
      unawaited(
        link.authenticated.then((_) {
          if (pairingFor != null) {
            registry.pair(result.session.peerKey, pairingFor!);
          } else {
            registry.touch(result.session.peerKey);
          }
          _changes.add(null);
        }),
      );
      final host = RemoteChatHost(
        repository(),
        link,
        extraHandlers: extraHandlers,
        settings: settings,
      );
      final browser = PairedBrowser(
        key: result.session.peerKey,
        name: result.session.peerName,
        pairedAt: DateTime.now(),
      );
      final session = WebSession(browser, host);
      _sessions.add(session);
      _changes.add(null);
      unawaited(
        host.done.then((_) {
          _sessions.remove(session);
          _changes.add(null);
        }),
      );
    } on HandshakeException catch (e) {
      if (e.failure == HandshakeFailure.notPaired) {
        socket.add(HandshakeResponder.notPairedReply());
      }
      await sub.cancel();
      await socket.close(WebSocketStatus.policyViolation);
    } on TimeoutException {
      await sub.cancel();
      await socket.close(WebSocketStatus.policyViolation);
    }
  }
}

class _IoSocket implements FrameSocket {
  _IoSocket(this._socket);
  final WebSocket _socket;

  @override
  Stream<Object?> get incoming => throw StateError('read through SecureLink');

  @override
  void add(Object frame) {
    if (_socket.readyState == WebSocket.open) _socket.add(frame);
  }

  @override
  Future<void> close() => _socket.close();
}
