import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_share/weft_share.dart';

import '../../app/intents.dart';

/// One staged blob, as the App Group container holds it.
///
/// The [id] travels beside the JSON rather than being read out of it, and that
/// is the whole reason this type exists. A blob that cannot be decoded still has
/// to be *deleted*, and the id inside it is precisely the part that cannot be
/// read — so the id the filename carries is the one the container is addressed
/// by. Without it, one corrupt blob would be re-read on every launch, forever.
@immutable
class StagedShareBlob {
  const StagedShareBlob({required this.id, required this.json});

  /// The `<id>.json` filename's stem, and the key for deleting this share.
  final String id;

  /// The blob's contents, or null when the platform could not read the file —
  /// unreadable, or too large to be a staged share. The same answer
  /// [ShareStagingCodec.decode] gives for a blob it refuses, and it takes the
  /// same path here: delete it.
  final String? json;

  /// [raw] as a blob, or null when it is not one.
  static StagedShareBlob? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final json = raw['blob'];
    return StagedShareBlob(id: id, json: json is String ? json : null);
  }

  @override
  String toString() => 'StagedShareBlob($id, ${json?.length ?? 0} chars)';
}

/// The App Group container, as the drain needs to see it.
///
/// A seam for the same reason [SharedFileResolver] and [ShareTargetPublisher]
/// are: behind it is a method channel and a filesystem the app does not own, and
/// every decision [StagedShareReader] makes — what to drop, what to deliver,
/// what not to deliver twice — is a decision that can be wrong without a device
/// being involved. The real implementation is [WeftStagedShares]; a test's is a
/// map.
abstract interface class StagedShareGateway {
  /// Every blob currently staged, and a sweep of what has aged out.
  ///
  /// [ttl] is passed down rather than applied here: the platform side sweeps
  /// *orphans* with it — an ingested copy nothing is going to open again, and a
  /// files directory whose blob was never written because the extension was
  /// killed between the two steps. Expiry of a readable share is Dart's, because
  /// it is judged on `capturedAt` inside the blob and only the codec reads that.
  Future<List<StagedShareBlob>> readStagedShares({required Duration ttl});

  /// Moves [files] out of the container and into storage the app owns,
  /// answering with each one's new absolute path keyed by
  /// [StagedFile.relativePath].
  ///
  /// The share is gone from the container afterwards either way. A file missing
  /// from the answer could not be moved, which is one lost attachment rather
  /// than a lost share.
  Future<Map<String, String>> ingestStagedShare(
    String id,
    List<StagedFile> files,
  );

  /// Drops a staged share unopened: expired, unreadable, or already handled.
  Future<void> removeStagedShare(String id);

  /// Writes the ranked target list the iOS extension's picker reads.
  Future<bool> writeShareTargets(String json);
}

/// Drains shares an iOS Share Extension captured while Weft was not running.
///
/// The extension cannot send: it has no Matrix session and a memory ceiling far
/// below what one costs. What it can do is copy the bytes into the App Group
/// container and write a `StagedShare` beside them. This is the other half —
/// called on launch and on resume, it reads what is there and hands each share
/// to [onShare], which is the *same* sink an Android `SEND` intent arrives
/// through. From that point on the two platforms are one code path: the share
/// sheet, the same resolver, the same send.
///
/// ## Everything it reads, it removes
///
/// A drain that leaves a blob behind is a drain that offers the same share again
/// on the next resume. So every blob it reads takes exactly one of two exits —
/// ingested, or removed — and there is no third. That covers the ugly cases for
/// free: a truncated blob, a blob from a build that wrote a field this one does
/// not understand, a share captured eight days ago.
///
/// ## Why it cannot send twice
///
/// Three things, in order of how much they matter:
///
/// 1. The drain does not send. It opens the share sheet, which needs a tap. The
///    worst a duplicate could do is ask twice.
/// 2. [ingestStagedShare] deletes the blob *before* it moves anything, so a
///    second reader — a resume racing a launch, a process killed halfway —
///    cannot find the share to begin with.
/// 3. [_handled] holds every id this run has committed to, recorded before the
///    first `await`, so two overlapping drains inside one process cannot both
///    reach the same share between the read and the delete.
class StagedShareReader {
  StagedShareReader({
    required StagedShareGateway gateway,
    ShareStagingCodec codec = const ShareStagingCodec(),
    Duration ttl = kStagedShareTtl,
  }) : _gateway = gateway,
       _codec = codec,
       _ttl = ttl;

  final StagedShareGateway _gateway;
  final ShareStagingCodec _codec;
  final Duration _ttl;

