import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import 'stores.dart';

/// A message the user saved to come back to.
///
/// A snapshot rather than a pointer: the list of saved messages is read
/// without any room's history loaded, on a device that may never have
/// fetched that far back, so it keeps what it shows — the words, who said
/// them and when — and the ids to open the conversation at the message.
class SavedMessage {
  const SavedMessage({
    required this.eventId,
    required this.chatId,
    required this.roomId,
    required this.senderName,
    required this.text,
    required this.sentAt,
    required this.savedAt,
  });

  /// The snapshot of [message], seen in the conversation [chatId].
  factory SavedMessage.of(
    WeftMessage message, {
    required String chatId,
    required String text,
    DateTime? now,
  }) => SavedMessage(
    eventId: message.eventId,
    chatId: chatId,
    roomId: message.roomId,
    senderName: message.senderName,
    text: text,
    sentAt: message.timestamp,
    savedAt: now ?? DateTime.now(),
  );

  final String eventId;

  /// The conversation it was saved from, which is what opens: a merged chat's
  /// id when it was saved in one, else the room's.
  final String chatId;
  final String roomId;
  final String senderName;

  /// The words of the message, or what stands for them — a file's name, a
  /// voice message's transcript.
  final String text;
  final DateTime sentAt;
  final DateTime savedAt;

  String encode() => jsonEncode({
    'chat': chatId,
    'room': roomId,
    'sender': senderName,
    'text': text,
    'sent': sentAt.millisecondsSinceEpoch,
    'saved': savedAt.millisecondsSinceEpoch,
  });

  /// The row [value] for [eventId], or null when it is not one this version
  /// can read — a row from a newer device is skipped, not a crash.
  static SavedMessage? decode(String eventId, String value) {
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, Object?>) return null;
      final room = json['room'];
      final sent = json['sent'];
      final saved = json['saved'];
      if (room is! String || sent is! int || saved is! int) return null;
      final chat = json['chat'];
      final sender = json['sender'];
      final text = json['text'];
      return SavedMessage(
        eventId: eventId,
        chatId: chat is String && chat.isNotEmpty ? chat : room,
        roomId: room,
        senderName: sender is String ? sender : '',
        text: text is String ? text : '',
        sentAt: DateTime.fromMillisecondsSinceEpoch(sent),
        savedAt: DateTime.fromMillisecondsSinceEpoch(saved),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Every saved message, the most recently saved first.
///
/// The rows are settings, so device sync carries them to the user's other
/// devices, sealed like everything else it carries.
final savedMessagesProvider = Provider<List<SavedMessage>>((ref) {
  ref.watch(settingsRevisionProvider);
  final settings = storesOrNull(ref)?.settings;
  if (settings == null) return const [];
  return readSavedMessages(settings);
});

/// The saved messages in [settings], the most recently saved first.
List<SavedMessage> readSavedMessages(SettingsStore settings) {
  const prefix = WeftSettings.savedMessagePrefix;
  return [
    for (final MapEntry(:key, :value) in settings.all().entries)
      if (key.startsWith(prefix))
        ?SavedMessage.decode(key.substring(prefix.length), value),
  ]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
}

/// The event ids of the saved messages, for marking them in a conversation.
final savedMessageIdsProvider = Provider<Set<String>>(
  (ref) => {
    for (final saved in ref.watch(savedMessagesProvider)) saved.eventId,
  },
);

/// Saves [saved], or forgets the message with its event id.
void setMessageSaved(
  SettingsStore settings,
  SavedMessage saved, {
  required bool isSaved,
}) {
  final key = WeftSettings.savedMessagePrefix + saved.eventId;
  if (isSaved) {
    settings.setString(key, saved.encode());
  } else {
    settings.remove(key);
  }
}

/// [saved] narrowed to the messages in [rooms], when given, and to the ones
/// whose words or sender contain every word of [query].
///
/// By room rather than by chat id: a conversation merged after a message was
/// saved in one of its rooms still lists it.
List<SavedMessage> filterSavedMessages(
  List<SavedMessage> saved, {
  Set<String>? rooms,
  String query = '',
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  return [
    for (final message in saved)
      if ((rooms == null || rooms.contains(message.roomId)) &&
          words.every(
            (w) =>
                message.text.toLowerCase().contains(w) ||
                message.senderName.toLowerCase().contains(w),
          ))
        message,
  ];
}
