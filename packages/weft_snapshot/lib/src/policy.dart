import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// How many rows a snapshot carries before it stops.
///
/// Sized off the widest thing that renders one, with headroom and no more. The
/// large WidgetKit family fits about six rows at the default text size and the
/// Glance list widget about eight; a watch conversation list scrolls, but a
/// wrist is not where anyone reads their fortieth conversation. Sixteen covers
/// every surface twice over.
///
/// The cap is not only about layout. Every row is a title, a preview and a
/// timestamp that has left the encrypted store, so a smaller number is a
/// smaller disclosure — and each row multiplies against [kMaxSnapshotBytes],
/// which is the limit that actually breaks a surface when it is exceeded.
const int kDefaultSnapshotRowCap = 16;

/// The privacy gate on companion surfaces.
///
/// The third instance of a shape the codebase has settled on — after
/// `TranscriptionSettings` and `LinkPreviewSettings` — and deliberately
/// recognisable as the same object: [enabled] is false until someone turns it
/// on, [excludedNetworks] holds `ChatNetwork.id` strings for the conversations
/// that stay out whatever the master switch says, [allows] is the predicate,
/// and [off] is the fallback. A gate that opens when it cannot find its own
/// configuration is not a gate.
///
/// **Why two preview flags and not one.** `weft_notify` documents previews-off
/// as hiding the message *body* while keeping the conversation title and the
/// sender — Android's "hide sensitive content", not iOS's "hide previews" — and
/// says a caller wanting the stricter reading degrades the title and sender as
/// a second, separate step. [includePreviews] and [includeSenderNames] are that
/// split, made into two switches because it is two decisions: "don't show what
/// they said" and "don't show who they are" are not the same worry, and a
/// widget on a desk in an open-plan office is the surface where the difference
/// bites.
///
/// **Where `fromStore` and `writeTo` are.** With the other two gates, in the app
/// layer: `SettingsStore` lives in `weft_store`, which depends on Flutter and
/// on sqlite, and this package must stay pure Dart so that Glance's and
/// WidgetKit's payload can be decided in a unit test. The keys belong under
/// `privacy.*` beside `privacy.link_preview_excluded`, and the reading and
/// writing of them is Phase 10's task 4.
@immutable
class SnapshotPolicy {
  const SnapshotPolicy({
    this.enabled = false,
    this.includePreviews = false,
    this.includeSenderNames = false,
    this.excludedNetworks = const {},
    this.maxRows = kDefaultSnapshotRowCap,
  });

  /// Off, with nothing disclosed. What an app that has never been configured
  /// is in, and what a failed settings read falls back to.
  ///
  /// Note that both content flags are false here and in the unnamed
  /// constructor: `SnapshotPolicy(enabled: true)` writes a snapshot of unread
  /// counts and nothing else. That is on purpose — a policy assembled by naming
  /// one field discloses only what that field named, and the surfaces screen
  /// turns the other two on where the user can see the sentence that says what
  /// they cost.
  static const SnapshotPolicy off = SnapshotPolicy();

  /// Whether anything at all is written to the shared container.
  final bool enabled;

  /// Whether a row carries what the last message said.
  final bool includePreviews;

  /// Whether a row carries who the conversation is with — its title, the last
  /// sender's name, and the avatar.
  ///
  /// The avatar travels under this flag rather than one of its own because for
  /// a DM the avatar *is* the other person's face, and a row showing it beside
  /// a redacted title has not redacted anything.
  final bool includeSenderNames;

  /// `ChatNetwork.id` strings that never reach a companion surface.
  final Set<String> excludedNetworks;

  /// Maximum rows in a snapshot. See [kDefaultSnapshotRowCap].
  final int maxRows;

  /// Whether [network] may appear on a companion surface at all.
  bool allows(ChatNetwork network) =>
      enabled && !excludedNetworks.contains(network.id);

  /// [maxRows] as a count that can actually be taken from a list.
  ///
  /// A negative cap is a settings-write bug rather than an instruction to take
  /// rows from the other end, and it reaches here through a key/value store
  /// with no schema to stop it.
  int get rowCap => maxRows < 0 ? 0 : maxRows;

  SnapshotPolicy copyWith({
    bool? enabled,
    bool? includePreviews,
    bool? includeSenderNames,
    Set<String>? excludedNetworks,
    int? maxRows,
  }) => SnapshotPolicy(
    enabled: enabled ?? this.enabled,
    includePreviews: includePreviews ?? this.includePreviews,
    includeSenderNames: includeSenderNames ?? this.includeSenderNames,
    excludedNetworks: excludedNetworks ?? this.excludedNetworks,
    maxRows: maxRows ?? this.maxRows,
  );

  @override
  bool operator ==(Object other) =>
      other is SnapshotPolicy &&
      other.enabled == enabled &&
      other.includePreviews == includePreviews &&
      other.includeSenderNames == includeSenderNames &&
      other.maxRows == maxRows &&
      const SetEquality<String>().equals(
        other.excludedNetworks,
        excludedNetworks,
      );

  @override
  int get hashCode => Object.hash(
    enabled,
    includePreviews,
    includeSenderNames,
    maxRows,
    const SetEquality<String>().hash(excludedNetworks),
  );

  @override
  String toString() =>
      'SnapshotPolicy(enabled: $enabled, previews: $includePreviews, '
      'names: $includeSenderNames, excluded: $excludedNetworks, '
      'maxRows: $maxRows)';
}
