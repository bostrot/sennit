/// Weft's Matrix layer: session lifecycle, E2EE, and the mapping from Matrix
/// events onto Weft's domain model.
///
/// Everything SDK-shaped stops here. `weft_merge` and the UI below it see only
/// `weft_domain` types, which is what keeps the merge logic device-free and
/// unit-testable.
library;

// Encryption types live in a separate library from the main SDK barrel.
export 'package:matrix/encryption.dart'
    show Bootstrap, BootstrapState, KeyVerification, KeyVerificationState;
export 'package:matrix/matrix.dart' show LoginFlow;

export 'src/api_session.dart';
export 'src/bridge_discovery.dart';
export 'src/database.dart';
export 'src/homeserver.dart';
export 'src/link_preview.dart';
export 'src/mapping.dart';
export 'src/media.dart';
export 'src/matrix_timeline_source.dart';
export 'src/push_delivery.dart';
export 'src/push_rules.dart';
export 'src/pusher.dart';
export 'src/session.dart';
export 'src/upload.dart';
