import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:weft_sync/weft_sync.dart';

SyncDocument _doc(int size) => SyncDocument({
  for (var i = 0; i < size; i++)
    's:key.$i': SyncEntry('value $i ${'x' * (i % 40)}', Hlc(i, 0, 'n')),
});

void main() {
  final secret = base64.encode(List<int>.generate(32, (i) => i));
  final other = base64.encode(List<int>.generate(32, (i) => 255 - i));

  Future<SyncDocument> roundTrip(SyncCipher c, SealedDocument s) =>
      c.open(s.manifest, (i) => i < s.parts.length ? s.parts[i] : null);

  test('opens what it sealed', () async {
    final cipher = await SyncCipher.fromBackupSecret(secret);
    final doc = _doc(10);
    final sealed = await cipher.seal(doc);
    expect((await roundTrip(cipher, sealed)).sameAs(doc), isTrue);
    expect(jsonEncode(sealed.manifest), isNot(contains('value')));
  });

  test('splits a large document into parts under the event limit', () async {
    final cipher = await SyncCipher.fromBackupSecret(secret);
    // Random values so gzip cannot fold them into one part.
    final rng = Random(1);
    final doc = SyncDocument({
      for (var i = 0; i < 3000; i++)
        'm:$i': SyncEntry(
          base64.encode(List<int>.generate(40, (_) => rng.nextInt(256))),
          Hlc(i, 0, 'n'),
        ),
    });
    final sealed = await cipher.seal(doc);
    expect(sealed.parts.length, greaterThan(1));
    for (final part in sealed.parts) {
      expect(jsonEncode(part).length, lessThan(60 * 1024));
    }
    expect((await roundTrip(cipher, sealed)).sameAs(doc), isTrue);
  });

  test('tells another key apart from damage', () async {
    final mine = await SyncCipher.fromBackupSecret(secret);
    final theirs = await SyncCipher.fromBackupSecret(other);
    final sealed = await theirs.seal(_doc(3));
    expect(
      () => roundTrip(mine, sealed),
      throwsA(
        isA<SyncOpenException>().having(
          (e) => e.failure,
          'failure',
          SyncOpenFailure.otherKey,
        ),
      ),
    );
  });

  test('refuses a tampered document', () async {
    final cipher = await SyncCipher.fromBackupSecret(secret);
    final sealed = await cipher.seal(_doc(3));
    final data = sealed.parts.first['data']! as String;
    final bytes = base64.decode(data);
    bytes[20] ^= 1;
    final tampered = base64.encode(bytes);
    final manifest = {
      ...sealed.manifest,
      // The attacker can recompute the digest; the AEAD tag still fails.
      'sha256': base64.encode(
        (await Sha256().hash(utf8.encode(tampered))).bytes,
      ),
    };
    expect(
      () => cipher.open(
        manifest,
        (_) => {...sealed.parts.first, 'data': tampered},
      ),
      throwsA(
        isA<SyncOpenException>().having(
          (e) => e.failure,
          'failure',
          SyncOpenFailure.corrupt,
        ),
      ),
    );
  });

  test('waits for parts from an older or newer revision', () async {
    final cipher = await SyncCipher.fromBackupSecret(secret);
    final first = await cipher.seal(_doc(3));
    final second = await cipher.seal(_doc(4));
    expect(
      () => cipher.open(second.manifest, (_) => first.parts.first),
      throwsA(
        isA<SyncOpenException>().having(
          (e) => e.failure,
          'failure',
          SyncOpenFailure.incomplete,
        ),
      ),
    );
  });
}
