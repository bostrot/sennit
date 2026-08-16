/// Chat merging: deciding which handles are the same person, and interleaving
/// their conversations into one correctly-ordered timeline.
///
/// Pure Dart. The watermark logic in [MergedTimeline] is the subtlest code in
/// Weft, and it is testable here without a homeserver, a device, or a bridge.
library;

export 'src/identity_graph.dart';
export 'src/scoring/merge_scorer.dart';
export 'src/scoring/similarity.dart';
export 'src/timeline/merged_timeline.dart';
export 'src/timeline/timeline_source.dart';
