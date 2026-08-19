import 'dart:convert';

import 'package:meta/meta.dart';

import 'snapshot.dart';

/// The hard ceiling on an encoded snapshot, in bytes.
///
/// A number with a mechanism behind it rather than a round one, because every
/// surface that reads this payload is the memory-constrained side of its own
/// process boundary:
///
/// * **Wear OS** carries the snapshot over the Wearable Data Layer, where a
///   single `DataItem` is rejected outright above 100 KB. Anything larger has
///   to be split into `Asset`s, which is a second transport for a payload whose
///   whole point is to be small.
/// * **Android widgets** update through `RemoteViews`, which crosses a Binder
///   transaction with a ~1 MB budget *shared by every transaction in flight* —
///   so a large widget update fails on a busy device rather than on a big one,
///   which is the kind of bug that never reproduces.
/// * **WidgetKit** runs its extension under a memory limit low enough that
///   decoding megabytes of JSON is how a widget stops being scheduled at all.
///
/// 64 KiB sits under the tightest of those with room to spare, and comfortably
/// holds [kDefaultSnapshotRowCap] rows of an 80-character preview, a title, a
/// link and a timestamp. The cap is enforced on **both** sides: [encode] never
/// emits a payload above it, and [decode] refuses one, because the writer is
/// the process with the memory to spare and the reader is the one that gets
/// killed.
const int kMaxSnapshotBytes = 64 * 1024;

/// Reads and writes the [InboxSnapshot] JSON in the shared container.
///
/// **Every decode is total**, for the reason `ShareStagingCodec` gives and one
/// more of its own. The writer is a host app the system can suspend between the
/// first byte of the file and the last; the reader is a widget extension that
/// the OS stops scheduling if it crashes, and which the user then sees as a
/// blank rectangle they eventually delete. So a payload that cannot be read is
/// dropped, and the surface shows its "open Weft on your phone" state — which
/// is a state it needs anyway, for a phone that has not been unlocked all day.
///
/// **Version is load-bearing here.** `weft_share` can treat its version as
/// diagnostic because a Share Extension ships inside the app bundle, so a
/// reader older than its writer cannot exist. A widget or watch process can be
/// held by the OS across an app update, so here it can and does. [decode]
/// therefore accepts a version above its own and reads what it recognises,
/// flagging it as [InboxSnapshot.isFutureVersion] rather than refusing: an
/// unread count and a chat id mean the same thing in every version this format
/// will ever have, and refusing them costs the user a working widget to protect
/// them from a field that might be spelled differently.
///
/// **No `extras`.** `StagedShare` carries unknown top-level keys through
/// re-encoding because its reader also *writes* — the drain re-stages a share
/// it could not finish ingesting. Nothing on this side ever writes the payload
/// back: the phone writes, the surfaces read, and a snapshot is regenerated
/// from the inbox rather than edited. Unknown keys are therefore ignored, and
/// nothing is lost by ignoring them.
///
/// The key names are a cross-language contract. `WeftWidget.swift` and the
/// Glance provider parse this JSON by hand with no Dart on their side of it, so
/// renaming a key here is a silent break there.
@immutable
class SnapshotCodec {
  const SnapshotCodec({this.maxBytes = kMaxSnapshotBytes});

  /// The size cap this instance enforces. Injectable so a test can prove the
  /// cap works without building a 64 KiB inbox.
  final int maxBytes;

  /// [snapshot] as JSON, guaranteed to be at most [maxBytes].
  ///
  /// Oversize snapshots lose rows from the end — the least recent ones — rather
  /// than being written whole and rejected by the reader. Half a list is a
  /// widget; a payload the extension refuses is a blank rectangle.
  /// [InboxSnapshot.totalUnread] is not recomputed as rows are dropped, because
  /// it never counted only the visible ones.
  String encode(InboxSnapshot snapshot) {
    var current = snapshot;
    var encoded = jsonEncode(current.toJson());
    while (_byteLength(encoded) > maxBytes && current.rows.isNotEmpty) {
      current = current.copyWith(
        rows: current.rows.sublist(0, current.rows.length - 1),
      );
      encoded = jsonEncode(current.toJson());
    }
    return encoded;
  }

  /// [raw], or null when it is not a usable snapshot.
  ///
  /// Refused, in every case without throwing:
  ///
  /// * null, empty or blank input — a writer killed before its first write;
  /// * anything past [maxBytes], which is what a partially overwritten file or
  ///   a payload from a build with a larger cap looks like, and which the
  ///   reader is the wrong process to try to hold;
  /// * anything `jsonDecode` cannot parse, which is what a write killed partway
  ///   through looks like;
  /// * a root that is not a JSON object.
  ///
  /// Everything else degrades. A missing `generatedAt` reads as the epoch,
  /// which makes the snapshot maximally stale and sends the surface to its
  /// "open Weft on your phone" state — the right answer for a payload that
  /// cannot say when it was written. A missing `enabled` reads as true, since
  /// the switched-off payload is the one that states it. Rows that are not
  /// usable are skipped individually rather than taking the payload with them.
  InboxSnapshot? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    // The cheap check first: a UTF-16 code unit is never more than one UTF-8
    // byte's worth of length, so a string longer than the cap is over it
    // whatever it contains — and this avoids encoding a payload that is absurd
    // rather than merely too big.
    if (raw.length > maxBytes || _byteLength(raw) > maxBytes) return null;

    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;

    final version = parsed['version'];
    final enabled = parsed['enabled'];
    final totalUnread = parsed['totalUnread'];

    final rows = <SnapshotRow>[
      for (final row in _listOrEmpty(parsed['rows']))
        ?SnapshotRow.fromJson(row),
    ];

    return InboxSnapshot(
      generatedAt:
          parseSnapshotTimestamp(parsed['generatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      rows: rows,
      // Falls back to the visible rows rather than to zero: a snapshot that
      // says "0 unread" when it has rows carrying unread counts is wrong in a
      // way the user reads as messages having been marked read.
      totalUnread: totalUnread is int && totalUnread >= 0
          ? totalUnread
          : rows.fold<int>(0, (sum, row) => sum + row.unreadCount),
      enabled: enabled is bool ? enabled : true,
      version: version is int && version > 0 ? version : kSnapshotFormatVersion,
    );
  }

  /// A cast would be shorter and would throw a [TypeError], which the
  /// [FormatException] guard above is not looking for — and the readers on the
  /// other side are hand-written Swift and Kotlin with no compiler checking
  /// these key names, so a `rows` that arrives as a string is a skew to survive
  /// rather than an impossibility.
  static List<Object?> _listOrEmpty(Object? raw) =>
      raw is List ? raw : const [];

  static int _byteLength(String raw) => utf8.encode(raw).length;
}
