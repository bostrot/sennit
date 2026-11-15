/// Writing a `.sennit` archive.
///
/// ## What is deliberately not in here
///
/// **No E2EE device keys. No access tokens. No bridge credentials.** Not an
/// oversight and not a limitation — the exclusion is the design, and it is the
/// line between the two things people mean by "backup":
///
/// * *Restoring history* is getting your conversations back onto a device. That
///   is what this archive does.
/// * *Cloning a session* is becoming your account on a new device. That needs
///   device keys and an access token, and an archive that carried them would be
///   a file that logs anyone who opens it into your Matrix account, reads your
///   encrypted rooms, and appears on your account's device list — protected by
///   whatever passphrase someone chose while impatient to finish a settings
///   screen.
///
/// Matrix already answers the second question properly, with cross-signing and
/// server-side key backup, where losing the recovery key does not also lose the
/// history. See `docs/architecture/multi-device.md`. Duplicating it here in a
/// file the user emails to themselves would undo it.
///
/// The consequence, stated plainly because the restore screen has to say it:
/// a restored archive gives back what Sennit knew — the messages, who said them,
/// which network they arrived on, the merges, the settings, the media — and
/// does **not** give back the ability to decrypt anything new from the
/// homeserver. That still comes from Matrix key backup.
///
/// Also excluded, for smaller reasons: the embedding vectors and their queue
/// (derived, model-specific, and larger than everything else combined — a
/// restore rebuilds them), and the link-preview cache (a cache, and a log of
/// which links the user was sent, which is not something to carry around in a
/// file).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import 'crypto.dart';
import 'format.dart';
import 'records.dart';
import 'stream.dart';

/// What a source expects to produce, asked before anything is written.
///
/// Needed up front because the manifest states counts and the progress bar
/// needs a denominator, and both sit at the *front* of the file. A source
/// answers this with `COUNT(*)`-shaped work, not by walking the records twice.
@immutable
class BackupSummary {
  const BackupSummary({
    this.networks = const <String>[],
    this.chatCount = 0,
    this.messageCount = 0,
    this.mediaCount = 0,
    this.mediaBytes = 0,
    this.otherRecordCount = 0,
  });

  final List<String> networks;
  final int chatCount;
  final int messageCount;

  /// Distinct media files, after content-hash dedup where the source can tell.
  /// An over-count here costs a progress bar that finishes early, which is the
  /// right direction to be wrong in.
  final int mediaCount;
  final int mediaBytes;

  /// Contacts, handles, merges, prefs, settings and transcripts together.
  final int otherRecordCount;

  /// A rough finished size, for [ArchivePreview.totalBytes] and the progress
  /// denominator.
  ///
  /// Media dominates whenever there is any, so the estimate is media plus a
  /// flat allowance per non-media record. 512 bytes is a little over what a
  /// typical message record encodes to; being high means the bar creeps rather
  /// than jumping to 100% and waiting, which is the failure mode people read as
  /// a hang.
  int get estimatedBytes =>
      mediaBytes + (messageCount + otherRecordCount) * 512 + 1024;
}

/// Where the records come from.
///
/// An interface rather than a concrete store reader, and that is what keeps
/// this package free of SQL and Flutter: the adapter over `weft_store` lives in
/// `weft_store`, where the schema already is, and the tests here run against
/// sources built by hand. It also leaves room for a source that can answer
/// questions Sennit's own tables cannot — reactions, for one, which are
/// aggregated live from the Matrix timeline and never persisted.
abstract interface class BackupSource {
  /// Counts, cheaply, before the first byte is written.
  Future<BackupSummary> summarise({required bool includeMedia});

  /// Every record, in whatever order suits the source.
  ///
  /// Order is not a contract: import applies records by type, and the one
  /// ordering dependency — a handle referencing a contact that must exist —
  /// is resolved on the import side rather than imposed here, so that a source
  /// can stream straight out of a cursor.
  ///
  /// Media may be yielded naively: emit a [MediaRecord] and a [MediaRefRecord]
  /// per attachment and let [writeArchive] drop the duplicate bytes.
  Stream<BackupRecord> records({required bool includeMedia});
}