  /// Where a drained share goes.
  ///
  /// The same signature — and in the app the same closure — as
  /// [WeftIntents.onShare], because a share staged by the extension and a share
  /// arriving as an Android intent are the same thing at this point. Null before
  /// the app wires it up, in which case a drain still removes what has expired
  /// but delivers nothing.
  void Function(SharedPayload payload)? onShare;

  /// Ids this run has committed to ingesting.
  ///
  /// Bounded by the number of shares actually staged, which is a handful. Not
  /// persisted, and does not need to be: the blob is deleted at ingestion, so
  /// nothing survives a restart for this to recognise.
  final Set<String> _handled = {};

  /// A drain is running. A second one would read blobs the first has not
  /// deleted yet.
  bool _draining = false;

  @visibleForTesting
  bool get isDraining => _draining;

  /// Reads the container, delivers what is in it, and removes the rest.
  ///
  /// Cheap enough for launch and every resume: with an empty container it is one
  /// channel call answering with an empty list. Never throws — this is on the
  /// launch path, and a share the user has already forgotten about must not be
  /// able to stop the app starting.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      await _drainOnce();
    } on Object catch (error, stack) {
      // Deliberately Object. Behind the gateway is a method channel and another
      // process's filesystem, and every way that fails has the same answer:
      // there are no staged shares this time.
      debugPrint('weft: staged shares could not be drained: $error\n$stack');
    } finally {
      _draining = false;
    }
  }

  Future<void> _drainOnce() async {
    final blobs = await _gateway.readStagedShares(ttl: _ttl);
    if (blobs.isEmpty) return;

    final now = clock.now();
    final ready = <_PendingShare>[];
    for (final blob in blobs) {
      final share = _handled.contains(blob.id)
          ? null
          : _codec.decode(blob.json);
      if (share == null || share.isExpiredAt(now, ttl: _ttl)) {
        await _remove(blob.id);
        continue;
      }
      ready.add(_PendingShare(blob.id, share));
    }

    // Oldest capture first, which is what `decodeAll` would have done — but that
    // returns bare shares, and the id a share is *addressed* by on disk is the
    // one its filename carries, not the one inside it. Losing that association
    // would mean nothing could be deleted.
    ready.sort((a, b) => a.share.capturedAt.compareTo(b.share.capturedAt));

    for (final pending in ready) {
      // Before the await, so an overlapping drain cannot reach the same share
      // in the window between reading it and the platform deleting its blob.
      _handled.add(pending.id);
      await _deliver(pending);
    }
  }

  Future<void> _deliver(_PendingShare pending) async {
    final share = pending.share;
    final resolved = await _gateway.ingestStagedShare(pending.id, share.files);

    final uris = <String>[];
    final types = <String>{};
    for (final file in share.files) {
      final path = resolved[file.relativePath];
      // Missing means the move failed, or the blob named a path outside the
      // container — the platform refuses those rather than opening them.
      if (path == null || path.isEmpty) continue;
      uris.add(Uri.file(path).toString());
      types.add(file.mimeType);
    }

    final payload = SharedPayload(
      text: share.text,
      mimeType: _batchMimeType(types),
      uris: uris,
      targetChatId: share.targetChatId,
    );
    // Everything failed to move and there was no text alongside it. The share is
    // already gone from the container; opening an empty sheet on top of whatever
    // the user was doing adds nothing.
    if (payload.isEmpty) return;
    onShare?.call(payload);
  }

  /// The batch-level hint, in the shape an Android `SEND_MULTIPLE` gives it.
  ///
  /// Only a hint, and a weak one: the extension guesses from a filename
  /// extension and gives up entirely below iOS 14, and everything downstream
  /// re-sniffs from the bytes through [sniffMimeType]. Its one job is to be the
  /// fallback for a file whose own name says nothing, so a single-type batch
  /// passes its type on and a mixed one says `*/*` rather than claiming the
  /// first file's type for all of them.
  static String? _batchMimeType(Set<String> types) {
    final known = types
        .where((type) => type != kFallbackStagedMimeType)
        .toSet();
    if (known.isEmpty) return types.isEmpty ? null : kFallbackStagedMimeType;
    return known.length == 1 ? known.single : '*/*';
  }

  Future<void> _remove(String id) async {
    try {
      await _gateway.removeStagedShare(id);
    } on Object catch (error) {
      // One blob that will not delete is one blob re-read next launch, not a
      // drain that stops halfway and leaves the rest behind it.
      debugPrint('weft: staged share $id could not be removed: $error');
    }
  }
}

