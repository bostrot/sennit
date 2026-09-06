import 'package:flutter_test/flutter_test.dart';
import 'package:weft/data/matrix_chat_repository.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

/// The comparison that decides whether a handle is written to SQLite again.
///
/// It runs for every DM in the account on every rebuild, and the rebuilds run
/// on the UI thread — so getting it wrong is not a wrong answer on a screen,
/// it is either a launch that rewrites the whole identity table before the
/// inbox draws, or a rename that never reaches the database.
void main() {
  NetworkHandle handle({
    String id = '@whatsapp_4915112345678:example.org',
    ChatNetwork network = ChatNetwork.whatsapp,
    String remoteId = '4915112345678',
    String matrixUserId = '@whatsapp_4915112345678:example.org',
    String? roomId = '!portal:example.org',
    String? displayName = 'Anna',
    String? avatarUrl = 'https://example.org/_matrix/media/anna.png',
    String? phoneE164 = '+4915112345678',
    String? email = 'anna@example.org',
    int? avatarDHash = 0x0f1e2d3c4b5a6978,
    String? unifiedContactId = 'contact_1',
  }) => NetworkHandle(
    id: id,
    network: network,
    remoteId: remoteId,
    matrixUserId: matrixUserId,
    roomId: roomId,
    displayName: displayName,
    avatarUrl: avatarUrl,
    phoneE164: phoneE164,
    email: email,
    avatarDHash: avatarDHash,
    unifiedContactId: unifiedContactId,
  );

  test('a handle that has not moved fingerprints the same', () {
    expect(handleFingerprint(handle()), handleFingerprint(handle()));
  });

  /// Every column [IdentityStore.upsertHandle] writes, one at a time.
  ///
  /// This is the property the skip rests on: if a field can change without the
  /// fingerprint changing, the write is skipped and the row keeps the old
  /// value — silently, until something else about the handle moves. `roomId`
  /// is why this group is exhaustive rather than a spot check: it was outside
  /// the older fingerprint, and only the fact that the map started empty at
  /// launch — and rewrote everything anyway — kept that from showing.
  final moved = <String, NetworkHandle>{
    'network': handle(network: ChatNetwork.signal),
    'remoteId': handle(remoteId: '4915100000000'),
    'matrixUserId': handle(matrixUserId: '@signal_abc:example.org'),
    'roomId': handle(roomId: '!other:example.org'),
    'displayName': handle(displayName: 'Anna B.'),
    'avatarUrl': handle(avatarUrl: 'https://example.org/other.png'),
    'phoneE164': handle(phoneE164: '+4915100000000'),
    'email': handle(email: 'anna@other.example'),
    'avatarDHash': handle(avatarDHash: 0x1122334455667788),
    'unifiedContactId': handle(unifiedContactId: 'contact_2'),
  };

  group('a changed column changes the fingerprint', () {
    moved.forEach((field, changed) {
      test(field, () {
        expect(handleFingerprint(changed), isNot(handleFingerprint(handle())));
      });
    });
  });

  group('a cleared column changes the fingerprint', () {
    final cleared = <String, NetworkHandle>{
      'roomId': handle(roomId: null),
      'displayName': handle(displayName: null),
      'avatarUrl': handle(avatarUrl: null),
      'phoneE164': handle(phoneE164: null),
      'email': handle(email: null),
      'avatarDHash': handle(avatarDHash: null),
      'unifiedContactId': handle(unifiedContactId: null),
    };
    cleared.forEach((field, changed) {
      test(field, () {
        expect(handleFingerprint(changed), isNot(handleFingerprint(handle())));
      });
    });
  });

  test('text cannot walk across a field boundary', () {
    // The failure mode of joining fields with a character a value may contain:
    // a display name that swallows the next field reads as the pair that was
    // actually stored, and a rename to it is never written. Display names come
    // from bridges and from strangers, so every candidate separator is one of
    // them — `|` here, but the same holds for a comma or a NUL.
    expect(
      handleFingerprint(handle(displayName: 'Anna', avatarUrl: 'B')),
      isNot(handleFingerprint(handle(displayName: 'Anna|B', avatarUrl: null))),
    );
    expect(
      handleFingerprint(handle(displayName: 'Anna', avatarUrl: 'B')),
      isNot(
        handleFingerprint(handle(displayName: 'Anna\u0000B', avatarUrl: null)),
      ),
    );
  });

  test('an empty column is not the word for one', () {
    // A contact who has genuinely called themselves "null" is not a contact
    // whose name the database does not hold.
    expect(
      handleFingerprint(handle(displayName: null)),
      isNot(handleFingerprint(handle(displayName: 'null'))),
    );
  });

  test('a stored handle fingerprints as the handle that was stored', () {
    // The seed the repository's constructor plants is computed from rows read
    // back out of SQLite, and it is compared against fingerprints computed
    // from handles built out of the live session. The two only mean the same
    // thing while a round trip through the store is lossless — a column the
    // store drops or retypes would make the seed claim a row is current when
    // it is not, and that handle would stop being written for the rest of the
    // run.
    final db = WeftDatabase.openAt(':memory:');
    addTearDown(db.dispose);
    final store = IdentityStore(db);

    final written = handle();
    store.upsertHandle(written);

    expect(
      handleFingerprint(store.loadHandles().single),
      handleFingerprint(written),
    );
  });
}