/// How far an export or import has got.
@immutable
class BackupProgress {
  const BackupProgress({
    required this.bytes,
    required this.totalBytes,
    required this.records,
  });

  final int bytes;

  /// The estimate from [BackupSummary.estimatedBytes]. Zero when unknown, which
  /// a progress indicator should read as indeterminate rather than as done.
  final int totalBytes;

  final int records;

  /// 0..1, or null when there is no usable denominator.
  double? get fraction {
    if (totalBytes <= 0) return null;
    return (bytes / totalBytes).clamp(0.0, 1.0);
  }
}

/// Raised when [writeArchive]'s `shouldContinue` said stop.
///
/// An exception rather than a quiet return, so that a caller cannot mistake a
/// cancelled export for a finished one — and so that the `.part` cleanup in
/// [exportArchiveToFile] sits in a single `catch` with every other failure,
/// which is the only way it is guaranteed to run.
class BackupCancelledException implements Exception {
  const BackupCancelledException();

  @override
  String toString() => 'BackupCancelledException()';
}

/// What an export produced.
@immutable
class ExportOutcome {
  const ExportOutcome({
    required this.manifest,
    required this.bytesWritten,
    required this.recordsWritten,
    required this.mediaDeduplicated,
  });

  final ArchiveManifest manifest;
  final int bytesWritten;
  final int recordsWritten;

  /// Media entries whose bytes were already in the archive under the same
  /// hash. Reported because "your 900 photos took 300 MB" is a question the
  /// settings screen gets asked, and this is the answer.
  final int mediaDeduplicated;
}

