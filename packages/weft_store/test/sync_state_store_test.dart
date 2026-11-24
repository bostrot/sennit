import 'package:flutter_test/flutter_test.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  late WeftDatabase db;
  late SyncStateStore store;

  setUp(() {
    db = WeftDatabase.openAt(':memory:');
    store = SyncStateStore(db);
  });

  tearDown(() => db.dispose());

  test('replaces every row at once and reads them back', () {
    store.replaceAll([
      (key: 's:a', value: '1', hlc: 'h1', observed: '1', tracked: true),
      (key: 'm:x|y', value: null, hlc: 'h2', observed: null, tracked: false),
    ]);
    store.replaceAll([
      (key: 's:a', value: '2', hlc: 'h3', observed: '2', tracked: true),
    ]);
    final rows = store.load();
    expect(rows, hasLength(1));
    expect(rows.single.value, '2');
    expect(rows.single.tracked, isTrue);
  });

  test('lists every setting for comparison', () {
    final settings = SettingsStore(db)
      ..setString('appearance.theme_mode', 'dark')
      ..setBool('rail.multi_select', value: true);
    expect(settings.all(), {
      'appearance.theme_mode': 'dark',
      'rail.multi_select': 'true',
    });
  });
}
