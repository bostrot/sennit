import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

import 'content.dart';

/// Every attachment kind a share can actually arrive as.
///
/// [MessageKind.location], [MessageKind.poll], [MessageKind.sticker] and
/// [MessageKind.event] are absent because nothing shares one into Weft — they
/// are shapes the timeline renders, not files a share sheet hands over.
const Set<MessageKind> kShareableKinds = {
  MessageKind.image,
  MessageKind.video,
  MessageKind.audio,
  MessageKind.voice,
  MessageKind.file,
};

/// What one network will take as an attachment.
///
/// This describes the **remote network**, not the bridge and not the
/// homeserver. A file that clears this still has to clear the homeserver's
/// `m.upload.size` (which `planUpload` enforces) and Weft's own
/// `kMaxSharedFileBytes` — three caps that measure three different things, and
/// none of which replaces the others.
///
/// The numbers below are approximations, and are deliberately set at the
/// *generous* end of what each network documents. The cost of the two errors is
/// not symmetric: a cap set too low silently hides a conversation the user was
/// looking for and gives them no way to find out why, while a cap set too high
/// offers a target whose send then fails with a sentence explaining itself.
/// Hiding is the worse failure, so ambiguity resolves toward allowing.
@immutable
class NetworkShareCapability {
  const NetworkShareCapability({
    required this.network,
    this.kinds = kShareableKinds,
    this.maxAttachmentBytes,
  });

  final ChatNetwork network;

  /// Attachment kinds the network carries. An empty set means text only.
  final Set<MessageKind> kinds;

  /// Largest single attachment, or null when no limit is known.
  ///
  /// Null means *unknown*, never *zero*: an unrecognised network must not have
  /// its chats filtered away on the strength of a value nobody supplied.
  final int? maxAttachmentBytes;

  /// Whether this network can carry [item].
  bool accepts(ShareItem item) {
    if (!kinds.contains(item.kind)) return false;
    final cap = maxAttachmentBytes;
    return cap == null || item.sizeBytes <= cap;
  }

  /// Whether this network can carry every file in [content].
  ///
  /// A share is one gesture; offering a target that takes four of five files
  /// and then fails on the fifth is worse than not offering it.
  bool acceptsAll(ShareContent content) =>
      content.items.every(accepts);

  @override
  String toString() =>
      'NetworkShareCapability(${network.id}, ${kinds.length} kinds, '
      '${maxAttachmentBytes ?? 'no'} cap)';
}

/// The per-network capability table, with room for the app to override it.
///
/// Held as a value object rather than a bare map so the defaults and the
/// lookup live together: every caller that filters targets — the ranker, and
/// the per-target network chips in the share sheet — asks the same object the
/// same question and gets the same answer.
@immutable
class NetworkShareCapabilities {
  /// [overrides] replaces the default entry for a network entirely; it does not
  /// merge field by field. A caller that wants "WhatsApp, but 16 MB" builds the
  /// whole [NetworkShareCapability] and hands it over.
  const NetworkShareCapabilities([this.overrides = const {}]);

  final Map<ChatNetwork, NetworkShareCapability> overrides;