/// Writes an archive of [source] into [sink], encrypted under [passphrase].
///
/// The body is a single plaintext byte stream, chunked into frames of
/// [CipherParameters.frameSize] *without regard to record boundaries* — a
/// 40 MB video spans forty frames and no frame ever holds more than its size.
/// That is what makes this streaming rather than merely incremental.
///
/// ```text
/// manifestLength  uint32     ┐
/// manifestJson    …          │
/// recordLength    uint32     │ one plaintext stream,
/// recordJson      …          │ split into frames by size alone
/// blobLength      uint32     │
/// blob            …          │
/// …repeat…                   │
/// 0               uint32     ┘ terminator, inside the ciphertext
/// ```
///
/// The terminator is encrypted rather than implied by end-of-file so that a
/// truncated archive fails on content as well as on the final-frame flag. Two
/// independent checks for the same attack, because the cost is four bytes.
Future<ExportOutcome> writeArchive({
  required BackupSource source,
  required String passphrase,
  required ArchiveSink sink,
  required String appVersion,
  required DateTime createdAt,
  bool includeMedia = true,
  void Function(BackupProgress progress)? onProgress,
  Future<bool> Function()? shouldContinue,
  Random? random,
  int frameSize = kDefaultFrameSize,
  KdfParameters? kdfOverride,
}) async {
  final summary = await source.summarise(includeMedia: includeMedia);

  // The override exists for tests, which would otherwise pay 64 MiB of Argon2id
  // per case and take minutes to prove a framing bug. It is a real parameter
  // rather than a test hook because the *reader* already honours whatever the
  // header says — so a future "this archive is going somewhere hostile" setting
  // that raises the cost needs no format change, only this argument.
  final kdf = kdfOverride ?? newKdfParameters(random: random);
  final cipher = newCipherParameters(random: random, frameSize: frameSize);

  final manifest = ArchiveManifest(
    createdAt: createdAt,
    appVersion: appVersion,
    networks: summary.networks,
    chatCount: summary.chatCount,
    messageCount: summary.messageCount,
    mediaIncluded: includeMedia,
    mediaCount: includeMedia ? summary.mediaCount : 0,
    mediaBytes: includeMedia ? summary.mediaBytes : 0,
  );

  final headerBytes = encodeArchiveHeader(
    kdf: kdf,
    cipher: cipher,
    preview: ArchivePreview(
      createdAt: createdAt,
      appVersion: appVersion,
      chatCount: summary.chatCount,
      messageCount: summary.messageCount,
      mediaIncluded: includeMedia,
      totalBytes: summary.estimatedBytes,
    ),
  );

  // Derived before the header is written, so that a passphrase Argon2id refuses
  // outright leaves nothing at the destination at all.
  final key = await deriveArchiveKey(passphrase, kdf);
  final frames = FrameCipher(
    key: key,
    cipher: cipher,
    headerBytes: headerBytes,
  );

  var bytesWritten = 0;
  Future<void> emit(List<int> bytes) async {
    await sink.add(bytes);
    bytesWritten += bytes.length;
  }

  await emit(headerBytes);

  final writer = _FrameWriter(frames: frames, frameSize: frameSize, emit: emit);
  var recordsWritten = 0;
  var deduplicated = 0;
  final seenMedia = <String>{};

  Future<void> checkpoint() async {
    onProgress?.call(
      BackupProgress(
        bytes: bytesWritten,
        totalBytes: summary.estimatedBytes,
        records: recordsWritten,
      ),
    );
    if (shouldContinue != null && !await shouldContinue()) {
      throw const BackupCancelledException();
    }
  }

  final manifestJson = utf8.encode(jsonEncode(manifest.toJson()));
  await writer.add(uint32Bytes(manifestJson.length));
  await writer.add(manifestJson);

  await for (final record in source.records(includeMedia: includeMedia)) {
    // Dedup here rather than in every source. The bytes are what is expensive,
    // so the *ref* is always kept and only the payload is dropped — which is
    // what lets one photo forwarded into four chats restore into four chats.
    if (record is MediaRecord) {
      if (!seenMedia.add(record.sha256)) {
        deduplicated++;
        continue;
      }
    }

    final json = encodeBackupRecord(record);
    final blobLength = record.blobLength;
    await writer.add(uint32Bytes(json.length));
    await writer.add(json);
    await writer.add(uint32Bytes(blobLength));

    if (blobLength > 0) {
      // The length went out before the bytes did, so a source that lies about
      // it — a file truncated by another process between the stat and the read
      // is the realistic way — would silently shift every following record by
      // the difference. Counted and checked rather than trusted, and a
      // mismatch fails the export rather than producing an archive that
      // decrypts perfectly into nonsense.
      var seen = 0;
      await for (final chunk in record.openBlob()) {
        seen += chunk.length;
        if (seen > blobLength) {
          throw StateError(
            'Record ${_describe(record)} produced more bytes than the '
            '$blobLength it declared.',
          );
        }
        await writer.add(chunk);
        await checkpoint();
      }
      if (seen != blobLength) {
        throw StateError(
          'Record ${_describe(record)} produced $seen bytes of the '
          '$blobLength it declared.',
        );
      }
    }

    recordsWritten++;
    await checkpoint();
  }

  await writer.add(uint32Bytes(0));
  await writer.finish();

  onProgress?.call(
    BackupProgress(
      bytes: bytesWritten,
      totalBytes: bytesWritten,
      records: recordsWritten,
    ),
  );

  return ExportOutcome(
    manifest: manifest,
    bytesWritten: bytesWritten,
    recordsWritten: recordsWritten,
    mediaDeduplicated: deduplicated,
  );
}

