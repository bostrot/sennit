/// The share surfaces' core: who gets offered as a share target, in what order,
/// and what a share looks like while it is waiting for the app to wake up.
///
/// Pure Dart, and pointedly so. Android publishes conversation shortcuts through
/// the People API and iOS runs a Share Extension in a separate process with no
/// Matrix session at all — two mechanisms with nothing in common except the two
/// questions they both have to answer: *which conversations, in what order*, and
/// *what shape does a captured share take on disk*. Both answers are decisions,
/// not platform calls, so both live here and are tested without a device.
///
/// Three pieces:
///
/// * [ShareTargetRanker] orders conversations by pinned state, decayed recency
///   and decayed send frequency, and filters out any whose networks cannot
///   carry what is being shared.
/// * [ShareTargetSlot] is the published shape — the id the launcher and the
///   notification bubble share, the labels, the avatar to resolve, the deep
///   link.
/// * [StagedShare] and [ShareStagingCodec] are the App Group container's
///   contract: a share captured by an extension, written as JSON that a
///   hand-written Swift encoder produces and a decoder that never throws reads
///   back.
///
/// Nothing here touches the filesystem, a method channel or Flutter. The
/// publishers do, in `apps/weft/lib/services/share/`.
library;

// Consumers import this barrel, never src/.
export 'src/capability.dart';
export 'src/content.dart';
export 'src/ranker.dart';
export 'src/slot.dart';
export 'src/staging.dart';
