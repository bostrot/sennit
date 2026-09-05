/// The `.braid` archive: one encrypted file holding a user's cross-network
/// history, and the only way that history gets off the device.
///
/// Braid keeps conversations from every network in one local store. That is the
/// feature, and it is also the exposure: the unified view — which handles are
/// the same person, what a bridge said before it was shut down, a voice note
/// transcribed once and never again — exists nowhere but on the device, and
/// until this package existed there was no way to get it out. A homeserver can
/// hand back Matrix rooms. It cannot hand back the merges.
///
/// Four pieces:
///
/// * [ArchiveHeader] and friends in `format.dart` — the container. Versioned,
///   and **parseable before the passphrase**, so that "this is not a Braid
///   archive", "this build is too old to read it" and "that passphrase is
///   wrong" are three different sentences instead of one shrug.
/// * `crypto.dart` — Argon2id from the passphrase, XChaCha20-Poly1305 over
///   chunked frames, the header bound in as associated data.
/// * [BackupSource] and [writeArchive] — export, streaming, cancellable,
///   leaving no partial file behind.
/// * [BackupSink] and [importArchive] — restore, merging by default,
///   transactional, and degrading rather than refusing when the archive knows
///   more than this build does.
///
/// **What is not in an archive: E2EE device keys, access tokens, bridge
/// credentials.** Restoring history is not cloning a session, and a file that
/// did both would be an account takeover protected by whatever passphrase
/// someone picked in a hurry. `export.dart` says more; so does
/// `docs/architecture/backup-restore.md`.
///
/// Pure Dart, and deliberately knows nothing about SQL or Flutter: the format
/// is decided in one test file rather than on a device, and the adapters onto
/// Braid's actual tables live in `weft_store`, where the schema already is.
library;

// Consumers import this barrel, never src/.
export 'src/crypto.dart'
    show
        ArchiveAuthenticationException,
        ArchiveKey,
        FrameCipher,
        deriveArchiveKey,
        newCipherParameters,
        newKdfParameters,
        randomBytes;
export 'src/export.dart';
export 'src/format.dart';
export 'src/import.dart';
export 'src/records.dart';
export 'src/stream.dart';
