/// Device sync: what a user set up on one device, on the others too.
///
/// Merge verdicts, per-chat preferences and settings travel as one document of
/// last-writer-wins entries. The document is sealed with a key every verified
/// device of the account already holds, so the homeserver that carries it sees
/// ciphertext and a size.
library;

export 'src/device_sync.dart';
export 'src/hlc.dart';
export 'src/sync_cipher.dart';
export 'src/sync_document.dart';
export 'src/sync_policy.dart';
export 'src/sync_reconciler.dart';
