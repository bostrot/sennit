import 'dart:async';

/// One end of an ordered, reliable message pipe — an encrypted WebSocket in
/// the app, a pair of controllers in tests. Frames are JSON-shaped maps.
abstract interface class RemoteLink {
  Stream<Map<String, Object?>> get incoming;

  void send(Map<String, Object?> frame);

  Future<void> close();
}

/// Two links wired to each other, in memory.
({RemoteLink a, RemoteLink b}) linkedPair() {
  // Each controller is closed by the link that writes to it.
  // ignore: close_sinks
  final ab = StreamController<Map<String, Object?>>();
  // ignore: close_sinks
  final ba = StreamController<Map<String, Object?>>();
  return (a: _MemoryLink(ba.stream, ab), b: _MemoryLink(ab.stream, ba));
}

class _MemoryLink implements RemoteLink {
  _MemoryLink(this.incoming, this._out);

  @override
  final Stream<Map<String, Object?>> incoming;
  final StreamController<Map<String, Object?>> _out;

  @override
  void send(Map<String, Object?> frame) {
    if (!_out.isClosed) _out.add(frame);
  }

  @override
  Future<void> close() => _out.close();
}

/// A call the other end refused or failed. [code] is stable and
/// machine-readable; [message] is for logs, never shown as is.
class RemoteException implements Exception {
  const RemoteException(this.code, [this.message = '']);

  final String code;
  final String message;

  /// The link went away with the call unanswered.
  static const String disconnected = 'disconnected';

  /// The other end has no such method — an older phone, usually.
  static const String unknownMethod = 'unknown_method';

  /// The method threw.
  static const String failed = 'failed';

  @override
  String toString() =>
      'RemoteException($code${message.isEmpty ? '' : ': $message'})';
}

typedef RpcHandler = Future<Object?> Function(Map<String, Object?> params);

/// Requests, answers and pushed events over a [RemoteLink], in both
/// directions: the browser calls the phone, the phone pushes state.
///
/// Frames: `{t: req, id, m, p}`, `{t: res, id, r}`, `{t: err, id, code, msg}`
/// and `{t: ev, n, d}`. Anything else is ignored, so a newer peer may add
/// frame types without breaking an older one.
class RpcPeer {
  RpcPeer(
    this._link, {
    Map<String, RpcHandler> handlers = const {},
    void Function(String name, Object? data)? onEvent,
  }) : _handlers = handlers,
       _onEvent = onEvent {
    _sub = _link.incoming.listen(_receive, onDone: _closed);
  }

  final RemoteLink _link;
  final Map<String, RpcHandler> _handlers;
  final void Function(String name, Object? data)? _onEvent;
  late final StreamSubscription<Map<String, Object?>> _sub;
  final Map<int, Completer<Object?>> _pending = {};
  final _done = Completer<void>();
  int _nextId = 1;
  bool _isClosed = false;

  /// Completes when the link closes, from either side.
  Future<void> get done => _done.future;

  bool get isClosed => _isClosed;

  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    if (_isClosed) {
      return Future.error(const RemoteException(RemoteException.disconnected));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _link.send({'t': 'req', 'id': id, 'm': method, 'p': params});
    return completer.future;
  }

  void emit(String name, Object? data) {
    if (_isClosed) return;
    _link.send({'t': 'ev', 'n': name, 'd': data});
  }

  Future<void> close() async {
    await _link.close();
    _closed();
  }

  void _receive(Map<String, Object?> frame) {
    switch (frame['t']) {
      case 'req':
        unawaited(_serve(frame));
      case 'res':
        _pending.remove(frame['id'])?.complete(frame['r']);
      case 'err':
        _pending
            .remove(frame['id'])
            ?.completeError(
              RemoteException(
                (frame['code'] as String?) ?? RemoteException.failed,
                (frame['msg'] as String?) ?? '',
              ),
            );
      case 'ev':
        final name = frame['n'];
        if (name is String) _onEvent?.call(name, frame['d']);
    }
  }

  Future<void> _serve(Map<String, Object?> frame) async {
    final id = frame['id'];
    final method = frame['m'];
    final params = frame['p'];
    final handler = method is String ? _handlers[method] : null;
    if (handler == null) {
      _link.send({
        't': 'err',
        'id': id,
        'code': RemoteException.unknownMethod,
        'msg': '$method',
      });
      return;
    }
    try {
      final result = await handler(
        params is Map ? params.cast<String, Object?>() : const {},
      );
      if (!_isClosed) _link.send({'t': 'res', 'id': id, 'r': result});
    } on RemoteException catch (e) {
      if (!_isClosed) {
        _link.send({'t': 'err', 'id': id, 'code': e.code, 'msg': e.message});
      }
    } on Object catch (e) {
      if (!_isClosed) {
        _link.send({
          't': 'err',
          'id': id,
          'code': RemoteException.failed,
          'msg': e.runtimeType.toString(),
        });
      }
    }
  }

  void _closed() {
    if (_isClosed) return;
    _isClosed = true;
    unawaited(_sub.cancel());
    for (final c in _pending.values) {
      c.completeError(const RemoteException(RemoteException.disconnected));
    }
    _pending.clear();
    _done.complete();
  }
}
