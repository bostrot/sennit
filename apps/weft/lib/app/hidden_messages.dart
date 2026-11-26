import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import 'stores.dart';

/// The event ids of the messages the user hid for themselves.
///
/// Hiding is not deleting: nothing is sent to the room and nobody else's copy
/// changes. The rows are settings, so device sync carries them to the user's
/// other devices and the message stays out of sight there too.
final hiddenMessagesProvider = Provider<Set<String>>((ref) {
  ref.watch(settingsRevisionProvider);
  final settings = storesOrNull(ref)?.settings;
  if (settings == null) return const {};
  const prefix = WeftSettings.hiddenMessagePrefix;
  return {
    for (final key in settings.all().keys)
      if (key.startsWith(prefix)) key.substring(prefix.length),
  };
});

/// Whether the "Message deleted" placeholders are left out of conversations.
final hideDeletedMessagesProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  return storesOrNull(
        ref,
      )?.settings.getBool(WeftSettings.hideDeletedMessages) ??
      false;
});

/// Hides [message] on this account's devices, or shows it again.
void setMessageHidden(
  SettingsStore settings,
  WeftMessage message, {
  required bool hidden,
}) {
  final key = WeftSettings.hiddenMessagePrefix + message.eventId;
  if (hidden) {
    settings.setString(key, message.roomId);
  } else {
    settings.remove(key);
  }
}

/// [messages] without what the user asked not to see: the messages they hid,
/// and — with [hideDeleted] — the placeholders deleted messages leave.
List<WeftMessage> withoutHidden(
  List<WeftMessage> messages, {
  required Set<String> hidden,
  required bool hideDeleted,
}) {
  if (hidden.isEmpty && !hideDeleted) return messages;
  bool shown(WeftMessage m) =>
      !hidden.contains(m.eventId) && !(hideDeleted && m.redacted);
  if (messages.every(shown)) return messages;
  return messages.where(shown).toList(growable: false);
}
