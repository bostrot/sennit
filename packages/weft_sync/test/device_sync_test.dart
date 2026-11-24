import 'dart:convert';

import 'package:test/test.dart';
import 'package:weft_sync/weft_sync.dart';

/// Account data shared by every device of the account.
class _Server {
  final Map<String, Map<String, Object?>> data = {};
}

class _Channel implements SyncChannel {
  _Channel(this.server, this.secret);
  final _Server server;
  String? secret;
  int writes = 0;

  @override
  Future<String?> backupSecret() async => secret;

  @override
  Map<String, Object?>? read(String type) => server.data[type];

  @override
  Future<void> write(String type, Map<String, Object?> content) async {
    writes++;
    // Through JSON, as the homeserver would.
    server.data[type] = jsonDecode(jsonEncode(content)) as Map<String, Object?>;
  }
}

class _Local implements SyncLocal {
  final Map<String, String> values = {};
  Map<String, SyncRecord> state = {};

  @override
  Map<String, String> collect() => Map.of(values);

  @override
  Map<String, SyncRecord> loadState() => state;

  @override
  void saveState(Map<String, SyncRecord> s) => state = s;

  @override
  Future<void> apply(Map<String, String?> changes) async {
    changes.forEach((k, v) => v == null ? values.remove(k) : values[k] = v);
  }
}

void main() {
  final secret = base64.encode(List<int>.generate(32, (i) => i * 3));
  var now = 1000;
  int clock() => now += 5;

  test('two devices converge through sealed account data', () async {
    final server = _Server();
    final phone = _Local()..values['s:appearance.theme_mode'] = 'dark';
    final desk = _Local()..values['m:a|b'] = 'merged|user';
    final phoneSync = DeviceSync(
      channel: _Channel(server, secret),
      local: phone,
      deviceId: 'phone',
      now: clock,
    );
    final deskSync = DeviceSync(
      channel: _Channel(server, secret),
      local: desk,
      deviceId: 'desk',
      now: clock,
    );
    expect(await phoneSync.run(), SyncOutcome.synced);
    expect(await deskSync.run(), SyncOutcome.synced);
    expect(await phoneSync.run(), SyncOutcome.synced);
    expect(phone.values, desk.values);
    expect(jsonEncode(server.data), isNot(contains('dark')));
  });

  test('a round with nothing new writes nothing', () async {
    final server = _Server();
    final channel = _Channel(server, secret);
    final local = _Local()..values['s:rail.multi_select'] = 'true';
    final sync = DeviceSync(channel: channel, local: local, deviceId: 'a');
    await sync.run();
    final writes = channel.writes;
    await sync.run();
    await sync.run();
    expect(channel.writes, writes);
  });

  test('without the backup key nothing is read or written', () async {
    final server = _Server();
    final local = _Local()..values['s:rail.multi_select'] = 'true';
    final sync = DeviceSync(
      channel: _Channel(server, null),
      local: local,
      deviceId: 'a',
    );
    expect(await sync.run(), SyncOutcome.noKey);
    expect(server.data, isEmpty);
  });

  test(
    'a document sealed for another backup is left alone until replaced',
    () async {
      final server = _Server();
      final other = base64.encode(List<int>.generate(32, (i) => 7));
      final a = DeviceSync(
        channel: _Channel(server, other),
        local: _Local()..values['s:rail.multi_select'] = 'true',
        deviceId: 'a',
      );
      await a.run();
      final before = jsonEncode(server.data);
      final local = _Local()..values['s:composer.send_on_enter'] = 'true';
      final b = DeviceSync(
        channel: _Channel(server, secret),
        local: local,
        deviceId: 'b',
      );
      expect(await b.run(), SyncOutcome.otherKey);
      expect(jsonEncode(server.data), before);
      expect(await b.run(replace: true), SyncOutcome.synced);
      expect(await b.run(), SyncOutcome.synced);
    },
  );
}
