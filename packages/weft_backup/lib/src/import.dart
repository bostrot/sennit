/// Reading a `.braid` archive back.
///
/// Two steps, because the restore screen has two:
///
/// 1. [readArchivePreview] parses the plaintext header and answers "is this a
///    Braid archive, can this build read it, and what does it say about
///    itself" — **without the passphrase**. This is what the file picker's
///    result is shown against, so that "wrong file" is a sentence the user gets
///    before they have typed anything.
/// 2. [openArchive] takes the passphrase, opens the first frame, and hands back
///    the manifest plus a stream of records. The manifest is the last chance to
///    back out, and it carries the part the header could not: which networks
///    are in here.
///
/// Then [importArchive] drives that stream into a [BackupSink].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'crypto.dart';
import 'export.dart' show BackupCancelledException, BackupProgress;
import 'format.dart';
import 'records.dart';
import 'stream.dart';

/// Why an archive could not be opened.
///
/// **Typed, and the types are the point.** Every one of these gets a different
/// sentence and a different next action, and collapsing them — which is what
/// happens if the only signal is an exception from the cipher — produces the
/// single worst message this feature could show: "could not restore", to
/// someone holding the only copy of their history.
sealed class ArchiveOpenFailure implements Exception {
  const ArchiveOpenFailure();
}

/// Not a `.braid` file at all — the magic bytes are missing.
///
/// The likely truth is that the file picker was pointed at the wrong thing.
final class NotAnArchiveFailure extends ArchiveOpenFailure {
  const NotAnArchiveFailure();

  @override
  String toString() => 'NotAnArchiveFailure()';
}

/// A `.braid` file whose header does not parse.
///
/// Distinct from [NotAnArchiveFailure] because the user picked the *right*
/// file and it is damaged, which is a different and much worse thing to be
/// told — and from [TruncatedArchiveFailure] because the damage is in the
/// first kilobyte rather than at the end.
final class MalformedArchiveFailure extends ArchiveOpenFailure {
  const MalformedArchiveFailure();

  @override
  String toString() => 'MalformedArchiveFailure()';
}

/// Written by a Braid whose container version this build does not know.
///
/// The only failure here whose remedy is "update Braid", which is why it is
/// worth being able to say exactly that. See [kBraidArchiveFormatVersion].
final class UnsupportedVersionFailure extends ArchiveOpenFailure {
  const UnsupportedVersionFailure(this.version);

  final ArchiveVersion version;

  @override
  String toString() => 'UnsupportedVersionFailure($version)';
}

/// The first frame did not authenticate.
///
/// Reported as a wrong passphrase because that is overwhelmingly what it is,
/// and because the alternative — a file whose header was edited — is not
/// something the user can act on differently. A failure at any *later* frame is
/// [DamagedArchiveFailure] instead: by then the key has already opened a frame,
/// so the passphrase was right and the file is not.
final class WrongPassphraseFailure extends ArchiveOpenFailure {
  const WrongPassphraseFailure();

  @override
  String toString() => 'WrongPassphraseFailure()';
}

/// The file ended before the archive did.
///
/// A copy interrupted, a disk that filled, a cloud sync that has not finished
/// downloading. Worth its own type because it is the one failure where "try
/// again with the same file" is sometimes the right advice.
final class TruncatedArchiveFailure extends ArchiveOpenFailure {
  const TruncatedArchiveFailure();

  @override
  String toString() => 'TruncatedArchiveFailure()';
}

/// A frame past the first did not authenticate — the file is corrupt.
final class DamagedArchiveFailure extends ArchiveOpenFailure {
  const DamagedArchiveFailure(this.frameIndex);

  final int frameIndex;

  @override
  String toString() => 'DamagedArchiveFailure(frame $frameIndex)';
}

