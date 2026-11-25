import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_domain/weft_domain.dart';

import 'notification_channels.dart';
import 'notification_presentation.dart';
import 'push_registration.dart';

/// Whether this platform lets the user pick a sound for one chat.
///
/// Android only: there a conversation's notifications can carry a sound of
/// their own, chosen in the system's settings. iOS gives an app one sound for
/// everything, and the desktops play whatever the system plays.
bool get canChooseChatSound => NotificationPlatform.isAndroid;

/// Opens Android's notification settings for [chat], where its sound is
/// picked. False when there is no such screen to open.
///
/// The conversation hangs off the channel of the network it is sent on, and
/// the launcher shortcut its notifications are posted with — the same two ids
/// `notification_presentation.dart` posts with, or Android opens a page for a
/// conversation that never notifies.
Future<bool> openChatSoundSettings(
  Chat chat, {
  @visibleForTesting
  MethodChannel channel = const MethodChannel('com.bostrot.weft/intents'),
}) async {
  if (!canChooseChatSound) return false;
  final network = chat.sendNetwork ?? chat.networks.firstOrNull;
  if (network == null) return false;
  try {
    final opened = await channel
        .invokeMethod<bool>('openConversationNotificationSettings', {
          'channelId': messageChannelFor(network).id,
          'shortcutId': chatShortcutId(chat.id),
        });
    return opened ?? false;
  } on PlatformException catch (error) {
    debugPrint('weft: sound settings for ${chat.id} did not open: $error');
    return false;
  } on MissingPluginException {
    return false;
  }
}
