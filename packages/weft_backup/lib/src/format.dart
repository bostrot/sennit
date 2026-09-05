/// The `.braid` container: what is on disk, in what order, and which parts a
/// reader may parse before it has the passphrase.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The eight bytes every `.braid` file starts with.
///
/// A magic number rather than trusting the extension, because the file picker
/// hands back whatever the user tapped and "you chose the wrong file" and "you
/// typed the wrong passphrase" must be different sentences. Without this they
/// are the same sentence — a MAC failure — and the user retypes a correct
/// passphrase five times at a holiday photo.
const List<int> kBraidArchiveMagic = <int>[
  0x42, 0x52, 0x41, 0x49, 0x44, 0x42, 0x41, 0x4B, // BRAIDBAK
];

/// The container version this build writes, and the highest major it reads.
///
/// **What a reader older than its writer must do**, which is the ordinary case
/// and not the pathological one — a phone restoring last year's archive, a
/// desktop restoring one written by the phone that updated first:
///
/// * **A higher [ArchiveVersion.minor] is read normally.** Minor is bumped for
///   additions only: a new record type, a new field on an existing record, a
///   new entry in the manifest. Readers skip record types they do not know
///   (counting them into [ArchiveVersion] mismatch reporting rather than
///   failing) and ignore fields they do not know, exactly as
///   `SnapshotCodec.decode` ignores unknown keys. An archive is therefore never
///   rejected for containing more than the reader was taught.
/// * **A higher [ArchiveVersion.major] is refused**, with a typed failure that
///   names the version. Major is reserved for a change to the *container* —
///   the framing, the AEAD construction, the order of the header — which a
///   reader cannot skip past because it cannot find where the next thing
///   starts. Refusing loudly is the honest answer: the alternative is a
///   half-decoded restore that looks like it worked.
///
/// The split matters because these two failures deserve opposite advice.
/// "Update Braid and try again" is right for a major; for a minor it would be a
/// lie, since the restore already worked.
const ArchiveVersion kBraidArchiveFormatVersion = ArchiveVersion(1, 0);

/// The largest plaintext header this reader will parse.
///
/// The header arrives from a file the user picked, so its declared length is
/// attacker-controlled before a single byte has been authenticated — there is
/// no MAC over it until the first frame is opened. 64 KiB is far above any
/// header this format produces (a few hundred bytes) and far below a number
/// that costs anything to allocate by mistake.
const int kMaxHeaderBytes = 64 * 1024;

/// The plaintext bytes an archive may declare per encrypted frame.
///
/// Frames are the streaming unit: an archive is written and read one frame at a
/// time so that a 4 GB backup costs a frame of memory rather than 4 GB of it.
/// 1 MiB is large enough that the 4-byte length prefix and 16-byte tag are
/// noise, and small enough to hold several in flight without noticing.
const int kDefaultFrameSize = 1024 * 1024;

/// The ceiling a reader enforces on a frame it has been told to expect.
///
/// Same reasoning as [kMaxHeaderBytes] and the same reasoning `SnapshotCodec`
/// gives for capping on *both* sides: the writer is the process with memory to
/// spare and the reader is the one the OS kills. A corrupt length field is
/// indistinguishable from a hostile one, and neither should be able to ask for
/// an 8 GB buffer.
const int kMaxFrameSize = 16 * 1024 * 1024;

/// A major/minor container version.
@immutable
class ArchiveVersion implements Comparable<ArchiveVersion> {
  const ArchiveVersion(this.major, this.minor);

  final int major;
  final int minor;

  /// Whether a reader at [kBraidArchiveFormatVersion] can read this.
  ///
  /// Only the major is consulted. See [kBraidArchiveFormatVersion] for why a
  /// newer minor is a normal, successful read.
  bool get isReadable => major <= kBraidArchiveFormatVersion.major;

  /// Whether this archive was written by something that knew more than us.
  bool get isFutureMinor =>
      major == kBraidArchiveFormatVersion.major &&
      minor > kBraidArchiveFormatVersion.minor;

  Map<String, Object?> toJson() => {'major': major, 'minor': minor};