/// Reads the plaintext header, without a passphrase.
///
/// Throws an [ArchiveOpenFailure]; never returns a partly-populated preview.
/// The input is left positioned after the header, which is what [openArchive]
/// expects — but callers that mean to open it afterwards should re-open the
/// input rather than reuse it, since a preview is usually shown, thought about,
/// and acted on much later.
Future<ArchiveHeader> readArchiveHeader(ArchiveInput input) async {
  final bytes = await readExactly(input, kMaxHeaderBytes);
  final result = parseArchiveHeader(bytes);

  final header = result.header;
  if (header != null) return header;

  throw switch (result.problem!) {
    HeaderProblem.notAnArchive => const NotAnArchiveFailure(),
    HeaderProblem.malformed => const MalformedArchiveFailure(),
    HeaderProblem.unsupportedVersion => UnsupportedVersionFailure(
      result.version ?? kBraidArchiveFormatVersion,
    ),
  };
}

/// The header's [ArchivePreview], for the screen shown before the passphrase.
Future<ArchivePreview> readArchivePreview(ArchiveInput input) async =>
    (await readArchiveHeader(input)).preview;

/// An opened archive: its manifest, and its records.
class ArchiveReader {
  ArchiveReader._({
    required this.header,
    required this.manifest,
    required _BodyReader body,
  }) : _body = body;

  final ArchiveHeader header;

  /// What the archive says it holds. Authenticated — it came out of the first
  /// frame — so unlike [ArchiveHeader.preview] it can be trusted rather than
  /// merely displayed.
  final ArchiveManifest manifest;

  final _BodyReader _body;

  /// Whether the writer knew record types or fields this build does not.
  bool get isFutureMinor => header.isFutureMinor;

  /// Every record, in the order the writer emitted them.
  ///
  /// Media bytes are **not** in these values. A [MediaRecord] arrives naming a
  /// hash and a length, and its bytes are handed to [BackupSink.beginMedia] by
  /// [importArchive] as they come off the frame stream — which is what keeps a
  /// 400 MB video from being a 400 MB `Uint8List`. A caller iterating this
  /// stream itself must call [drainBlob] for each media record before asking
  /// for the next one, because the bytes sit between them.
  Stream<BackupRecord> records() async* {
    while (true) {
      final lengthBytes = await _body.take(4);
      final length = readUint32(lengthBytes, 0);
      if (length == 0) return; // The terminator, inside the ciphertext.

      // Authenticated, so this is the writer's number rather than an
      // attacker's — but a writer with a bug is still a writer, and a 2 GB
      // record header is a bug. The frame size is a generous ceiling for
      // something that is JSON.
      if (length > kMaxFrameSize) throw const MalformedArchiveFailure();

      final Object? json;
      try {
        json = jsonDecode(utf8.decode(await _body.take(length)));
      } on FormatException {
        throw const MalformedArchiveFailure();
      }

      final blobLength = readUint32(await _body.take(4), 0);
      _pendingBlob = blobLength;

      final record = decodeBackupRecord(json);
      if (record == null) {
        // A known type missing its required fields. Its blob, if any, still
        // has to come off the stream or every following record is misaligned.
        await drainBlob();
        continue;
      }
      yield record;

      // A consumer that ignored the blob would leave the cursor mid-file.
      await drainBlob();
    }
  }

  int _pendingBlob = 0;

  /// How many blob bytes sit between the record just yielded and the next one.
  int get pendingBlobLength => _pendingBlob;

  /// Reads the pending blob in chunks, handing each to [onChunk].
  ///
  /// Called by [importArchive] with a sink writer, and by [records] itself with
  /// nothing, so that a consumer which skipped a media record still leaves the
  /// stream aligned.
  Future<void> drainBlob({
    Future<void> Function(Uint8List chunk)? onChunk,
  }) async {
    var remaining = _pendingBlob;
    _pendingBlob = 0;
    while (remaining > 0) {
      final want = remaining < _blobChunk ? remaining : _blobChunk;
      final chunk = await _body.take(want);
      remaining -= chunk.length;
      if (onChunk != null) await onChunk(chunk);
    }
  }

  /// 256 KiB at a time. Small enough that peak memory during a restore is a
  /// constant rather than a function of the largest video in the archive, large
  /// enough that a 400 MB file is not 1.6 million awaits.
  static const int _blobChunk = 256 * 1024;

