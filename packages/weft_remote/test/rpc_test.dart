import 'package:test/test.dart';
import 'package:weft_remote/weft_remote.dart';

void main() {
  test('a call is answered, an error carries its code', () async {
    final pair = linkedPair();
    final server = RpcPeer(
      pair.a,
      handlers: {
        'add': (p) async => (p['a']! as int) + (p['b']! as int),
        'boom': (_) async => throw const RemoteException('nope', 'why'),
      },
    );
    final client = RpcPeer(pair.b);
    expect(await client.call('add', {'a': 2, 'b': 3}), 5);
    await expectLater(
      client.call('boom'),
      throwsA(isA<RemoteException>().having((e) => e.code, 'code', 'nope')),
    );
    await expectLater(
      client.call('missing'),
      throwsA(
        isA<RemoteException>().having(
          (e) => e.code,
          'code',
          RemoteException.unknownMethod,
        ),
      ),
    );
    await server.close();
  });

  test('pushed events arrive in order', () async {
    final pair = linkedPair();
    final seen = <Object?>[];
    final server = RpcPeer(pair.a);
    RpcPeer(pair.b, onEvent: (name, data) => seen.add('$name:$data'));
    server
      ..emit('state', 1)
      ..emit('state', 2);
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['state:1', 'state:2']);
  });

  test('pending calls fail when the link goes away', () async {
    final pair = linkedPair();
    RpcPeer(
      pair.a,
      handlers: {
        'slow': (_) => Future<Object?>.delayed(const Duration(days: 1)),
      },
    );
    final client = RpcPeer(pair.b);
    final call = client.call('slow');
    await client.close();
    await expectLater(
      call,
      throwsA(
        isA<RemoteException>().having(
          (e) => e.code,
          'code',
          RemoteException.disconnected,
        ),
      ),
    );
  });
}
