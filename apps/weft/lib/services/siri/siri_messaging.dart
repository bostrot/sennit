import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_share/weft_share.dart';

import '../../data/chat_repository.dart';

/// The Dart end of SiriKit messaging on iOS: "Read my messages", "Reply",
/// "Send a message to …" and "Mark as read", on the phone and in CarPlay.
///
/// Siri resolves the intent in native code (`SiriIntents.swift`) and asks
/// over `com.bostrot.weft/siri` for the three things only the Matrix side
/// knows: which conversations a spoken name could mean, what is unread, and
/// — once the user has confirmed — to send or to mark read. Sending goes
/// through [ChatRepository.send] and reading through [ChatRepository.markRead],
/// the same calls the composer and the notification actions make, so a reply
/// dictated in the car is encrypted and routed exactly like a typed one, and
/// nothing reaches any server but the user's own homeserver.
///
/// What Siri reads aloud obeys the notification preview setting: with
/// previews off it says who wrote and "New message", never the text —
/// the same thing the lock screen would show.
class SiriMessaging {
  SiriMessaging({
    required ChatRepository repository,
    required List<Chat> Function() chats,
    required NotificationPolicy Function() policy,
    required WeftNotifyStrings Function() words,
    MethodChannel channel = const MethodChannel(kSiriChannelName),
  }) : _repository = repository,
       _chats = chats,
       _policy = policy,
       _words = words,
       _channel = channel;

  final ChatRepository _repository;
  final List<Chat> Function() _chats;
  final NotificationPolicy Function() _policy;
  final WeftNotifyStrings Function() _words;
  final MethodChannel _channel;

  /// Takes calls from the native side, then tells it Dart is listening: an
  /// intent that launched the app in the background is held natively until
  /// this arrives.
  Future<void> start() async {
    _channel.setMethodCallHandler(handle);
    try {
      await _channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // Not iOS, or a build without the channel. Nothing to serve.
    } on PlatformException catch (error) {
      debugPrint('weft: Siri channel did not start: $error');
    }
  }

  /// Siri's permission for Sennit: `authorized`, `denied`, `restricted` or
  /// `notDetermined`. Null where there is no Siri channel.
  Future<String?> authorizationStatus() => _ask('authorizationStatus');

  /// Asks for Siri, once. The system prompt only appears while the answer is
  /// still `notDetermined`; Sennit calls this after sign-in, never on first
  /// launch, so the prompt arrives when the user knows what it is for. Until
  /// the user allows it, iOS routes no messaging intent to the app, in the
  /// car or anywhere else.
  Future<String?> requestAuthorizationIfUndecided() async {
    if (await authorizationStatus() != 'notDetermined') return null;
    return _ask('requestAuthorization');
  }

  Future<String?> _ask(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('weft: Siri $method failed: $error');
      return null;
    }
  }

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments is Map
        ? (call.arguments as Map).cast<String, Object?>()
        : const <String, Object?>{};
    switch (call.method) {
      case 'recipients':
        return siriRecipientMatches(_chats(), args['query'] as String? ?? '');
      case 'unread':
        return siriUnreadMessages(_chats(), _policy(), _words());
      case 'send':
        final chatId = args['chatId'] as String? ?? '';
        final text = (args['text'] as String? ?? '').trim();
        if (chatId.isEmpty || text.isEmpty) return false;
        await _repository.send(chatId, text);
        // Answering is reading, as it is from a notification.
        unawaited(_markReadQuietly(chatId));
        return true;
      case 'markRead':
        final chatIds = (args['chatIds'] as List? ?? const [])
            .whereType<String>();
        for (final chatId in chatIds) {
          await _repository.markRead(chatId);
        }
        return true;
      default:
        throw MissingPluginException('weft: no Siri method ${call.method}');
    }
  }

  Future<void> _markReadQuietly(String chatId) async {
    try {
      await _repository.markRead(chatId);
    } on Object catch (error) {
      debugPrint('weft: $chatId was replied to by Siri but not read: $error');
    }
  }
}

const String kSiriChannelName = 'com.bostrot.weft/siri';

/// How many conversations Siri offers for one spoken name before it asks
/// the user to say more.
const int kSiriMaxRecipientMatches = kMaxRecipientMatches;

/// How many unread conversations "Read my messages" reads. Siri reads every
/// one it is given, and a long list is a long drive.
const int kSiriMaxUnreadChats = 10;

/// The conversations a spoken [query] could mean, best first, as Siri wants
/// them.
///
/// The matching is `rankMessageRecipients` in `weft_share`, which the Android
/// App Action resolves through too, so a name means the same conversation to
/// Siri, to Gemini and in either car. It leaves out archived chats and chat
/// requests nobody has accepted: replying to a request from the car would
/// accept it without the user ever seeing who it is from.
List<Map<String, Object?>> siriRecipientMatches(
  List<Chat> chats,
  String query,
) => [
  for (final chat in rankMessageRecipients(
    chats,
    query,
    max: kSiriMaxRecipientMatches,
  ))
    {'chatId': chat.id, 'title': chat.title, 'isGroup': chat.isGroup},
];

/// What "Read my messages" reads: the latest message of every unread,
/// unmuted conversation, newest first.
///
/// One message per conversation, with the count beside it, rather than every
/// unread line: Siri reads each item in full, and twelve messages from one
/// group is not what a driver asked for. The body goes through
/// [renderNotificationBody], so it is the notification's own wording — "Photo",
/// "Voice message" — and degrades to the hidden-preview text when the user
/// has turned previews off.
List<Map<String, Object?>> siriUnreadMessages(
  List<Chat> chats,
  NotificationPolicy policy,
  WeftNotifyStrings words,
) {
  final unread =
      [
        for (final chat in chats)
          if (chat.unreadCount > 0 &&
              !chat.muted &&
              !chat.archived &&
              chat.request == null &&
              chat.lastMessage != null &&
              !chat.lastMessage!.isOwn)
            chat,
      ]..sort(
        (a, b) => b.lastMessage!.timestamp.compareTo(a.lastMessage!.timestamp),
      );

  return [
    for (final chat in unread.take(kSiriMaxUnreadChats))
      {
        'id': chat.lastMessage!.eventId,
        'chatId': chat.id,
        'title': chat.title,
        'isGroup': chat.isGroup,
        'senderId': chat.lastMessage!.senderId,
        'senderName': disambiguatedSenderName(
          chat.lastMessage!,
          withNetwork: false,
          fallbackName: chat.isGroup ? null : chat.title,
        ),
        'text': renderNotificationBody(
          chat.lastMessage!,
          showPreview: policy.showPreviews,
          words: words,
        ),
        'timestamp': chat.lastMessage!.timestamp.millisecondsSinceEpoch,
        'unreadCount': chat.unreadCount,
      },
  ];
}