  Future<void> close() => _body.close();
}

/// Opens an archive whose bytes are already available as one buffer.
///
/// Rewinding is the awkward part: the header is read by pulling a fixed
/// [kMaxHeaderBytes] block, which normally overshoots into the body, and
/// [ArchiveInput] deliberately has no seek — a seekable interface is one only
/// files can satisfy, and this package is meant to be testable without a disk.
/// So there are two entry points instead: this one slices, and [openArchiveWith]
/// opens twice.
///
/// Throws [WrongPassphraseFailure] when the first frame does not authenticate,
/// which is also what a tampered header produces — see the type's own note for
/// why they are deliberately the same answer.
Future<ArchiveReader> openArchiveBytes(
  Uint8List bytes,
  String passphrase,
) async {
  final header = await readArchiveHeader(BytesArchiveInput(bytes));
  final body = BytesArchiveInput(
    Uint8List.sublistView(bytes, header.bytes.length),
  );
  return _open(header, body, passphrase);
}

/// Opens an archive from a stream positioned at its very first byte.
///
/// [openInput] is called twice — once to read the header, once to read the body
/// from the beginning — because [ArchiveInput] has no seek and the header read
/// overshoots. Two cheap opens beat a seekable interface that only files can
/// satisfy.
Future<ArchiveReader> openArchiveWith(
  Future<ArchiveInput> Function() openInput,
  String passphrase,
) async {
  final headerInput = await openInput();
  final ArchiveHeader header;
  try {
    header = await readArchiveHeader(headerInput);
  } finally {
    await headerInput.close();
  }

  final bodyInput = await openInput();
  // Skip the header the second time round.
  await readExactly(bodyInput, header.bytes.length);
  return _open(header, bodyInput, passphrase);
}

/// [openArchiveWith] over a file.
Future<ArchiveReader> openArchiveFile(File file, String passphrase) =>
    openArchiveWith(() => FileArchiveInput.open(file), passphrase);

/// [readArchivePreview] over a file, closing it again afterwards.
///
/// The restore flow's first step: the user picked a file, and this is what the
/// screen can say about it before asking for anything.
Future<ArchivePreview> readArchiveFilePreview(File file) async {
  final input = await FileArchiveInput.open(file);
  try {
    return (await readArchiveHeader(input)).preview;
  } finally {
    await input.close();
  }
}

Future<ArchiveReader> _open(
  ArchiveHeader header,
  ArchiveInput bodyInput,
  String passphrase,
) async {
  final key = await deriveArchiveKey(passphrase, header.kdf);
  final body = _BodyReader(
    input: bodyInput,
    cipher: FrameCipher(
      key: key,
      cipher: header.cipher,
      headerBytes: header.bytes,
    ),
    parameters: header.cipher,
  );

  // The first frame is the passphrase check. Reading the manifest length forces
  // it open, so an archive that reaches the caller at all is one whose key
  // works — which is what lets a later authentication failure be reported as
  // damage rather than as a passphrase the user already got right.
  final manifestLength = readUint32(await body.take(4), 0);
  if (manifestLength <= 0 || manifestLength > kMaxFrameSize) {
    throw const MalformedArchiveFailure();
  }

  final Object? json;
  try {
    json = jsonDecode(utf8.decode(await body.take(manifestLength)));
  } on FormatException {
    throw const MalformedArchiveFailure();
  }

  return ArchiveReader._(
    header: header,
    manifest: ArchiveManifest.fromJson(json),
    body: body,
  );
}

// ------------------------------------------------------------------- import

/// What a restore does to what is already there.
enum ImportMode {
  /// Insert what is missing and leave everything else alone. The default, and
  /// the one that is safe to run twice: a message already present is recognised
  /// by `(roomId, eventId)` and skipped, never duplicated.
  merge,

  /// Empty the tables this archive covers, then insert. For the case the merge
  /// mode cannot serve — a store that has drifted, a device being reset to a
  /// known state — and the only mode that can *lose* data, which is why the UI
  /// asks twice.
  replace,
}

