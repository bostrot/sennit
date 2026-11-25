import 'package:collection/collection.dart' show MapEquality;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';

import 'stores.dart';

/// Names and pictures the user gave conversations for themselves.
///
/// Kept per room rather than per chat: a merged contact's chat id is made on
/// each device from that device's merges, but its rooms are the same rooms
/// everywhere. Giving a merged chat a nickname writes it under every room it
/// has, and reading takes the first room that has one — so the name follows
/// the person across devices, and survives an unmerge on both halves.
///
/// Stored as settings under `inbox.`, which device sync already carries, so a
/// nickname set on the phone shows on the laptop. Nothing here is ever sent to
/// the conversation itself: the other side keeps the name they chose.
@immutable
class ChatNicknames {
  const ChatNicknames({this.names = const {}, this.photos = const {}});

  /// Settings key prefix for a room's nickname.
  static const String namePrefix = 'inbox.nickname.';

  /// Settings key prefix for a room's picture, a small `data:` image.
  static const String photoPrefix = 'inbox.nickphoto.';

  /// Reads both maps out of the settings table's rows.
  factory ChatNicknames.fromSettings(Map<String, String> settings) {
    final names = <String, String>{};
    final photos = <String, String>{};
    for (final MapEntry(:key, :value) in settings.entries) {
      if (value.isEmpty) continue;
      if (key.startsWith(namePrefix)) {
        names[key.substring(namePrefix.length)] = value;
      } else if (key.startsWith(photoPrefix)) {
        photos[key.substring(photoPrefix.length)] = value;
      }
    }
    return ChatNicknames(names: names, photos: photos);
  }

  /// Nickname by room id.
  final Map<String, String> names;

  /// Picture (`data:` uri) by room id.
  final Map<String, String> photos;

  bool get isEmpty => names.isEmpty && photos.isEmpty;

  String? nameFor(Chat chat) => _first(names, chat);

  String? photoFor(Chat chat) => _first(photos, chat);

  static String? _first(Map<String, String> map, Chat chat) {
    if (map.isEmpty) return null;
    for (final room in [chat.id, ...chat.roomIds]) {
      final value = map[room];
      if (value != null) return value;
    }
    return null;
  }

  /// [chat] as the user calls it.
  Chat apply(Chat chat) {
    final name = nameFor(chat);
    final photo = photoFor(chat);
    if (name == null && photo == null) return chat;
    return chat.copyWith(title: name, avatarUrl: photo);
  }

  List<Chat> applyTo(List<Chat> chats) =>
      isEmpty ? chats : [for (final chat in chats) apply(chat)];

  @override
  bool operator ==(Object other) =>
      other is ChatNicknames &&
      const MapEquality<String, String>().equals(other.names, names) &&
      const MapEquality<String, String>().equals(other.photos, photos);

  @override
  int get hashCode => Object.hash(
    const MapEquality<String, String>().hash(names),
    const MapEquality<String, String>().hash(photos),
  );
}

/// The user's private nicknames and pictures, re-read when settings change —
/// including when device sync brings one in from another device.
final chatNicknamesProvider = Provider<ChatNicknames>((ref) {
  ref.watch(settingsRevisionProvider);
  try {
    return ChatNicknames.fromSettings(ref.read(storesProvider).settings.all());
  } on Object {
    // Stores not bootstrapped: a widget test, or a launch still starting.
    return const ChatNicknames();
  }
});

/// Gives [chat] the private nickname [name], or takes it away when [name] is
/// null or blank. Written under every room the chat has; see [ChatNicknames].
void setChatNickname(WidgetRef ref, Chat chat, String? name) =>
    _write(ref, chat, ChatNicknames.namePrefix, name?.trim());

/// Gives [chat] the private picture [photo] (a `data:` uri), or takes it away.
void setChatNicknamePhoto(WidgetRef ref, Chat chat, String? photo) =>
    _write(ref, chat, ChatNicknames.photoPrefix, photo);

void _write(WidgetRef ref, Chat chat, String prefix, String? value) {
  final settings = ref.read(storesProvider).settings;
  for (final room in {chat.id, ...chat.roomIds}) {
    if (value == null || value.isEmpty) {
      settings.remove('$prefix$room');
    } else {
      settings.setString('$prefix$room', value);
    }
  }
  ref.read(settingsRevisionProvider.notifier).bump();
}
