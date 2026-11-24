import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:weft_remote/weft_remote.dart';
import 'package:web/web.dart' as web;

import '../../data/remote_chat_repository.dart';
import 'phone_connection_errors.dart';

const _phoneKey = 'sennit.web.phone';
const _browserSeed = 'sennit.web.browser';

/// Reads the pairing from the address, connects to the phone that served
/// this page, and hands back its repository.
///
/// The QR code's address carries the phone's key and a one-time token in the
/// fragment, which browsers never send to a server — so neither the tunnel
/// nor the relay ever sees them. They are taken out of the address bar as soon
/// as they are read, so the token is not left in history or a bookmark.
Future<RemoteChatRepository> connectToPhone() async {
  final storage = web.window.localStorage;
  final fragment = Uri.splitQueryString(
    web.window.location.hash.replaceFirst('#', ''),
  );
  String? token;
  if (fragment['p'] case final phone?) {
    storage.setItem(_phoneKey, phone);
    token = fragment['t'];
    // Flutter's router keeps its own entry in the state; keep it.
    web.window.history.replaceState(
      web.window.history.state,
      '',
      web.window.location.pathname + web.window.location.search,
    );
  }
  final phone = storage.getItem(_phoneKey);
  if (phone == null) {
    throw const PhoneConnectionException(PhoneConnectionProblem.notPaired);
  }

  final StaticKey self;
  if (storage.getItem(_browserSeed) case final seed?) {
    self = await StaticKey.fromSeed(_decode(seed));
  } else {
    self = await StaticKey.generate();
    storage.setItem(_browserSeed, await self.exportSeed());
  }

  final location = web.window.location;
  final scheme = location.protocol == 'https:' ? 'wss' : 'ws';
  final socket = _BrowserSocket(
    web.WebSocket('$scheme://${location.host}${location.pathname}ws'),
  );
  try {
    await socket.opened.timeout(const Duration(seconds: 10));
  } on Object {
    throw const PhoneConnectionException(PhoneConnectionProblem.unreachable);
  }

  final initiator = HandshakeInitiator(
    self: self,
    phonePublicKey: _decode(phone, url: true),
    name: _browserName(),
    pairingToken: token,
  );
  final frames = StreamIterator(socket.incoming);
  socket.add(await initiator.start());
  final SecureSession session;
  try {
    if (!await frames.moveNext().timeout(const Duration(seconds: 15))) {
      throw const PhoneConnectionException(PhoneConnectionProblem.notPaired);
    }
    session = await initiator.finish(frames.current! as String);
  } on HandshakeException {
    await socket.close();
    throw const PhoneConnectionException(PhoneConnectionProblem.notPaired);
  } on TimeoutException {
    await socket.close();
    throw const PhoneConnectionException(PhoneConnectionProblem.unreachable);
  }

  final rest = StreamController<Object?>();
  unawaited(() async {
    while (await frames.moveNext()) {
      rest.add(frames.current);
    }
    await rest.close();
  }());
  final repository = RemoteChatRepository(
    SecureLink(socket, session, incoming: rest.stream),
  );
  try {
    await repository.connect();
  } on RemoteException {
    throw const PhoneConnectionException(
      PhoneConnectionProblem.versionMismatch,
    );
  }
  return repository;
}

/// Drops this browser's pairing and reloads to the connect screen; the next
/// connection needs a fresh QR code from the phone.
void forgetPhone() {
  web.window.localStorage
    ..removeItem(_phoneKey)
    ..removeItem(_browserSeed);
  web.window.location.reload();
}

List<int> _decode(String s, {bool url = false}) {
  final normalized = url ? s.replaceAll('-', '+').replaceAll('_', '/') : s;
  final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  return Uri.parse('data:;base64,$padded').data!.contentAsBytes();
}

/// A name the phone lists this browser under: the browser and the platform,
/// nothing that identifies the person.
String _browserName() {
  final ua = web.window.navigator.userAgent;
  final browser = ua.contains('Firefox/')
      ? 'Firefox'
      : ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('Chrome/')
      ? 'Chrome'
      : ua.contains('Safari/')
      ? 'Safari'
      : 'Browser';
  final platform = ua.contains('Mac OS')
      ? 'macOS'
      : ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Android')
      ? 'Android'
      : ua.contains('Linux')
      ? 'Linux'
      : ua.contains('iPhone') || ua.contains('iPad')
      ? 'iOS'
      : '';
  return platform.isEmpty ? browser : '$browser · $platform';
}

class _BrowserSocket implements FrameSocket {
  _BrowserSocket(this._socket) {
    _socket.binaryType = 'arraybuffer';
    _socket.onopen = ((web.Event _) {
      if (!_open.isCompleted) _open.complete();
    }).toJS;
    _socket.onerror = ((web.Event _) {
      if (!_open.isCompleted) _open.completeError(StateError('socket error'));
    }).toJS;
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data.isA<JSString>()) {
        _in.add((data! as JSString).toDart);
      } else if (data.isA<JSArrayBuffer>()) {
        _in.add((data! as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    _socket.onclose = ((web.CloseEvent _) {
      if (!_open.isCompleted) _open.completeError(StateError('closed'));
      unawaited(_in.close());
    }).toJS;
  }

  final web.WebSocket _socket;
  final _open = Completer<void>();
  final _in = StreamController<Object?>();

  Future<void> get opened => _open.future;

  @override
  Stream<Object?> get incoming => _in.stream;

  @override
  void add(Object frame) {
    if (_socket.readyState != web.WebSocket.OPEN) return;
    if (frame is String) {
      _socket.send(frame.toJS);
    } else if (frame is List<int>) {
      _socket.send(Uint8List.fromList(frame).toJS);
    }
  }

  @override
  Future<void> close() async => _socket.close();
}
