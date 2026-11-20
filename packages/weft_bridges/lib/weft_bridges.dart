/// Bridge management: the mautrix bridgev2 provisioning API v3 client, the
/// bot-chat command client, and the declarative login flow both drive.
///
/// Weft hosts no bridges. The user runs their own, and this talks to them.
/// Login steps are rendered generically from what the bridge declares, so a
/// bridge adding a new field or a whole new flow works without a Weft release.
library;

export 'src/backend.dart';
export 'src/bot_channel.dart';
export 'src/command_client.dart';
export 'src/discovery.dart';
export 'src/login_session.dart';
export 'src/models.dart';
export 'src/provisioning_client.dart';