/// [writeArchive] onto a file, leaving nothing behind if it does not finish.
///
/// Writes to `<target>.part` and renames on success — the same trick
/// `stageAttachment` uses for downloads, for the same reason. The presence of
/// the final name means the bytes are all there, so a cancelled or crashed
/// export cannot leave a plausible-looking archive in the user's Files app for
/// them to discover the truth about a year later, on the day they need it.
Future<ExportOutcome> exportArchiveToFile({
  required BackupSource source,
  required String passphrase,
  required File target,
  required String appVersion,
  required DateTime createdAt,
  bool includeMedia = true,
  void Function(BackupProgress progress)? onProgress,
  Future<bool> Function()? shouldContinue,
  Random? random,
  int frameSize = kDefaultFrameSize,
  KdfParameters? kdfOverride,
}) async {
  final part = File('${target.path}.part');
  final sink = await FileArchiveSink.open(part);

  try {
    final outcome = await writeArchive(
      source: source,
      passphrase: passphrase,
      sink: sink,
      appVersion: appVersion,
      createdAt: createdAt,
      includeMedia: includeMedia,
      onProgress: onProgress,
      shouldContinue: shouldContinue,
      random: random,
      frameSize: frameSize,
      kdfOverride: kdfOverride,
    );
    await sink.close();
    await part.rename(target.path);
    return outcome;
  } catch (_) {
    await sink.close();
    // Deleting is best-effort: a `.part` that outlives a crash is untidy, and
    // failing the export a second time over the tidying would replace a clear
    // error with a confusing one.
    try {
      if (part.existsSync()) await part.delete();
    } on FileSystemException {
      // Nothing useful to do, and the original failure is the one to report.
    }
    rethrow;
  }
}

/// Accumulates plaintext and seals it a frame at a time.
///
/// The buffer is what makes record boundaries and frame boundaries independent:
/// callers hand over whatever length they have and frames come out at exactly
/// [frameSize] until the last one.
class _FrameWriter {
  _FrameWriter({
    required this.frames,
    required this.frameSize,
    required this.emit,
  });

  final FrameCipher frames;
  final int frameSize;
  final Future<void> Function(List<int> bytes) emit;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _index = 0;

  Future<void> add(List<int> bytes) async {
    _buffer.add(bytes);
    while (_buffer.length >= frameSize) {
      // `takeBytes` empties the builder, so the remainder past this frame goes
      // straight back in rather than being copied twice.
      final all = _buffer.takeBytes();
      await _seal(Uint8List.sublistView(all, 0, frameSize), isFinal: false);
      if (all.length > frameSize) {
        _buffer.add(Uint8List.sublistView(all, frameSize));
      }
    }
  }

  /// Seals whatever is left as the final frame.
  ///
  /// Always emits one, even when the buffer is empty: the final-frame flag is
  /// how a reader knows it reached the end on purpose, so an archive with no
  /// final frame is by definition truncated. An empty final frame is 21 bytes.
  Future<void> finish() async {
    await _seal(_buffer.takeBytes(), isFinal: true);
  }

  Future<void> _seal(Uint8List plaintext, {required bool isFinal}) async {
    final sealed = await frames.seal(
      plaintext,
      frameIndex: _index,
      isFinal: isFinal,
    );
    _index++;
    await emit(uint32Bytes(sealed.length));
    await emit(<int>[isFinal ? 1 : 0]);
    await emit(sealed);
  }
}

/// Names [record] in an error message without naming its contents.
///
/// For media that is the first twelve characters of the content hash. The whole
/// hash is the address of a file that is probably a photograph of the user, and
/// this string ends up in a log; twelve characters identify it in a bug report
/// without being a handle onto the file.
String _describe(BackupRecord record) {
  if (record is! MediaRecord) return record.type;
  final hash = record.sha256;
  return hash.length <= 12 ? hash : hash.substring(0, 12);
}

/// The SHA-256 of [bytes], lowercase hex — the address a [MediaRecord] is
/// stored under.
///
/// Exposed so a source can hash a file it is about to read without duplicating
/// the choice of algorithm, and so the two sides of a dedup cannot drift.
String mediaContentHash(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// [mediaContentHash] over a stream, for a file too large to hold.
///
/// The export path hashes every attachment the user has ever opened, and one of
/// them being a two-hour film is the ordinary case rather than the exotic one.
/// Reading those into a `Uint8List` to hash them would undo the streaming the
/// rest of this file exists to provide.
Future<String> mediaContentHashOfStream(Stream<List<int>> bytes) async {
  final digests = AccumulatorSink<crypto.Digest>();
  final input = crypto.sha256.startChunkedConversion(digests);
  await for (final chunk in bytes) {
    input.add(chunk);
  }
  input.close();
  return digests.events.single.toString();
}
