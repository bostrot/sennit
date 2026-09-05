/// The words a notification body is made of, supplied by the app.
///
/// Same rule as `weft_design`'s [WeftDesignStrings], and here for the same
/// reason: this package renders the text a lock screen shows, it has no ARB
/// files, and pointing it at the app's `AppL10n` would make a library depend on
/// the app. So the words come in as a parameter.
///
/// [WeftNotifyStrings.english] is a real fallback, not a placeholder — a caller
/// that passes nothing gets readable English, which is what the package's own
/// tests want and what a device in an undeclared locale would have got anyway.
///
/// See `docs/architecture/l10n-pipeline.md`, "Packages and their words".
library;

import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// Every word `weft_notify` puts in front of a reader.
@immutable
class WeftNotifyStrings {
  const WeftNotifyStrings({
    required this.hiddenPreview,
    required this.messageKind,
  });

  /// What a notification says instead of the message when previews are off.
  /// The sender and the chat are still shown; this replaces only the words.
  final String hiddenPreview;

  /// What a message *is*, for a body with nothing else to say — "Photo",
  /// "Voice message". No emoji: a notification body is read aloud, and
  /// "camera Photo IMG_4021.jpg" is not an improvement.
  final String Function(MessageKind kind) messageKind;

  static const WeftNotifyStrings english = WeftNotifyStrings(
    hiddenPreview: 'New message',
    messageKind: _englishKind,
  );
}

String _englishKind(MessageKind kind) => switch (kind) {
  MessageKind.image => 'Photo',
  MessageKind.video => 'Video',
  MessageKind.voice => 'Voice message',
  MessageKind.audio => 'Audio',
  MessageKind.file => 'File',
  MessageKind.sticker => 'Sticker',
  MessageKind.location => 'Location',
  MessageKind.poll => 'Poll',
  MessageKind.event => 'Event',
  MessageKind.text => 'Message',
};