  /// [raw] as a version, or null when it is not one.
  ///
  /// Null rather than a default, because "the header did not say" is a
  /// wrong-file signal and must not quietly become version 1.0.
  static ArchiveVersion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final major = raw['major'];
    final minor = raw['minor'];
    if (major is! int || minor is! int || major < 0 || minor < 0) return null;
    return ArchiveVersion(major, minor);
  }

  @override
  int compareTo(ArchiveVersion other) =>
      major != other.major ? major - other.major : minor - other.minor;

  @override
  bool operator ==(Object other) =>
      other is ArchiveVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

// ---------------------------------------------------------------------- KDF

/// How the passphrase becomes a key, recorded so a future build can raise the
/// cost without orphaning archives written under the old one.
///
/// Every parameter lives in the header rather than in a constant, which is the
/// whole point: Argon2id's memory and time costs should climb as phones get
/// faster, and an archive written in 2026 must still open on the build that
/// climbed. A constant here would mean either never raising the cost or
/// silently failing to open old files.
@immutable
class KdfParameters {
  const KdfParameters({
    required this.salt,
    this.id = argon2id,
    this.memoryKiB = defaultMemoryKiB,
    this.iterations = defaultIterations,
    this.parallelism = defaultParallelism,
    this.keyLength = defaultKeyLength,
  });

  static const String argon2id = 'argon2id';

  /// 64 MiB, 3 passes, 1 lane.
  ///
  /// Chosen against the weakest device Braid supports rather than the fastest:
  /// this runs on a mid-range Android phone, in a foreground isolate, while the
  /// user watches a spinner. 64 MiB is the RFC 9106 second recommended option
  /// and is comfortably survivable there; raising it to the first option's
  /// 2 GiB would make export impossible on the devices that most need a backup.
  static const int defaultMemoryKiB = 64 * 1024;
  static const int defaultIterations = 3;
  static const int defaultParallelism = 1;
  static const int defaultKeyLength = 32;

  /// Sixteen random bytes, so two archives from the same passphrase share no
  /// derived key and neither is answerable by a table built for the other.
  static const int saltLength = 16;

  final String id;
  final Uint8List salt;
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final int keyLength;

  Map<String, Object?> toJson() => {
    'id': id,
    'salt': base64.encode(salt),
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
    'keyLength': keyLength,
  };

  /// [raw] as parameters, or null when any of them is missing or absurd.
  ///
  /// Bounds-checked rather than trusted, because these numbers come out of an
  /// unauthenticated header and drive an allocation: a `memoryKiB` of 2^31 is
  /// an out-of-memory kill dressed up as a backup file. The upper bounds are
  /// generous enough to accept anything a future Braid would plausibly write
  /// and low enough that a hostile file cannot use them as a weapon.
  static KdfParameters? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final salt = _decodeBase64(raw['salt']);
    if (salt == null || salt.isEmpty || salt.length > 64) return null;

    final memoryKiB = raw['memoryKiB'];
    final iterations = raw['iterations'];
    final parallelism = raw['parallelism'];
    final keyLength = raw['keyLength'];
    if (memoryKiB is! int || memoryKiB < 8 || memoryKiB > 1024 * 1024) {
      return null;
    }
    if (iterations is! int || iterations < 1 || iterations > 64) return null;
    if (parallelism is! int || parallelism < 1 || parallelism > 64) return null;
    if (keyLength is! int || keyLength != 32) return null;

    return KdfParameters(
      id: raw['id'] is String ? raw['id'] as String : argon2id,
      salt: salt,
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      keyLength: keyLength,
    );
  }
}

// ------------------------------------------------------------------- cipher

/// The AEAD, its nonce prefix and the frame size the body was written at.
@immutable
class CipherParameters {
  const CipherParameters({
    required this.noncePrefix,
    this.id = xchacha20Poly1305,
    this.frameSize = kDefaultFrameSize,
  });

  static const String xchacha20Poly1305 = 'xchacha20-poly1305';

  /// XChaCha20 takes a 24-byte nonce. Sixteen of those bytes are random per
  /// archive and eight are the frame counter, which is what lets one derived
  /// key encrypt an unbounded number of frames without a nonce ever repeating.
  static const int noncePrefixLength = 16;
  static const int nonceLength = 24;
  static const int tagLength = 16;

  final String id;
  final Uint8List noncePrefix;
  final int frameSize;

  Map<String, Object?> toJson() => {
    'id': id,
    'noncePrefix': base64.encode(noncePrefix),
    'frameSize': frameSize,
  };

