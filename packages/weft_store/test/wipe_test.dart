import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  late Directory directory;
  late WeftDatabase db;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('weft-wipe');
    db = WeftDatabase.openAt(p.join(directory.path, 'weft.db'));
  });

  tearDown(() {
    db.dispose();
    directory.deleteSync(recursive: true);
  });

  WeftMessage message(String body) => WeftMessage(
    eventId: r'$event',
    roomId: '!room:example.org',
    network: ChatNetwork.whatsapp,
    senderId: '@peer:example.org',
    senderName: 'Peer',
    timestamp: DateTime.utc(2026, 11, 22),
    kind: MessageKind.text,
    isOwn: false,
    body: body,
  );

  test('a wipe leaves the schema and nothing else', () async {
    final settings = SettingsStore(db)..setString('appearance.theme', 'dark');
    final search = SearchStore(db)
      ..indexMessage(message('the zebracorn is in the garden'), chatId: 'c1');
    expect(await search.keywordSearch('zebracorn'), hasLength(1));
    final version = db.schemaVersion;

    db.wipe();

    expect(settings.getString('appearance.theme'), isNull);
    expect(await search.keywordSearch('zebracorn'), isEmpty);
    expect(db.schemaVersion, version);
    // Still usable, as after a fresh install.
    settings.setString('appearance.theme', 'light');
    expect(settings.getString('appearance.theme'), 'light');
  });

  test('the deleted text is gone from the file, not only from the tables', () {
    SearchStore(
      db,
    ).indexMessage(message('the zebracorn is in the garden'), chatId: 'c1');

    db.wipe();

    for (final file in directory.listSync().whereType<File>()) {
      final bytes = String.fromCharCodes(file.readAsBytesSync());
      expect(bytes, isNot(contains('zebracorn')), reason: file.path);
    }
  });
}
