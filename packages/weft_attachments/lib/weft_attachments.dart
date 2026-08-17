/// The attachment pipeline's core: what a file is, what Weft will send for it,
/// and how that send is queued and retried.
///
/// Pure Dart, and pointedly so. The subtle parts here — magic-byte sniffing of
/// files that arrive from outside the app's control, the fact that a plain room
/// carries the mxc URI under `url` while an encrypted one carries it under
/// `file.url`, and a queue that must bound its own concurrency — are all
/// decisions, not I/O. Transport is injected behind an interface so every one of
/// them is testable without a homeserver, a device, or a byte on disk.
library;

// Consumers import this barrel, never src/.
export 'src/detect.dart';
export 'src/plan.dart';
export 'src/queue.dart';
