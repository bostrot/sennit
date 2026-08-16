import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'handle.dart';
import 'network.dart';

/// One human, across every network they appear on.
///
/// A contact owns one or more [NetworkHandle]s. A contact with a single handle
/// is the ordinary unmerged case and is deliberately not special — it keeps the
/// rest of the app from branching on "merged or not".
@immutable
class UnifiedContact {
  const UnifiedContact({
    required this.id,
    required this.displayName,
    required this.handles,
    this.avatarUrl,
    this.pinned = false,
  });

  final String id;

  /// User-chosen name, falling back to the best handle's name at merge time.
  final String displayName;

  final List<NetworkHandle> handles;
  final String? avatarUrl;
  final bool pinned;

  bool get isMerged => handles.length > 1;

  /// Networks this contact is reachable on, in stable enum order so the UI
  /// doesn't reshuffle chips between rebuilds.
  List<ChatNetwork> get networks {
    final seen = handles.map((h) => h.network).toSet();
    return ChatNetwork.values.where(seen.contains).toList(growable: false);
  }

  /// The handle to use when sending on [network], if any.
  NetworkHandle? handleFor(ChatNetwork network) =>
      handles.firstWhereOrNull((h) => h.network == network);

  /// Rooms backing this contact — the inputs to a merged timeline.
  List<String> get roomIds => handles
      .map((h) => h.roomId)
      .whereType<String>()
      .toSet()
      .toList(growable: false);

  UnifiedContact copyWith({
    String? displayName,
    List<NetworkHandle>? handles,
    String? avatarUrl,
    bool? pinned,
  }) {
    return UnifiedContact(
      id: id,
      displayName: displayName ?? this.displayName,
      handles: handles ?? this.handles,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      pinned: pinned ?? this.pinned,
    );
  }

  @override
  bool operator ==(Object other) => other is UnifiedContact && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'UnifiedContact($id, $displayName, ${handles.length} handles)';
}
