/// Turning a passphrase into a key, and a byte stream into authenticated
/// frames.
///
/// Two primitives, both from `package:cryptography` and neither written here.
/// The workspace had no crypto library to reuse — the Matrix SDK does its own
/// in Rust behind `flutter_vodozemac`, which is a Flutter plugin and therefore
/// unreachable from a package that must run under plain `dart test` — so this
/// is a new dependency taken deliberately rather than a hand-rolled AEAD. The
/// thing being protected is every message the user has ever received.
///
/// **Nothing in this file writes a passphrase or a derived key anywhere.** No
/// `toString` returns key material, no exception message quotes it, and the
/// derived key never reaches settings, the database or a crash report. The one
/// place bytes leave here is into the cipher.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'format.dart';

/// A key derived from a passphrase, and the parameters it came from.
///
/// Paired rather than passed separately because using a key with the wrong
/// parameters is not an error anything can detect — it just produces a MAC
/// failure that reads to the user as a wrong passphrase.
@immutable
class ArchiveKey {
  const ArchiveKey._(this.key, this.kdf);

  final SecretKey key;
  final KdfParameters kdf;

  /// Deliberately says nothing.
  ///
  /// The default would print the runtime type and the hash code, which is
  /// harmless — but a future field that is not harmless would start leaking
  /// into every log line that interpolated one of these, silently. Overriding
  /// now makes that impossible later.
  @override
  String toString() => 'ArchiveKey(<redacted>)';
}

/// Derives the archive key from [passphrase] under [kdf].
///
/// Argon2id, at the parameters the *header* names rather than at this build's
/// defaults — that is the whole reason [KdfParameters] is serialised. An
/// archive written when the default was 32 MiB must still open on a build whose
/// default has climbed to 256 MiB, and it does, because this reads the number
/// out of the file.
///
/// Unicode-normalising the passphrase is deliberately **not** done. It is the
/// kind of helpfulness that turns into a locked archive: a passphrase typed on
/// one keyboard and normalised by one build, then typed identically on another
/// and normalised by a build whose Unicode tables moved, derives a different
/// key with nothing to say why. The bytes the user typed are the bytes that are
/// hashed.
Future<ArchiveKey> deriveArchiveKey(
  String passphrase,
  KdfParameters kdf, {
  Argon2id? algorithm,
}) async {
  final argon2id =
      algorithm ??
      Argon2id(
        parallelism: kdf.parallelism,
        // `memory` is a count of 1 kB blocks, which is what `memoryKiB` says.
        memory: kdf.memoryKiB,
        iterations: kdf.iterations,
        hashLength: kdf.keyLength,
      );

  final key = await argon2id.deriveKeyFromPassword(
    password: passphrase,
    nonce: kdf.salt,
  );
  return ArchiveKey._(key, kdf);
}

/// Fresh [KdfParameters] at this build's defaults, with a random salt.
KdfParameters newKdfParameters({Random? random}) =>
    KdfParameters(salt: randomBytes(KdfParameters.saltLength, random: random));

/// Fresh [CipherParameters] with a random nonce prefix.
CipherParameters newCipherParameters({
  Random? random,
  int frameSize = kDefaultFrameSize,
}) => CipherParameters(
  noncePrefix: randomBytes(CipherParameters.noncePrefixLength, random: random),
  frameSize: frameSize,
);

/// [count] cryptographically random bytes.
///
/// [Random.secure] by default. The [random] parameter exists so a test can pin
/// a salt and a nonce and assert on exact bytes; production never passes it,
/// and passing a non-secure [Random] here would make every archive from this
/// device derivable from the ones before it.
Uint8List randomBytes(int count, {Random? random}) {
  final source = random ?? Random.secure();
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    out[i] = source.nextInt(256);
  }
  return out;
}

/// Thrown when a frame does not authenticate.
///
/// One exception for four causes — wrong passphrase, flipped ciphertext bit,
/// edited header, reordered frames — because a MAC cannot tell them apart and
/// pretending otherwise would be a lie in the type system. `import.dart` turns
/// this into a user-facing failure, and it is the *first* frame's failure that
/// gets reported as a wrong passphrase: by the second frame the key has already
/// proven itself, so a failure there is a damaged file.
class ArchiveAuthenticationException implements Exception {
  const ArchiveAuthenticationException(this.frameIndex);

