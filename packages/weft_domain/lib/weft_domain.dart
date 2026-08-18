/// Shared vocabulary for every Weft layer.
///
/// Pure Dart on purpose: no Flutter, no I/O, no storage. Anything in here can
/// be constructed in a unit test without a device or a homeserver.
library;

export 'src/chat.dart';
export 'src/contact.dart';
export 'src/handle.dart';
export 'src/link.dart';
export 'src/message.dart';
export 'src/network.dart';
export 'src/relations.dart';
