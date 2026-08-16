import 'package:meta/meta.dart';

import 'network.dart';

/// One person as they exist on one network.
///
/// A handle is the atom of merging: "Anna on WhatsApp" and "Anna on Signal" are
/// two handles that may or may not point at the same human. Everything the
/// merge scorer reasons about lives here.
@immutable
class NetworkHandle {
  const NetworkHandle({
    required this.id,
    required this.network,
    required this.remoteId,
    required this.matrixUserId,
    this.roomId,
    this.displayName,
    this.avatarUrl,
    this.phoneE164,
    this.email,
    this.avatarDHash,
    this.unifiedContactId,
  });

  /// Stable local primary key.
  final String id;

  final ChatNetwork network;

  /// Identifier native to [network] — a phone number, username, or opaque id.
  final String remoteId;

  /// The ghost user the bridge puppets on the homeserver, e.g.
  /// `@whatsapp_4915112345678:example.org`.
  final String matrixUserId;

  /// The direct-message room with this handle, when one exists. Null for
  /// handles only ever seen inside a group.
  final String? roomId;

  final String? displayName;
  final String? avatarUrl;

  /// Phone number normalised to E.164 (`+4915112345678`), when known. The
  /// single strongest merge signal.
  final String? phoneE164;

  final String? email;

  /// Perceptual hash of the avatar. 64-bit dHash stored as an `int`; compared
  /// by Hamming distance so a re-encoded or rescaled avatar still matches.
  final int? avatarDHash;

  /// The contact this handle has been merged into, or null when unmerged.
  final String? unifiedContactId;

  bool get isMerged => unifiedContactId != null;

  NetworkHandle copyWith({
    String? displayName,
    String? avatarUrl,
    String? phoneE164,
    String? email,
    int? avatarDHash,
    String? roomId,
    Object? unifiedContactId = _sentinel,
  }) {
    return NetworkHandle(
      id: id,
      network: network,
      remoteId: remoteId,
      matrixUserId: matrixUserId,
      roomId: roomId ?? this.roomId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      phoneE164: phoneE164 ?? this.phoneE164,
      email: email ?? this.email,
      avatarDHash: avatarDHash ?? this.avatarDHash,
      unifiedContactId: identical(unifiedContactId, _sentinel)
          ? this.unifiedContactId
          : unifiedContactId as String?,
    );
  }

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) => other is NetworkHandle && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'NetworkHandle($id, ${network.id}, $displayName)';
}