  final int frameIndex;

  @override
  String toString() =>
      'ArchiveAuthenticationException(frame $frameIndex did not authenticate)';
}

/// Encrypts and decrypts the body's frames.
///
/// **The construction, and what each part of it buys:**
///
/// * The nonce is `noncePrefix ‖ uint64BE(frameIndex)`. Sixteen random bytes
///   per archive and eight of counter means one derived key can encrypt 2^64
///   frames with no nonce ever repeating — and XChaCha20's 24-byte nonce is
///   what makes a random prefix that long safe in the first place, which is why
///   it and not ChaCha20 or AES-GCM.
/// * The associated data is `headerBytes ‖ uint64BE(frameIndex) ‖ finalFlag`.
///   The header has no MAC of its own, so binding it here is what makes
///   tampering with the KDF parameters — dropping Argon2id's memory cost to
///   nothing, say — fail rather than succeed at a weaker setting. The index
///   makes reordered or replayed frames fail. The flag makes truncation fail.
/// * **Truncation is the one an AEAD does not catch by itself.** Every frame of
///   a shortened archive authenticates perfectly; the file is simply missing
///   the end. So the last frame is sealed with a flag byte of 1 and every other
///   with 0, and a reader that reaches end-of-file without having opened a
///   final frame reports a truncated archive. Cutting an archive short and
///   re-flagging the new last frame requires the key.
class FrameCipher {
  FrameCipher({
    required this.key,
    required this.cipher,
    required this.headerBytes,
    Cipher? algorithm,
  }) : _algorithm = algorithm ?? Xchacha20.poly1305Aead();

  final ArchiveKey key;
  final CipherParameters cipher;

  /// The plaintext header exactly as it sits on disk. See
  /// [ArchiveHeader.bytes] for why this is the bytes and not a re-encoding.
  final Uint8List headerBytes;

  final Cipher _algorithm;

  /// [plaintext] as `ciphertext ‖ tag`.
  Future<Uint8List> seal(
    List<int> plaintext, {
    required int frameIndex,
    required bool isFinal,
  }) async {
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: key.key,
      nonce: _nonce(frameIndex),
      aad: _aad(frameIndex, isFinal: isFinal),
    );

    final out = BytesBuilder(copy: false)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// The plaintext behind `ciphertext ‖ tag`.
  ///
  /// Throws [ArchiveAuthenticationException] rather than the library's own
  /// error type, so callers of this package never have to import
  /// `package:cryptography` to catch a wrong passphrase.
  Future<Uint8List> open(
    Uint8List sealed, {
    required int frameIndex,
    required bool isFinal,
  }) async {
    if (sealed.length < CipherParameters.tagLength) {
      throw ArchiveAuthenticationException(frameIndex);
    }
    final split = sealed.length - CipherParameters.tagLength;

    try {
      final clear = await _algorithm.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, split),
          nonce: _nonce(frameIndex),
          mac: Mac(Uint8List.sublistView(sealed, split)),
        ),
        secretKey: key.key,
        aad: _aad(frameIndex, isFinal: isFinal),
      );
      return clear is Uint8List ? clear : Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw ArchiveAuthenticationException(frameIndex);
    }
  }

  Uint8List _nonce(int frameIndex) {
    final out = Uint8List(CipherParameters.nonceLength)
      ..setRange(0, CipherParameters.noncePrefixLength, cipher.noncePrefix)
      ..setRange(
        CipherParameters.noncePrefixLength,
        CipherParameters.nonceLength,
        uint64Bytes(frameIndex),
      );
    return out;
  }

  Uint8List _aad(int frameIndex, {required bool isFinal}) {
    final out = BytesBuilder(copy: false)
      ..add(headerBytes)
      ..add(uint64Bytes(frameIndex))
      ..addByte(isFinal ? 1 : 0);
    return out.toBytes();
  }
}