  /// Defaults, keyed by network. Anything absent falls through to [_permissive].
  ///
  /// Sources are each network's own published limits for a direct message, at
  /// the point Phase 04 was written. They drift, which is why [overrides]
  /// exists — a value here being a year out of date should cost a settings
  /// change, not a release.
  static const Map<ChatNetwork, NetworkShareCapability> defaults = {
    // The homeserver's `m.upload.size` is the only limit, and the upload
    // planner already enforces it against the real number.
    ChatNetwork.matrix: NetworkShareCapability(network: ChatNetwork.matrix),

    ChatNetwork.whatsapp: NetworkShareCapability(
      network: ChatNetwork.whatsapp,
      maxAttachmentBytes: 2 * 1024 * 1024 * 1024,
    ),
    ChatNetwork.signal: NetworkShareCapability(
      network: ChatNetwork.signal,
      maxAttachmentBytes: 100 * 1024 * 1024,
    ),
    ChatNetwork.telegram: NetworkShareCapability(
      network: ChatNetwork.telegram,
      maxAttachmentBytes: 2 * 1024 * 1024 * 1024,
    ),

    // Instagram DMs take media and nothing else — there is no attach-a-PDF.
    ChatNetwork.instagram: NetworkShareCapability(
      network: ChatNetwork.instagram,
      kinds: {MessageKind.image, MessageKind.video, MessageKind.audio,
        MessageKind.voice},
      maxAttachmentBytes: 100 * 1024 * 1024,
    ),
    ChatNetwork.messenger: NetworkShareCapability(
      network: ChatNetwork.messenger,
      maxAttachmentBytes: 25 * 1024 * 1024,
    ),
    ChatNetwork.discord: NetworkShareCapability(
      network: ChatNetwork.discord,
      maxAttachmentBytes: 25 * 1024 * 1024,
    ),
    ChatNetwork.slack: NetworkShareCapability(
      network: ChatNetwork.slack,
      maxAttachmentBytes: 1024 * 1024 * 1024,
    ),
    ChatNetwork.imessage: NetworkShareCapability(
      network: ChatNetwork.imessage,
      maxAttachmentBytes: 100 * 1024 * 1024,
    ),
    ChatNetwork.linkedin: NetworkShareCapability(
      network: ChatNetwork.linkedin,
      kinds: {MessageKind.image, MessageKind.video, MessageKind.file},
      maxAttachmentBytes: 20 * 1024 * 1024,
    ),
    ChatNetwork.googlechat: NetworkShareCapability(
      network: ChatNetwork.googlechat,
      maxAttachmentBytes: 200 * 1024 * 1024,
    ),
    ChatNetwork.gmessages: NetworkShareCapability(
      network: ChatNetwork.gmessages,
      maxAttachmentBytes: 100 * 1024 * 1024,
    ),

    // X DMs take pictures and video, not documents.
    ChatNetwork.twitter: NetworkShareCapability(
      network: ChatNetwork.twitter,
      kinds: {MessageKind.image, MessageKind.video},
      maxAttachmentBytes: 100 * 1024 * 1024,
    ),
    // Bluesky's chat carries images only, and small ones. This is the entry
    // that most often removes a target, and the one most worth being right.
    ChatNetwork.bluesky: NetworkShareCapability(
      network: ChatNetwork.bluesky,
      kinds: {MessageKind.image},
      maxAttachmentBytes: 1024 * 1024,
    ),
    // MMS. No documents, and a payload ceiling set by the carrier rather than
    // by anyone the user can appeal to.
    ChatNetwork.sms: NetworkShareCapability(
      network: ChatNetwork.sms,
      kinds: {MessageKind.image, MessageKind.video, MessageKind.audio,
        MessageKind.voice},
      maxAttachmentBytes: 1024 * 1024,
    ),
    ChatNetwork.email: NetworkShareCapability(
      network: ChatNetwork.email,
      maxAttachmentBytes: 25 * 1024 * 1024,
    ),
  };

  /// The fallback: takes anything, of any size.
  ///
  /// [ChatNetwork.unknown] lands here, and so does any network added to the
  /// enum without a row above. Both are cases where Weft knows nothing, and
  /// knowing nothing is not a reason to hide someone's conversation.
  static const NetworkShareCapability _permissive = NetworkShareCapability(
    network: ChatNetwork.unknown,
  );

  NetworkShareCapability forNetwork(ChatNetwork network) =>
      overrides[network] ?? defaults[network] ?? _permissive;

  /// Whether [network] can carry all of [content].
  bool canCarry(ChatNetwork network, ShareContent content) =>
      content.isTextOnly || forNetwork(network).acceptsAll(content);

  /// The networks of [chat] that can carry [content], in [Chat.networks] order.
  ///
  /// This is what the share sheet's per-target network chips render, and what
  /// makes the answer to "why can't I pick Signal here" visible rather than
  /// inferred: the chip is absent because this returned without it.
  List<ChatNetwork> capableNetworks(Chat chat, ShareContent content) => [
    for (final network in chat.networks)
      if (canCarry(network, content)) network,
  ];

  /// Whether any leg of [chat] can carry [content].
  bool canReach(Chat chat, ShareContent content) =>
      chat.networks.any((network) => canCarry(network, content));
}
