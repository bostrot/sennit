import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:weft_backup/weft_backup.dart';

import 'support/fakes.dart';

Uint8List headerFor(CipherParameters cipher, KdfParameters kdf) =>
    encodeArchiveHeader(
      kdf: kdf,
      cipher: cipher,
      preview: ArchivePreview(
        createdAt: DateTime.utc(2026, 8, 28),
        appVersion: 'test',
      ),
    );

Future<FrameCipher> cipherFor({
  String passphrase = 'correct horse battery staple',
  KdfParameters? kdf,
  CipherParameters? cipher,
  Uint8List? headerBytes,
}) async {
  final k = kdf ?? cheapKdf();
  final c = cipher ?? CipherParameters(noncePrefix: Uint8List(16));
  return FrameCipher(
    key: await deriveArchiveKey(passphrase, k),
    cipher: c,
    headerBytes: headerBytes ?? headerFor(c, k),
  );
}

void main() {
  group('key derivation', () {
    test('the same passphrase and salt give the same key', () async {
      final kdf = cheapKdf();
      final a = await cipherFor(kdf: kdf);
      final b = await cipherFor(kdf: kdf);

      final sealed = await a.seal([1, 2, 3], frameIndex: 0, isFinal: true);
      expect(
        await b.open(sealed, frameIndex: 0, isFinal: true),
        equals([1, 2, 3]),
      );
    });

    test('a different salt gives a different key', () async {
      // Why a salt is per-archive: without this, two backups from one
      // passphrase share a key and a table built for one answers the other.
      final a = await cipherFor(kdf: cheapKdf(seed: 1));
      final sealed = await a.seal([9], frameIndex: 0, isFinal: true);

      final b = await cipherFor(kdf: cheapKdf(seed: 200));
      expect(
        () => b.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('a different passphrase gives a different key', () async {
      final kdf = cheapKdf();
      final a = await cipherFor(kdf: kdf, passphrase: 'one');
      final sealed = await a.seal([9], frameIndex: 0, isFinal: true);

      final b = await cipherFor(kdf: kdf, passphrase: 'onf');
      expect(
        () => b.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('the passphrase is not normalised behind the user\'s back', () async {
      // Two spellings of "café": precomposed U+00E9, and a plain "e"
      // followed by a combining acute. Written as escapes rather than as
      // literals so that no editor, formatter or checkout filter can quietly
      // normalise this file and turn the case into a string compared with
      // itself.
      const precomposed = 'café';
      const combining = 'café';
      expect(precomposed, isNot(combining), reason: 'the fixture is the test');

      final kdf = cheapKdf();
      final a = await cipherFor(kdf: kdf, passphrase: precomposed);
      final sealed = await a.seal([1], frameIndex: 0, isFinal: true);

      // They must derive *different* keys. A build that normalised, reading an
      // archive written by one that did not — or by one whose Unicode tables
      // have since moved — would refuse a passphrase the user typed correctly,
      // with nothing to say why.
      final b = await cipherFor(kdf: kdf, passphrase: combining);
      expect(
        () => b.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('a key never prints itself', () async {
      final key = await deriveArchiveKey('hunter2', cheapKdf());
      expect(key.toString(), 'ArchiveKey(<redacted>)');
      expect(key.toString(), isNot(contains('hunter2')));
    });
  });

  group('frame sealing', () {
    test('an empty frame round-trips', () async {
      // The final frame of an archive whose body fell exactly on a boundary.
      final cipher = await cipherFor();
      final sealed = await cipher.seal(
        const <int>[],
        frameIndex: 4,
        isFinal: true,
      );
      expect(await cipher.open(sealed, frameIndex: 4, isFinal: true), isEmpty);
    });

    test('a flipped ciphertext bit fails', () async {
      final cipher = await cipherFor();
      final sealed = await cipher.seal(
        List<int>.filled(64, 7),
        frameIndex: 0,
        isFinal: true,
      );
      sealed[10] ^= 0x01;

      expect(
        () => cipher.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('a flipped tag bit fails', () async {
      final cipher = await cipherFor();
      final sealed = await cipher.seal(
        List<int>.filled(64, 7),
        frameIndex: 0,
        isFinal: true,
      );
      sealed[sealed.length - 1] ^= 0x80;

      expect(
        () => cipher.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('a frame shorter than a tag fails rather than underflowing', () async {
      final cipher = await cipherFor();
      expect(
        () => cipher.open(Uint8List(4), frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });
  });

  group('what the associated data buys', () {
    test('a reordered frame fails', () async {
      // The frame index is in both the nonce and the AAD, so frame 3 cannot be
      // replayed as frame 2 — which is what stops an attacker rearranging a
      // conversation without the key.
      final cipher = await cipherFor();
      final sealed = await cipher.seal(
        List<int>.filled(32, 1),
        frameIndex: 3,
        isFinal: false,
      );
      expect(
        () => cipher.open(sealed, frameIndex: 2, isFinal: false),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('re-flagging the last frame fails', () async {
      // Truncation defence: cutting an archive short and claiming the new last
      // frame is final requires the key.
      final cipher = await cipherFor();
      final sealed = await cipher.seal(
        List<int>.filled(32, 1),
        frameIndex: 1,
        isFinal: false,
      );
      expect(
        () => cipher.open(sealed, frameIndex: 1, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });

    test('editing the header fails every frame', () async {
      // The header has no MAC of its own. Binding it as associated data is what
      // makes lowering Argon2id's cost in the file a failure rather than a
      // successful derivation at a weaker setting.
      final kdf = cheapKdf();
      final params = CipherParameters(noncePrefix: Uint8List(16));
      final honest = headerFor(params, kdf);

      final cipher = await cipherFor(
        kdf: kdf,
        cipher: params,
        headerBytes: honest,
      );
      final sealed = await cipher.seal(
        List<int>.filled(32, 1),
        frameIndex: 0,
        isFinal: true,
      );

      final tampered = Uint8List.fromList(honest)..[40] ^= 0x01;
      final attacker = FrameCipher(
        key: await deriveArchiveKey('correct horse battery staple', kdf),
        cipher: params,
        headerBytes: tampered,
      );
      expect(
        () => attacker.open(sealed, frameIndex: 0, isFinal: true),
        throwsA(isA<ArchiveAuthenticationException>()),
      );
    });
  });

  group('nonce discipline', () {
    test('two frames of identical plaintext produce different bytes', () async {
      // If they matched, the nonce were repeating and the keystream with it —
      // the single failure that turns an AEAD into a cipher that leaks by XOR.
      final cipher = await cipherFor();
      final plain = List<int>.filled(128, 0x5A);

      final first = await cipher.seal(plain, frameIndex: 0, isFinal: false);
      final second = await cipher.seal(plain, frameIndex: 1, isFinal: false);
      expect(first, isNot(equals(second)));
    });

    test('the nonce prefix is 16 random bytes and the counter is 8', () {
      expect(
        CipherParameters.noncePrefixLength + 8,
        CipherParameters.nonceLength,
      );
      final params = newCipherParameters();
      expect(params.noncePrefix.length, CipherParameters.noncePrefixLength);
    });

    test('fresh parameters differ from one archive to the next', () {
      final a = newKdfParameters();
      final b = newKdfParameters();
      expect(a.salt, isNot(equals(b.salt)));
      expect(
        newCipherParameters().noncePrefix,
        isNot(equals(newCipherParameters().noncePrefix)),
      );
    });

    test('an injected Random makes bytes reproducible for a test', () {
      expect(
        randomBytes(8, random: Random(42)),
        equals(randomBytes(8, random: Random(42))),
      );
    });
  });
}
