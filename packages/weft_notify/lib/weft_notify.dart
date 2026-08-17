/// The notification decision layer: whether an event deserves a notification,
/// what it should say, and which conversation it belongs to.
///
/// Pure Dart, and pointedly so. The hard parts here are decisions, not
/// delivery. Whether a message is suppressed depends on the user's policy, the
/// mute state of each source of a merged chat, quiet hours, and whether the
/// message was already read on another device — none of which needs a device to
/// evaluate. Grouping is harder still: one person's WhatsApp and Signal legs
/// must collapse into a single notification thread, which is only correct if
/// this package keys off the merged `Chat.id` the app already resolved rather
/// than re-deriving one from a room id.
///
/// Platform delivery — FCM, APNs, `flutter_local_notifications` — sits on top of
/// this package in `apps/weft`, and takes the decisions produced here as input.
/// Nothing in `lib/` may import Flutter or touch I/O.
library;

// Consumers import this barrel, never src/.
export 'src/content.dart';
export 'src/rules.dart';
