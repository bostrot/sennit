import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

import 'sync_document.dart';

/// The account-data type the sealed document is published under, and the
/// prefix of the types its parts go under.
const String kSyncEventType = 'de.bostrot.sennit.sync.v1';

/// Why a sealed document could not be opened.
enum SyncOpenFailure {
  /// Sealed under a different key — another backup, or a backup this device
  /// has not been given yet.
  otherKey,

  /// The parts do not belong together yet: one arrived, the rest has not.
  incomplete,

  /// Authentication failed or the content is malformed. Never applied.
  corrupt,
}

class SyncOpenException implements Exception {
  const SyncOpenException(this.failure);
  final SyncOpenFailure failure;

  @override
  String toString() => 'SyncOpenException(${failure.name})';
}

/// The sealed document as account-data contents: a manifest and its parts.
class SealedDocument {
  const SealedDocument(this.manifest, this.parts);

  final Map<String, Object?> manifest;

  /// Contents of `$kSyncEventType.<index>`, in index order.
  final List<Map<String, Object?>> parts;
}

/// Seals the shared document so the homeserver carrying it learns nothing but
/// its size and when it changed.
///
/// The key is derived from the account's key-backup secret, which every device
/// that can read the user's encrypted history already holds — it arrives with
/// verification or the recovery key. No second secret to set up, back up or
/// lose, and a device that cannot read the backup cannot read this either,
/// which is the right trust level for merge verdicts and API keys.
class SyncCipher {
  SyncCipher._(this._key, this.keyId);

  /// Account data is capped at the 64 KiB event limit; a part stays well under.
  static const int partChars = 48 * 1024;

  static final _aes = AesGcm.with256bits();
  static const _aad = kSyncEventType;

  final SecretKey _key;

  /// A short fingerprint of the key, so a device can tell "sealed for another
  /// backup" from "damaged" without trying to decrypt.
  final String keyId;

  /// Derives the key from the base64 key-backup secret.
  static Future<SyncCipher> fromBackupSecret(String backupSecret) async {
    final ikm = base64.decode(base64.normalize(backupSecret));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(ikm),
      nonce: utf8.encode('sennit'),
      info: utf8.encode(kSyncEventType),
    );
    final bytes = await key.extractBytes();
    final digest = await Sha256().hash(bytes);
    final keyId = base64Url.encode(digest.bytes.sublist(0, 8));
    return SyncCipher._(SecretKey(bytes), keyId);
  }

  Future<SealedDocument> seal(SyncDocument document, {Random? random}) async {
    final rng = random ?? Random.secure();
    final plain = GZipEncoder().encodeBytes(utf8.encode(document.encode()));
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await _aes.encrypt(
      plain,
      secretKey: _key,
      nonce: nonce,
      aad: utf8.encode(_aad),
    );
    final sealed = base64.encode(box.concatenation());
    final digest = await Sha256().hash(utf8.encode(sealed));
    final rev = base64Url.encode(
      List<int>.generate(9, (_) => rng.nextInt(256)),
    );
    final parts = <Map<String, Object?>>[
      for (var i = 0; i < sealed.length; i += partChars)
        {
          'rev': rev,
          'data': sealed.substring(i, min(i + partChars, sealed.length)),
        },
    ];
    return SealedDocument({
      'v': 1,
      'kid': keyId,
      'rev': rev,
      'parts': parts.length,
      'sha256': base64.encode(digest.bytes),
    }, parts);
  }

  /// Opens what [seal] produced. [partOf] returns the contents of part
  /// `index`, or null when the server has not delivered it.
  Future<SyncDocument> open(
    Map<String, Object?> manifest,
    Map<String, Object?>? Function(int index) partOf,
  ) async {
    if (manifest['v'] != 1) {
      throw const SyncOpenException(SyncOpenFailure.corrupt);
    }
    if (manifest['kid'] != keyId) {
      throw const SyncOpenException(SyncOpenFailure.otherKey);
    }
    final rev = manifest['rev'];
    final count = manifest['parts'];
    final expected = manifest['sha256'];
    if (rev is! String || count is! int || count < 1 || expected is! String) {
      throw const SyncOpenException(SyncOpenFailure.corrupt);
    }
    final joined = StringBuffer();
    for (var i = 0; i < count; i++) {
      final part = partOf(i);
      final data = part?['data'];
      if (part == null || part['rev'] != rev || data is! String) {
        throw const SyncOpenException(SyncOpenFailure.incomplete);
      }
      joined.write(data);
    }
    final sealed = joined.toString();
    final digest = await Sha256().hash(utf8.encode(sealed));
    if (base64.encode(digest.bytes) != expected) {
      throw const SyncOpenException(SyncOpenFailure.incomplete);
    }
    try {
      final box = SecretBox.fromConcatenation(
        base64.decode(sealed),
        nonceLength: 12,
        macLength: 16,
      );
      final plain = await _aes.decrypt(
        box,
        secretKey: _key,
        aad: utf8.encode(_aad),
      );
      final json = utf8.decode(
        GZipDecoder().decodeBytes(Uint8List.fromList(plain)),
      );
      return SyncDocument.decode(json);
    } on SecretBoxAuthenticationError {
      throw const SyncOpenException(SyncOpenFailure.corrupt);
    } on FormatException {
      throw const SyncOpenException(SyncOpenFailure.corrupt);
    }
  }
}