/// Somewhere a restore's records go.
///
/// Implemented against `weft_store` in that package, and against a map in this
/// package's tests. The transaction is the sink's to run, because only it knows
/// what a transaction means where it is writing.
abstract interface class BackupSink {
  /// Opens the transaction and, for [ImportMode.replace], clears.
  Future<void> begin(ImportMode mode);

  /// Applies one non-media record.
  ///
  /// Returns whether it changed anything — false for a merge that recognised a
  /// row it already had. The count is what the summary screen reports, and
  /// "restored 0 new messages" is the honest answer to importing the same
  /// archive twice.
  Future<bool> apply(BackupRecord record);

  /// Starts writing one media file, or returns null to skip its bytes.
  ///
  /// Null is the useful case: a sink that already has this content hash says so
  /// and the bytes are read off the stream and discarded, without a second copy
  /// on disk and without the caller having to buffer to find out.
  Future<MediaWriter?> beginMedia(String sha256, int sizeBytes);

  /// Commits. Called once, on success.
  Future<void> commit();

  /// Rolls back. Called once, on any failure or cancellation.
  Future<void> rollback();
}

/// One media file being written during a restore.
abstract interface class MediaWriter {
  Future<void> add(List<int> bytes);

  /// The bytes are all there. Only now may the file take its final name.
  Future<void> finish();

  /// Abandon it, leaving nothing behind.
  Future<void> abort();
}

/// What a restore did.
@immutable
class ImportOutcome {
  const ImportOutcome({
    required this.manifest,
    required this.applied,
    required this.skippedExisting,
    required this.skippedUnknownType,
    required this.mediaWritten,
    required this.mediaSkipped,
    required this.unknownTypes,
  });

  final ArchiveManifest manifest;

  /// Records that changed something.
  final int applied;

  /// Records the sink recognised and left alone — the merge no-ops.
  final int skippedExisting;

  /// Records whose `type` this build does not know.
  ///
  /// Separate from [skippedExisting] because they mean opposite things: one is
  /// a restore working exactly as designed, the other is an archive from a
  /// newer Braid carrying something this build cannot store. The summary screen
  /// says so, because silently dropping it would leave the user believing they
  /// have a complete copy.
  final int skippedUnknownType;

  final int mediaWritten;

  /// Media whose bytes the sink already had, by content hash.
  final int mediaSkipped;

  /// The distinct unknown `type` strings, for a bug report.
  final Set<String> unknownTypes;

  bool get isComplete => skippedUnknownType == 0;
}

/// Drives [reader]'s records into [sink].
///
/// **All of it or none of it.** The sink's transaction is opened before the
/// first record and rolled back on any failure, including cancellation — so an
/// interrupted restore leaves the store exactly as it was rather than
/// half-populated, which is the state that would be indistinguishable from a
/// successful restore of a truncated archive.
///
/// Media is the exception, and unavoidably so: files on disk are not in the
/// database transaction. Each one is written to a temporary name and renamed
/// only when its bytes are complete, so a rollback leaves orphaned *content*
/// that nothing references rather than a half-written photo something does.
Future<ImportOutcome> importArchive({
  required ArchiveReader reader,
  required BackupSink sink,
  ImportMode mode = ImportMode.merge,
  void Function(BackupProgress progress)? onProgress,
  Future<bool> Function()? shouldContinue,
}) async {
  var applied = 0;
  var skippedExisting = 0;
  var skippedUnknown = 0;
  var mediaWritten = 0;
  var mediaSkipped = 0;
  var bytes = 0;
  final unknownTypes = <String>{};

  await sink.begin(mode);

  try {
    await for (final record in reader.records()) {
      if (record is MediaRecord) {
        final length = reader.pendingBlobLength;
        final writer = await sink.beginMedia(record.sha256, length);
        if (writer == null) {
          await reader.drainBlob();
          mediaSkipped++;
        } else {
          try {
            await reader.drainBlob(
              onChunk: (chunk) async {
                bytes += chunk.length;
                await writer.add(chunk);
              },
            );
            await writer.finish();
          } catch (_) {
            await writer.abort();
            rethrow;
          }
          mediaWritten++;
        }
      } else if (record is UnknownRecord) {
        skippedUnknown++;
        unknownTypes.add(record.type);
      } else if (await sink.apply(record)) {
        applied++;
      } else {
        skippedExisting++;
      }

      onProgress?.call(
        BackupProgress(
          bytes: bytes,
          totalBytes: reader.manifest.mediaBytes,
          records: applied + skippedExisting + skippedUnknown,
        ),
      );

      if (shouldContinue != null && !await shouldContinue()) {
        throw const BackupCancelledException();
      }
    }

    await sink.commit();
  } catch (_) {
    await sink.rollback();
    rethrow;
  }

  return ImportOutcome(
    manifest: reader.manifest,
    applied: applied,
    skippedExisting: skippedExisting,
    skippedUnknownType: skippedUnknown,
    mediaWritten: mediaWritten,
    mediaSkipped: mediaSkipped,
    unknownTypes: unknownTypes,
  );
}

