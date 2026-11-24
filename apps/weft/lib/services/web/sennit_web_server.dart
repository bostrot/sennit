import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:weft_remote/weft_remote.dart';

import '../../data/chat_repository.dart';
import '../remote/remote_chat_host.dart';
import 'pairing_registry.dart';

/// One browser connected right now.
class WebSession {
  WebSession(this.browser, this.host, {this.relayed = false});
  final PairedBrowser browser;
  final RemoteChatHost host;

  /// Came through the relay rather than the LAN listener.
  final bool relayed;
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

  /// Opens the LAN listener. Relayed browsers need no listener; they arrive
  /// through [serveSocket] and [file].
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

  /// Closes the LAN listener and ends the sessions that came through it.
  Future<void> stopListening() async {
    final server = _server;
    _server = null;
    for (final s in [..._sessions]) {
      if (!s.relayed) s.host.dispose();
    }
    await server?.close(force: true);
    _changes.add(null);
  }

  /// Closes everything: the listener and every session, relayed or not.
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
        await serveSocket(
          _IoSocket(await WebSocketTransformer.upgrade(request)),
        );
        return;
      }
      final response = request.response;
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final file = await this.file(
        Uri.decodeComponent(request.uri.path),
        etag: request.headers.value('if-none-match'),
      );
      response.statusCode = file.status;
      file.headers.forEach(response.headers.set);
      if (file.body != null && request.method == 'GET') {
        await response.addStream(file.body!);
      }
      await response.close();
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

  /// One of the bundle's files, for a GET of [path] — over the LAN listener
  /// or through the relay.
  ///
  /// [base] is where the app lives on the host serving it: `/` here, the
  /// phone's own path on a relay. The page's `<base href>` is set to it, so
  /// every file the page loads resolves under the same path.
  Future<WebFile> file(String path, {String? etag, String base = '/'}) async {
    const common = {
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'X-Robots-Tag': 'noindex',
    };
    if (path == '/' || path.isEmpty) path = '/index.html';
    final file = File(p.normalize(p.join(bundle.path, path.substring(1))));
    // Nothing outside the bundle, and nothing that is not a plain file.
    if (!p.isWithin(bundle.path, file.path) ||
        p.basename(file.path).startsWith('.') ||
        !file.existsSync()) {
      return const WebFile(HttpStatus.notFound, common);
    }
    // Revalidated on every load, answered with 304 while unchanged: a new
    // bundle — an app update — must never run against a cached old one, and
    // over a relay a 304 is all the second load costs.
    final stat = file.statSync();
    final tag =
        '"${stat.size.toRadixString(36)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(36)}"';
    final headers = {
      ...common,
      'Content-Type':
          _types[p.extension(file.path)] ?? 'application/octet-stream',
      'Cache-Control': 'no-cache',
      'ETag': tag,
    };
    if (etag == tag) return WebFile(HttpStatus.notModified, headers);
    if (p.basename(file.path) == 'index.html') {
      final html = (await file.readAsString()).replaceFirst(
        RegExp(r'<base href="[^"]*">'),
        '<base href="$base">',
      );
      return WebFile(HttpStatus.ok, headers, Stream.value(utf8.encode(html)));
    }
    return WebFile(HttpStatus.ok, headers, file.openRead());
  }

  /// Runs the handshake on a new browser socket — straight from the LAN
  /// listener or relayed — and, if the browser is let in, serves it.
  Future<void> serveSocket(FrameSocket socket, {bool relayed = false}) async {
    final frames = StreamIterator(socket.incoming);
    String? pairingFor;
    try {
      if (!await frames.moveNext().timeout(const Duration(seconds: 15)) ||
          frames.current is! String) {
        throw const HandshakeException(HandshakeFailure.protocol);
      }
      final hello = frames.current! as String;
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
      final rest = StreamController<Object?>();
      unawaited(() async {
        while (await frames.moveNext()) {
          rest.add(frames.current);
        }
        await rest.close();
      }());
      final link = SecureLink(socket, result.session, incoming: rest.stream);
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
      final session = WebSession(browser, host, relayed: relayed);
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
      await frames.cancel();
      await socket.close();
    } on TimeoutException {
      await frames.cancel();
      await socket.close();
    }
  }
}

/// A file's answer, ready for either transport.
class WebFile {
  const WebFile(this.status, this.headers, [this.body]);
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>>? body;
}

class _IoSocket implements FrameSocket {
  _IoSocket(this._socket);
  final WebSocket _socket;

  @override
  Stream<Object?> get incoming => _socket;

  @override
  void add(Object frame) {
    if (_socket.readyState == WebSocket.open) _socket.add(frame);
  }

  @override
  Future<void> close() => _socket.close();
}
