/// The vocabulary a screen reader hears, shared by every surface that has to
/// build a label out of optional parts.
///
/// It lives in the design system for the same reason the colour tokens do: an
/// inbox row and a message bubble describe the *same* delivery state, and two
/// call sites inventing their own wording is how "Delivered" in one place
/// becomes "Sent to their phone" in another.
library;

import 'package:weft_domain/weft_domain.dart';

/// Joins the parts of a merged semantics label into one sentence.
///
/// Null and blank parts are dropped rather than becoming ", , ". A label built
/// by interpolating optional fields is otherwise full of empty clauses, and a
/// screen reader announces every one of them as a real pause.
String semanticsSentence(List<String?> parts) => parts
    .where((part) => part != null && part.trim().isNotEmpty)
    .map((part) => part!.trim())
    .join(', ');

/// A message's delivery state in words.
///
/// Read and delivered are drawn with the same double tick and differ only in
/// colour — the one distinction a colour-blind reader cannot make and a screen
/// reader cannot see at all. Naming them is what makes the state exist for
/// both. Returns an empty string for a state with nothing worth saying, which
/// [semanticsSentence] then drops.
String deliveryStateLabel(DeliveryState? state) => switch (state) {
  DeliveryState.sending => 'Sending',
  DeliveryState.sent => 'Sent',
  DeliveryState.delivered => 'Delivered',
  DeliveryState.read => 'Read',
  DeliveryState.failed => 'Not sent',
  null => '',
};

/// What a message *is*, for a reader who cannot see the bubble.
///
/// The preview text answers "what does it say"; this answers "what kind of
/// thing is it", which for a photo or a file is the only thing there is to say.
String messageKindLabel(MessageKind kind) => switch (kind) {
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