  static CipherParameters? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final prefix = _decodeBase64(raw['noncePrefix']);
    if (prefix == null || prefix.length != noncePrefixLength) return null;

    final frameSize = raw['frameSize'];
    if (frameSize is! int || frameSize < 1024 || frameSize > kMaxFrameSize) {
      return null;
    }

    return CipherParameters(
      id: raw['id'] is String ? raw['id'] as String : xchacha20Poly1305,
      noncePrefix: prefix,
      frameSize: frameSize,
    );
  }
}

// ------------------------------------------------------------------ preview

/// The little that an archive says about itself *before* anyone types a
/// passphrase.
///
/// **This is a deliberate, bounded leak and the boundary is the interesting
/// part.** The restore screen has to show something before it asks for a
/// passphrase — a file picker hands back a name and nothing else, and asking
/// someone to unlock a file to find out whether it is the one they meant is how
/// they unlock the wrong one. So a few facts sit outside the ciphertext.
///
/// What is out here is what the file's *size* already tells an observer:
/// roughly how much is in it, whether it carries media, when it was written and
/// by which build. What stays inside, in [ArchiveManifest], is the part size
/// cannot reveal and that would genuinely expose the user: **which networks
/// they are on**. "This person has a Signal account" is a fact worth protecting
/// on its own, and it is not recoverable from a byte count.
///
/// The consequence for the UI is that the restore flow reveals in two steps —
/// this before the passphrase, the manifest after it and before anything is
/// written. That is a better flow anyway: the second step is the last chance to
/// back out, and it should be the one with the detail in it.
@immutable
class ArchivePreview {
  const ArchivePreview({
    required this.createdAt,
    required this.appVersion,
    this.chatCount = 0,
    this.messageCount = 0,
    this.mediaIncluded = false,
    this.totalBytes = 0,
  });

  final DateTime createdAt;

  /// The Braid build that wrote this, for a support conversation. Free text —
  /// never parsed to decide behaviour, which is what [ArchiveVersion] is for.
  final String appVersion;

  final int chatCount;
  final int messageCount;
  final bool mediaIncluded;

  /// The writer's estimate of the finished file size, in bytes.
  final int totalBytes;

  Map<String, Object?> toJson() => {
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'appVersion': appVersion,
    'chatCount': chatCount,
    'messageCount': messageCount,
    'mediaIncluded': mediaIncluded,
    'totalBytes': totalBytes,
  };

  /// Total, in the [SnapshotCodec.decode] sense: every field degrades on its
  /// own and nothing here can fail a parse. A preview is a courtesy shown to
  /// the user, and a missing count must not be the reason a restore is refused
  /// — the passphrase step behind it is the one that decides anything.
  static ArchivePreview fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final created = map['createdAt'];
    return ArchivePreview(
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        created is int ? created : 0,
        isUtc: true,
      ),
      appVersion: map['appVersion'] is String
          ? map['appVersion'] as String
          : '',
      chatCount: _nonNegativeInt(map['chatCount']),
      messageCount: _nonNegativeInt(map['messageCount']),
      mediaIncluded: map['mediaIncluded'] == true,
      totalBytes: _nonNegativeInt(map['totalBytes']),
    );
  }
}

/// The parsed plaintext header, and the exact bytes it occupied.
@immutable
class ArchiveHeader {
  const ArchiveHeader({
    required this.version,
    required this.kdf,
    required this.cipher,
    required this.preview,
    required this.bytes,
  });

  final ArchiveVersion version;
  final KdfParameters kdf;
  final CipherParameters cipher;
  final ArchivePreview preview;

  /// The header exactly as it sits on disk, magic and length prefix included.
  ///
  /// Kept verbatim rather than re-encoded because it is the associated data for
  /// every frame, and re-encoding it would have to reproduce this writer's key
  /// order and number formatting byte for byte. It would not — `jsonEncode` of
  /// a map parsed from a future writer drops the fields this build does not
  /// model — and every frame would fail to authenticate on exactly the archives
  /// the version policy promises still open.
  final Uint8List bytes;

  /// Whether this archive knows things this build does not.
  bool get isFutureMinor => version.isFutureMinor;
}

// ------------------------------------------------------------------ manifest