// -------------------------------------------------------------- body reader

/// Turns the framed, encrypted body into a plaintext cursor.
///
/// Pulls one frame at a time and hands out arbitrary-length slices of the
/// plaintext behind them, so callers can ask for four bytes or four megabytes
/// without knowing where the frame boundaries fell. At most one frame's
/// plaintext is held at a time.
class _BodyReader {
  _BodyReader({
    required this.input,
    required this.cipher,
    required this.parameters,
  });

  final ArchiveInput input;
  final FrameCipher cipher;
  final CipherParameters parameters;

  final BytesBuilder _plain = BytesBuilder(copy: false);
  int _index = 0;
  bool _sawFinalFrame = false;

  /// Exactly [count] plaintext bytes.
  ///
  /// Throws [TruncatedArchiveFailure] when the file runs out first, which is
  /// the *only* way this method can come up short — a caller asking for a
  /// length that the archive does not contain is exactly what a truncated file
  /// looks like from in here.
  Future<Uint8List> take(int count) async {
    while (_plain.length < count) {
      if (_sawFinalFrame) throw const TruncatedArchiveFailure();
      await _readFrame();
    }

    final all = _plain.takeBytes();
    if (all.length > count) {
      _plain.add(Uint8List.sublistView(all, count));
    }
    return Uint8List.sublistView(all, 0, count);
  }

  Future<void> _readFrame() async {
    final prefix = await readExactly(input, 5); // uint32 length + flag byte
    if (prefix.isEmpty) throw const TruncatedArchiveFailure();
    if (prefix.length < 5) throw const TruncatedArchiveFailure();

    final length = readUint32(prefix, 0);
    final isFinal = prefix[4] == 1;

    // Bounded before it is allocated. The length is not authenticated yet — the
    // MAC over it is inside the frame this number is describing — so a corrupt
    // or hostile file gets to name any size at all, and the reader is the
    // process that dies of it. `SnapshotCodec` refuses an oversize payload for
    // exactly this reason.
    final ceiling = parameters.frameSize + CipherParameters.tagLength;
    if (length < CipherParameters.tagLength || length > ceiling) {
      throw const MalformedArchiveFailure();
    }

    final sealed = await readExactly(input, length);
    if (sealed.length < length) throw const TruncatedArchiveFailure();

    final Uint8List clear;
    try {
      clear = await cipher.open(sealed, frameIndex: _index, isFinal: isFinal);
    } on ArchiveAuthenticationException catch (error) {
      // Frame zero is the passphrase check; anything later already proved the
      // key and so is damage. See [WrongPassphraseFailure].
      throw error.frameIndex == 0
          ? const WrongPassphraseFailure()
          : DamagedArchiveFailure(error.frameIndex);
    }

    _plain.add(clear);
    _index++;
    _sawFinalFrame = isFinal;
  }

  Future<void> close() => input.close();
}
