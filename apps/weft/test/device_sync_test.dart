import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/services/sync/store_sync_local.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

/// Account data, shared by both devices.
class _Channel implements SyncChannel {
  _Channel(this.data);
  final Map<String, Map<String, Object?>> data;

  @override
  Future<String?> backupSecret() async =>
      base64.encode(List<int>.generate(32, (i) => i));

  @override
  Map<String, Object?>? read(String type) => data[type];

  @override
  Future<void> write(String type, Map<String, Object?> content) async =>
      data[type] = jsonDecode(jsonEncode(content)) as Map<String, Object?>;
}

void main() {
  late WeftStores phone;
  late WeftStores desk;
  late Map<String, Map<String, Object?>> server;
  var mergesReloaded = 0;

  DeviceSync syncFor(WeftStores stores, String id) => DeviceSync(
    channel: _Channel(server),
    local: StoreSyncLocal(
      stores,
      onSettingsChanged: () {},
      onMergesChanged: () => mergesReloaded++,
    ),
    deviceId: id,
  );

  setUp(() {
    phone = WeftStores.inMemory();
    desk = WeftStores.inMemory();
    server = {};
    mergesReloaded = 0;
  });

  tearDown(() {
    phone.dispose();
    desk.dispose();
  });

  test('a merge made on the phone is in the desktop store', () async {
    phone.identity.saveDecision((
      pair: '@a:x|@b:x',
      verdict: 'merged',
      source: 'user',
      decidedAt: DateTime.utc(2026),
    ));
    phone.identity.setSendNetwork('!room:x', ChatNetwork.signal);
    phone.settings.setString(WeftSettings.themeMode, 'dark');

    await syncFor(phone, 'phone').run();
    await syncFor(desk, 'desk').run();

    expect(desk.identity.loadDecisions().single.verdict, 'merged');
    expect(desk.identity.sendNetworkFor('!room:x'), ChatNetwork.signal);
    expect(desk.settings.getString(WeftSettings.themeMode), 'dark');
    expect(mergesReloaded, greaterThan(0));
  });

  test('an unmerge on the desktop reaches the phone', () async {
    final phoneSync = syncFor(phone, 'phone');
    final deskSync = syncFor(desk, 'desk');
    phone.identity.saveDecision((
      pair: '@a:x|@b:x',
      verdict: 'merged',
      source: 'user',
      decidedAt: DateTime.utc(2026),
    ));
    await phoneSync.run();
    await deskSync.run();
    desk.identity.saveDecision((
      pair: '@a:x|@b:x',
      verdict: 'rejected',
      source: 'user',
      decidedAt: DateTime.utc(2026, 2),
    ));
    await deskSync.run();
    await phoneSync.run();
    expect(phone.identity.loadDecisions().single.verdict, 'rejected');
  });

  test('a draft follows to the other device, and so does sending it', () async {
    var draftsReloaded = 0;
    DeviceSync draftSync(WeftStores stores, String id) => DeviceSync(
      channel: _Channel(server),
      local: StoreSyncLocal(
        stores,
        onSettingsChanged: () {},
        onMergesChanged: () {},
        onDraftsChanged: () => draftsReloaded++,
      ),
      deviceId: id,
    );
    final phoneSync = draftSync(phone, 'phone');
    final deskSync = draftSync(desk, 'desk');

    phone.settings.setString('draft.!room:x', 'see you at');
    await phoneSync.run();
    await deskSync.run();
    expect(desk.settings.getString('draft.!room:x'), 'see you at');
    expect(draftsReloaded, 1);

    // Sent from the desktop: the draft is gone there, then everywhere.
    desk.settings.remove('draft.!room:x');
    await deskSync.run();
    await phoneSync.run();
    expect(phone.settings.getString('draft.!room:x'), isNull);
  });

  test('device-local settings and the sync switch stay put', () async {
    phone.settings
      ..setString(WeftSettings.notifyPushKey, 'token')
      ..setString(WeftSettings.transcriptionLocalModel, 'whisper-base')
      ..setBool(WeftSettings.syncEnabled, value: true);
    await syncFor(phone, 'phone').run();
    await syncFor(desk, 'desk').run();
    expect(desk.settings.getString(WeftSettings.notifyPushKey), isNull);
    expect(
      desk.settings.getString(WeftSettings.transcriptionLocalModel),
      isNull,
    );
    expect(desk.settings.getString(WeftSettings.syncEnabled), isNull);
  });

  test('secrets are collected only with their switch on', () {
    phone.llmApiKey = 'sk-test';
    final local = StoreSyncLocal(
      phone,
      onSettingsChanged: () {},
      onMergesChanged: () {},
    );
    expect(local.collect().keys, isNot(contains('x:${SecretStore.llmApiKey}')));
    phone.settings.setBool(WeftSettings.syncSecrets, value: true);
    expect(local.collect()['x:${SecretStore.llmApiKey}'], 'sk-test');
  });

  test('nothing on the server is readable', () async {
    phone.settings.setString(WeftSettings.llmModel, 'very-secret-model');
    await syncFor(phone, 'phone').run();
    expect(jsonEncode(server), isNot(contains('very-secret-model')));
  });
}
