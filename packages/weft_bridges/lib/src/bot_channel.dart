import 'package:meta/meta.dart';

/// The chat with a bridge bot, as much of it as [BridgeCommandClient] needs.
///
/// An interface so this package stays free of the Matrix SDK: the app supplies
/// one backed by a real room, and the tests supply one that replays what a
/// bridge bot actually says.
abstract interface class BridgeBotChannel {
  /// Whether a chat with the bot exists already.
  ///
  /// Asked before anything that would create one: looking at a bridge's status
  /// must not open a new chat in the inbox of someone who never used it.
  Future<bool> exists();

  /// Finds or creates the chat. Idempotent.
  Future<void> open();

  /// Sends [text] as a plain message from the user.
  Future<void> send(String text);

  /// The bot's messages from the moment this is first listened to — never
  /// history. A reply from yesterday's attempt must not be read as the answer
  /// to today's command.
  Stream<BotMessage> get messages;

  Future<void> close();
}

/// One thing the bot said or did.
@immutable
class BotMessage {
  const BotMessage({
    required this.eventId,
    this.body = '',
    this.formattedBody,
    this.isImage = false,
    this.replaces,
    this.redacts,
  });

  final String eventId;

  /// The plain body. For an edit, the *new* content's body — what the
  /// message now says, not the `* ` fallback.
  final String body;

  final String? formattedBody;

  /// An `m.image`. A bridge bot sends its QR codes as images whose body is
  /// the QR payload itself.
  final bool isImage;

  /// The message this one edits, when it is an edit — a refreshed QR code.
  final String? replaces;

  /// The message this one removes, when it is a redaction — a QR code the bot
  /// takes down once it was scanned or expired.
  final String? redacts;

  bool get isRedaction => redacts != null;

  @override
  String toString() =>
      'BotMessage($eventId${isImage ? ', image' : ''}'
      '${replaces != null ? ', edits $replaces' : ''}'
      '${redacts != null ? ', redacts $redacts' : ''}: $body)';
}
