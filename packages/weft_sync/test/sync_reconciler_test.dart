import 'dart:math';

import 'package:test/test.dart';
import 'package:weft_sync/weft_sync.dart';

/// One device: its local values, its sync records and its clock.
class _Device {
  _Device(this.name, {required int Function() now})
    : clock = HlcClock(name, now: now);

  final String name;
  final HlcClock clock;
  final Map<String, String> local = {};
  Map<String, SyncRecord> state = {};

  /// A round against [snapshot]; returns the document to upload, if any.
  SyncDocument? round(SyncDocument? snapshot) {
    final r = reconcile(
      state: state,
      local: Map.of(local),
      remote: snapshot,
      clock: clock,
    );
    for (final MapEntry(:key, :value) in r.apply.entries) {
      if (value == null) {
        local.remove(key);
      } else {
        local[key] = value;
      }
    }
    state = r.state;
    return r.upload ? r.document : null;
  }

  Map<String, String> synced({bool secrets = false}) => {
    for (final MapEntry(:key, :value) in local.entries)
      if (SyncPolicy.inScope(key, secrets: secrets)) key: value,
  };
}

const theme = 's:appearance.theme_mode';
const model = 's:ai.llm_model';
const pushKey = 's:notify.push_key';
const secretsGate = 's:sync.secrets';
const apiKey = 'x:llm_api_key';

void main() {
  var now = 1000;
  int clock() => now += 7;

  SyncDocument? server;
  void sync(_Device d) => server = d.round(server) ?? server;

  setUp(() {
    now = 1000;
    server = null;
  });

  test('a setting changed on the phone reaches the desktop', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local[theme] = 'dark';
    sync(phone);
    sync(desk);
    expect(desk.local[theme], 'dark');
  });

  test('device-local settings never leave the device', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local[pushKey] = 'fcm-token';
    sync(phone);
    sync(desk);
    expect(server?.entries.containsKey(pushKey) ?? false, isFalse);
    expect(desk.local.containsKey(pushKey), isFalse);
  });

  test('a removal is not undone by a device that still has the value', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local[model] = 'llama';
    sync(phone);
    sync(desk);
    phone.local.remove(model);
    sync(phone);
    sync(desk);
    sync(phone);
    expect(desk.local.containsKey(model), isFalse);
    expect(phone.local.containsKey(model), isFalse);
  });

  test('a device joining adopts what is shared and adds what only it has', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local[theme] = 'dark';
    sync(phone);
    desk.local[theme] = 'light';
    desk.local[model] = 'qwen';
    sync(desk);
    sync(phone);
    expect(desk.local[theme], 'dark');
    expect(phone.local[model], 'qwen');
  });

  test('merge and unmerge made offline on two devices converge', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local['m:a|b'] = 'merged|user';
    phone.local['m:b|c'] = 'merged|user';
    sync(phone);
    sync(desk);
    // Both offline from the same snapshot: the desktop unmerges a from b,
    // the phone merges a with c and, later, splits b from c.
    final snapshot = server;
    desk.local['m:a|b'] = 'rejected|user';
    desk.local['m:b|c'] = 'merged|auto';
    final fromDesk = desk.round(snapshot);
    phone.local['m:a|c'] = 'merged|user';
    phone.local['m:b|c'] = 'rejected|user';
    final fromPhone = phone.round(snapshot);
    // The desktop's upload lands first and the phone's overwrites it.
    server = fromDesk;
    server = fromPhone;
    for (var i = 0; i < 3; i++) {
      sync(desk);
      sync(phone);
    }
    expect(desk.synced(), phone.synced());
    expect(desk.local['m:a|b'], 'rejected|user');
    expect(desk.local['m:a|c'], 'merged|user');
    // Both edited b|c; the later edit wins on both devices.
    expect(desk.local['m:b|c'], 'rejected|user');
  });

  test('secrets travel only while the shared switch is on', () {
    final phone = _Device('phone', now: clock);
    final desk = _Device('desk', now: clock);
    phone.local[apiKey] = 'sk-1';
    sync(phone);
    expect(server?.entries.containsKey(apiKey) ?? false, isFalse);

    phone.local[secretsGate] = 'true';
    sync(phone);
    sync(phone);
    expect(server!.entries.containsKey(apiKey), isTrue);
    sync(desk);
    sync(desk);
    expect(desk.local[apiKey], 'sk-1');

    desk.local[secretsGate] = 'false';
    sync(desk);
    sync(phone);
    expect(server!.entries.containsKey(apiKey), isFalse);
    // Turning sync off never deletes the key from a device's keychain.
    expect(phone.local[apiKey], 'sk-1');
    expect(desk.local[apiKey], 'sk-1');
  });

  test('random interleavings with lost updates converge', () {
    for (var seed = 0; seed < 200; seed++) {
      now = 1000;
      final rng = Random(seed);
      final devices = [
        for (final n in ['phone', 'desk', 'tablet']) _Device(n, now: clock),
      ];
      final keys = [
        theme,
        model,
        's:merge.suggest_threshold',
        'm:a|b',
        'm:b|c',
        'c:!room',
      ];
      var shared = server = null as SyncDocument?;
      for (var step = 0; step < 40; step++) {
        final d = devices[rng.nextInt(devices.length)];
        switch (rng.nextInt(3)) {
          case 0:
            final key = keys[rng.nextInt(keys.length)];
            if (rng.nextInt(4) == 0) {
              d.local.remove(key);
            } else {
              d.local[key] = 'v${rng.nextInt(5)}';
            }
          case 1:
            // A round against a stale snapshot whose upload may clobber
            // another device's — the lost-update case account data allows.
            final upload = d.round(rng.nextBool() ? shared : server);
            if (upload != null) server = upload;
          default:
            shared = server;
        }
        now += rng.nextInt(3);
      }
      for (var pass = 0; pass < 4; pass++) {
        for (final d in devices) {
          sync(d);
        }
      }
      for (final d in devices.skip(1)) {
        expect(d.synced(), devices.first.synced(), reason: 'seed $seed');
      }
    }
  });
}