/// What the archive contains, written as the first thing inside the ciphertext.
///
/// Encrypted rather than in the header for the reason [ArchivePreview] gives:
/// [networks] is the field worth hiding, and splitting the manifest so that one
/// field could be public would leave a manifest that is mostly redundant with
/// the preview. So the whole of it lives inside, and the preview outside
/// carries the size-inferable subset.
@immutable
class ArchiveManifest {
  const ArchiveManifest({
    required this.createdAt,
    required this.appVersion,
    this.networks = const <String>[],
    this.chatCount = 0,
    this.messageCount = 0,
    this.mediaIncluded = false,
    this.mediaCount = 0,
    this.mediaBytes = 0,
  });

  final DateTime createdAt;
  final String appVersion;

  /// Network ids, as `ChatNetwork.id` spells them. Strings rather than the enum
  /// so this package stays free of `weft_domain` and an archive written when a
  /// network existed still names it after the enum value is removed.
  final List<String> networks;

  final int chatCount;
  final int messageCount;
  final bool mediaIncluded;
  final int mediaCount;
  final int mediaBytes;

  Map<String, Object?> toJson() => {
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'appVersion': appVersion,
    'networks': networks,
    'chatCount': chatCount,
    'messageCount': messageCount,
    'mediaIncluded': mediaIncluded,
    'mediaCount': mediaCount,
    'mediaBytes': mediaBytes,
  };

  /// Total, for the same reason [ArchivePreview.fromJson] is: by the time this
  /// runs the passphrase was right and the MAC verified, so the payload behind
  /// it is genuine. Refusing it over a manifest field a newer writer spelled
  /// differently would throw away a restore that is going to work.
  static ArchiveManifest fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final created = map['createdAt'];
    final networks = map['networks'];
    return ArchiveManifest(
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        created is int ? created : 0,
        isUtc: true,
      ),
      appVersion: map['appVersion'] is String
          ? map['appVersion'] as String
          : '',
      networks: networks is List
          ? networks.whereType<String>().toList(growable: false)
          : const <String>[],
      chatCount: _nonNegativeInt(map['chatCount']),
      messageCount: _nonNegativeInt(map['messageCount']),
      mediaIncluded: map['mediaIncluded'] == true,
      mediaCount: _nonNegativeInt(map['mediaCount']),
      mediaBytes: _nonNegativeInt(map['mediaBytes']),
    );
  }
}

// -------------------------------------------------------------- header codec

/// Serialises [ArchiveHeader] to the bytes that open a `.braid` file.
///
/// Layout, in order:
///
/// ```text
/// magic        8 bytes   "BRAIDBAK"
/// headerLength 4 bytes   uint32 big-endian
/// headerJson   headerLength bytes, UTF-8
/// ```
///
/// Big-endian throughout the container, so a hex dump reads left to right and
/// the Swift and Kotlin sides — should they ever need to peek at a header the
/// way they already hand-parse the snapshot JSON — do not have to guess.
Uint8List encodeArchiveHeader({
  required KdfParameters kdf,
  required CipherParameters cipher,
  required ArchivePreview preview,
  ArchiveVersion version = kBraidArchiveFormatVersion,
}) {
  final json = utf8.encode(
    jsonEncode({
      'format': version.toJson(),
      'kdf': kdf.toJson(),
      'cipher': cipher.toJson(),
      'preview': preview.toJson(),
    }),
  );

  final out = BytesBuilder(copy: false)
    ..add(kBraidArchiveMagic)
    ..add(_uint32(json.length))
    ..add(json);
  return out.toBytes();
}

/// Why a header could not be parsed.
///
/// An enum rather than a message, because these three deserve three different
/// sentences and only the caller knows the user's language. See
/// `ArchiveOpenFailure` in `import.dart` for how they surface.
enum HeaderProblem {
  /// No magic, or fewer bytes than a header needs. The wrong file.
  notAnArchive,

  /// Magic matched, structure did not. A `.braid` that was truncated or
  /// corrupted in its first kilobyte — distinct from [notAnArchive] because the
  /// user did pick the right file and the advice is different.
  malformed,

  /// A major version above this build's. See [kBraidArchiveFormatVersion].
  unsupportedVersion,
}

/// The result of trying to read a header, which either worked or did not.
@immutable
class HeaderParseResult {
  const HeaderParseResult.success(this.header) : problem = null, version = null;

  const HeaderParseResult.failure(this.problem, {this.version}) : header = null;

  final ArchiveHeader? header;
  final HeaderProblem? problem;