/// A decoded share and the container id it is addressed by.
@immutable
class _PendingShare {
  const _PendingShare(this.id, this.share);

  final String id;
  final StagedShare share;
}

/// The App Group container over `com.bostrot.weft/share`.
///
/// iOS only. On every other platform the channel has no handler, which surfaces
/// as [MissingPluginException] and is answered here as "there is nothing
/// staged" — the same answer an iPhone with an empty container gives, and the
/// reason the drain can be called unconditionally from `main.dart`.
///
/// It is also the iOS [ShareTargetPublisher]. Android publishes the ranked list
/// as launcher shortcuts; iOS writes the same list into the container for the
/// extension's picker to read. Same ranker, same diff, same
/// [ShareShortcutService] — only the last step differs, which is exactly what
/// the seam is for.
class WeftStagedShares implements StagedShareGateway, ShareTargetPublisher {
  WeftStagedShares({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.bostrot.weft/share');

  final MethodChannel _channel;
  final ShareStagingCodec _codec = const ShareStagingCodec();

  @override
  Future<List<StagedShareBlob>> readStagedShares({
    required Duration ttl,
  }) async {
    final raw = await _invoke<List<Object?>>('readStagedShares', {
      'ttlSeconds': ttl.inSeconds,
    });
    return [
      for (final entry in raw ?? const []) ?StagedShareBlob.fromMap(entry),
    ];
  }

  @override
  Future<Map<String, String>> ingestStagedShare(
    String id,
    List<StagedFile> files,
  ) async {
    final raw = await _invoke<Map<Object?, Object?>>('ingestStagedShare', {
      'id': id,
      // Only what the platform needs to move a file: where it is, and what to
      // call it once it is somewhere else. The name is the user's — the
      // container's copy is prefixed with an index to keep a Photos
      // multi-select of two `IMG_0001.HEIC` apart, and that prefix must not
      // reach the room.
      'files': [
        for (final file in files)
          {'path': file.relativePath, 'name': file.name},
      ],
    });
    return {
      for (final entry in (raw ?? const {}).entries)
        if (entry.key is String && entry.value is String)
          entry.key! as String: entry.value! as String,
    };
  }

  @override
  Future<void> removeStagedShare(String id) async {
    await _invoke<void>('removeStagedShare', {'id': id});
  }

  @override
  Future<bool> writeShareTargets(String json) async =>
      await _invoke<bool>('writeShareTargets', {'json': json}) ?? false;

  /// Writes [slots] where the extension's picker will find them.
  ///
  /// The maps arrive as `ShareTargetSlot.toJson()` plus the `iconPath`
  /// [ShareShortcutService] resolved, so they are turned back into slots and
  /// re-encoded through [ShareStagingCodec.encodeTargets] rather than written
  /// out as they are. That keeps one description of the target file's shape —
  /// the codec's, which `ShareTarget.decodeAll` in `ShareViewController.swift`
  /// is written against — instead of a second one here that could drift from it.
  /// `iconPath` is dropped on the way through, and would be useless if it were
  /// not: it points into the app's own container, which the extension is not
  /// entitled to read, and the picker draws initials for that reason.
  ///
  /// Returns how many were written, or zero when the container is not there —
  /// an unsigned build, or a profile predating the App Group. Zero against a
  /// non-empty request is read by the caller as a refusal to retry, which is
  /// the right reading: the next inbox tick tries again, and a device that gets
  /// its entitlement at the next install starts working without a reinstall of
  /// its own.
  @override
  Future<int> publishShareTargets(List<Map<String, Object?>> slots) async {
    final decoded = [for (final slot in slots) ?ShareTargetSlot.fromJson(slot)];
    final written = await writeShareTargets(_codec.encodeTargets(decoded));
    return written ? decoded.length : 0;
  }

  /// Empties the picker's list.
  ///
  /// An empty file rather than a deleted one: the extension reads this on a
  /// path where a missing file and an empty list mean the same thing, and
  /// writing is the operation that is atomic.
  @override
  Future<void> clearShareTargets() async {
    await writeShareTargets(_codec.encodeTargets(const []));
  }

  /// [method], or null for every way the platform can decline to answer.
  ///
  /// Both branches are ordinary rather than exceptional. [MissingPluginException]
  /// is every platform that is not iOS. [PlatformException] is a container the
  /// build is not entitled to reach, which is what an unsigned CI build and a
  /// stale provisioning profile both look like — and neither is a reason to
  /// throw out of a launch-path drain.
  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('weft: share container refused $method: ${error.message}');
      return null;
    }
  }
}
