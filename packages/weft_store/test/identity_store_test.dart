import 'package:flutter_test/flutter_test.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  late WeftDatabase db;
  late IdentityStore store;

  setUp(() {
    db = WeftDatabase.openAt(':memory:');
    store = IdentityStore(db);
  });

  tearDown(() => db.dispose());

  NetworkHandle handle(
    String id, {
    ChatNetwork network = ChatNetwork.whatsapp,
    String? contactId,
    String? phone,
  }) {
    return NetworkHandle(
      id: id,
      network: network,
      remoteId: phone ?? id,
      matrixUserId: '@${network.id}_$id:example.org',
      roomId: '!${id}_room:example.org',
      displayName: id,
      phoneE164: phone,
      unifiedContactId: contactId,
    );
  }

  group('handles', () {
    test('round-trips an unassigned handle', () {
      store.upsertHandle(handle('a'));

      final loaded = store.loadHandles();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'a');
      expect(loaded.single.unifiedContactId, isNull);
    });

    // Regression: the identity graph mints contact ids in memory, but nothing
    // inserted the matching `unified_contact` row, so persisting a *merged*
    // handle blew up with `FOREIGN KEY constraint failed`. Found by running on
    // a real device, not by any unit test — this is that test.
    test('persists a handle that belongs to a contact', () {
      store.upsertHandle(handle('a', contactId: 'contact_0'));

      final loaded = store.loadHandles();
      expect(loaded.single.unifiedContactId, 'contact_0');
    });

    test('assigning a contact after the fact also works', () {
      store.upsertHandle(handle('a'));
      store.setContact('a', 'contact_7');

      expect(store.loadHandles().single.unifiedContactId, 'contact_7');
    });

    test('saveAssignments writes a whole partition', () {
      store.upsertHandles([handle('a'), handle('b'), handle('c')]);
      store.saveAssignments({'a': 'c1', 'b': 'c1', 'c': 'c2'});

      final byId = {for (final h in store.loadHandles()) h.id: h};
      expect(byId['a']!.unifiedContactId, 'c1');
      expect(byId['b']!.unifiedContactId, 'c1');
      expect(byId['c']!.unifiedContactId, 'c2');
    });

    test('a sync refresh does not clear an existing merge', () {
      store.upsertHandle(handle('a', contactId: 'c1'));
      // Sync hands back the same handle with no contact id, as it always does.
      store.upsertHandle(handle('a'));

      expect(
        store.loadHandles().single.unifiedContactId,
        'c1',
        reason: 'a refresh must never undo a merge the user made',
      );
    });

    test('updates mutable fields on re-upsert', () {
      store.upsertHandle(handle('a'));
      store.upsertHandle(
        handle('a', phone: '+4915112345678', network: ChatNetwork.signal),
      );

      final loaded = store.loadHandles().single;
      expect(loaded.phoneE164, '+4915112345678');
      expect(loaded.network, ChatNetwork.signal);
      expect(store.loadHandles(), hasLength(1));
    });
  });

  group('decisions', () {
    test('round-trips merge and rejection verdicts', () {
      final at = DateTime.utc(2026, 8, 16);
      store.saveDecisions([
        (pair: 'a|b', verdict: 'merged', source: 'user', decidedAt: at),
        (pair: 'c|d', verdict: 'rejected', source: 'user', decidedAt: at),
      ]);

      final loaded = {for (final d in store.loadDecisions()) d.pair: d};
      expect(loaded['a|b']!.verdict, 'merged');
      expect(loaded['c|d']!.verdict, 'rejected');
      expect(loaded['a|b']!.decidedAt.isAtSameMomentAs(at), isTrue);
      expect(
        loaded['a|b']!.decidedAt.isUtc,
        isTrue,
        reason: 'stored instants come back zone-normalised',
      );
    });

    test('a later verdict replaces the earlier one for the same pair', () {
      store.saveDecision((
        pair: 'a|b',
        verdict: 'merged',
        source: 'user',
        decidedAt: DateTime.utc(2026, 8, 15),
      ));
      store.saveDecision((
        pair: 'a|b',
        verdict: 'rejected',
        source: 'user',
        decidedAt: DateTime.utc(2026, 8, 16),
      ));

      expect(store.loadDecisions(), hasLength(1));
      expect(
        store.loadDecisions().single.verdict,
        'rejected',
        reason: 'an unmerge must supersede the merge that preceded it',
      );
    });
  });

  group('chat preferences', () {
    test('round-trips a send-network choice', () {
      store.setSendNetwork('merged:anna', ChatNetwork.signal);

      expect(store.sendNetworkFor('merged:anna'), ChatNetwork.signal);
      expect(store.loadSendNetworks(), {'merged:anna': ChatNetwork.signal});
    });

    test('is null for a chat with no choice', () {
      expect(store.sendNetworkFor('unknown'), isNull);
    });

    test('clearing a choice removes it from the map', () {
      store.setSendNetwork('c', ChatNetwork.signal);
      store.setSendNetwork('c', null);

      expect(store.sendNetworkFor('c'), isNull);
      expect(store.loadSendNetworks(), isEmpty);
    });
  });
}