  /// Set when [problem] is [HeaderProblem.unsupportedVersion], so the message
  /// can name the version that would be needed.
  final ArchiveVersion? version;

  bool get isSuccess => header != null;
}

/// Parses the plaintext header out of [bytes].
///
/// Deliberately takes the *whole* leading slice rather than a stream: a header
/// is bounded by [kMaxHeaderBytes] and the restore screen wants it from a file
/// it has not committed to reading. Callers read the first [kMaxHeaderBytes] of
/// the file and pass them here; a short read is fine, since every length is
/// checked against what actually arrived.
///
/// **Nothing here is authenticated.** The header has no MAC of its own — it is
/// the associated data of the first frame instead, which is what makes tampered
/// KDF parameters fail as a wrong-passphrase-shaped MAC error rather than as a
/// silently weakened derivation. So every field is bounds-checked on the way in
/// and none of them is allowed to size an allocation unchecked.
HeaderParseResult parseArchiveHeader(Uint8List bytes) {
  const prefixLength = 12; // magic + uint32 length
  if (bytes.length < prefixLength) {
    return const HeaderParseResult.failure(HeaderProblem.notAnArchive);
  }
  for (var i = 0; i < kBraidArchiveMagic.length; i++) {
    if (bytes[i] != kBraidArchiveMagic[i]) {
      return const HeaderParseResult.failure(HeaderProblem.notAnArchive);
    }
  }

  final jsonLength = _readUint32(bytes, kBraidArchiveMagic.length);
  if (jsonLength <= 0 || jsonLength > kMaxHeaderBytes) {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }
  if (bytes.length < prefixLength + jsonLength) {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }

  final Object? parsed;
  try {
    parsed = jsonDecode(
      utf8.decode(
        bytes.sublist(prefixLength, prefixLength + jsonLength),
        allowMalformed: true,
      ),
    );
  } on FormatException {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }
  if (parsed is! Map) {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }

  final version = ArchiveVersion.fromJson(parsed['format']);
  if (version == null) {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }
  // Checked before the KDF and cipher blocks, not after: a future major may
  // have replaced both, and reporting "malformed" for an archive we simply are
  // too old to read would send the user to the wrong remedy.
  if (!version.isReadable) {
    return HeaderParseResult.failure(
      HeaderProblem.unsupportedVersion,
      version: version,
    );
  }

  final kdf = KdfParameters.fromJson(parsed['kdf']);
  final cipher = CipherParameters.fromJson(parsed['cipher']);
  if (kdf == null || cipher == null) {
    return const HeaderParseResult.failure(HeaderProblem.malformed);
  }
  if (kdf.id != KdfParameters.argon2id ||
      cipher.id != CipherParameters.xchacha20Poly1305) {
    // A same-major archive naming primitives this build does not have is a
    // version problem in everything but the number: there is nothing to try.
    return HeaderParseResult.failure(
      HeaderProblem.unsupportedVersion,
      version: version,
    );
  }

  return HeaderParseResult.success(
    ArchiveHeader(
      version: version,
      kdf: kdf,
      cipher: cipher,
      preview: ArchivePreview.fromJson(parsed['preview']),
      bytes: Uint8List.sublistView(bytes, 0, prefixLength + jsonLength),
    ),
  );
}

// --------------------------------------------------------------------- bytes

/// [value] as four big-endian bytes.
Uint8List uint32Bytes(int value) => _uint32(value);

/// [value] as eight big-endian bytes, for the frame counter.
Uint8List uint64Bytes(int value) {
  final out = Uint8List(8);
  ByteData.view(out.buffer).setUint64(0, value);
  return out;
}

/// The big-endian uint32 at [offset] in [bytes].
int readUint32(Uint8List bytes, int offset) => _readUint32(bytes, offset);

Uint8List _uint32(int value) {
  final out = Uint8List(4);
  ByteData.view(out.buffer).setUint32(0, value);
  return out;
}

int _readUint32(Uint8List bytes, int offset) =>
    ByteData.view(bytes.buffer, bytes.offsetInBytes).getUint32(offset);

Uint8List? _decodeBase64(Object? raw) {
  if (raw is! String) return null;
  try {
    return base64.decode(raw);
  } on FormatException {
    return null;
  }
}

int _nonNegativeInt(Object? raw) => raw is int && raw >= 0 ? raw : 0;
