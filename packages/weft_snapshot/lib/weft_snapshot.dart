/// What a home screen widget, a Lock Screen accessory and a watch app are
/// allowed to know about the inbox.
///
/// None of those surfaces can decrypt a Matrix room. Not "does not" — cannot: a
/// WidgetKit extension has no Matrix session, a Glance provider has no Flutter
/// engine, and a watch app has neither and no keys either. So they render a
/// *snapshot*: a small, deliberately minimal view of the inbox that the host
/// app writes into a shared container, and nothing else.
///
/// Which makes the interesting question a privacy one rather than a layout one.
/// A widget row is message content sitting outside the encrypted store, on a
/// home screen, in a file the OS and any device-level backup can read. That is
/// a real cost and it gets the same treatment as remote transcription and
/// remote embedding: off by default, one plain sentence saying what turning it
/// on does, per-network exclusion for the conversations that must never appear,
/// and separate switches for "what they said" and "who they are".
///
/// Three pieces:
///
/// * [SnapshotPolicy] — the gate. The third instance of a shape the codebase
///   has settled on, after `TranscriptionSettings` and `LinkPreviewSettings`.
/// * [InboxSnapshot] and [SnapshotRow] — the payload. Every string already
///   filtered, truncated and linked, because there is no second filter on the
///   far side of the process boundary and there cannot be one.
/// * [SnapshotCodec] — the wire format. Versioned, size-capped on both sides,
///   and total on decode: a widget that crashes is a widget the OS stops
///   scheduling.
///
/// Pure Dart, so all of it is decided in one test file rather than in three
/// platform reviews. The writer, the platform channels and the surfaces
/// themselves live in `apps/weft/lib/services/snapshot/`,
/// `apps/weft/android/` and `apps/weft/ios/`.
library;

// Consumers import this barrel, never src/.
export 'src/codec.dart';
export 'src/policy.dart';
export 'src/snapshot.dart';
