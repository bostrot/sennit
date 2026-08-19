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

/// A code said one character at a time, in groups.
///
/// Weft shows the user two strings they have to reproduce exactly and can never
/// see again: an MCP API key, and the recovery key that is the only way back
/// into their message history. Both are drawn as one monospace run, which a
/// screen reader announces as a single unpronounceable word — so the one screen
/// whose entire purpose is "write this down" is the one screen a blind user
/// cannot use.
///
/// Spaces between characters is what makes an engine spell rather than
/// pronounce. [groupSize] then inserts a comma every few characters, which is
/// what turns forty-eight spoken letters into something a person can actually
/// keep up with — and gives them somewhere to resume from when they lose their
/// place. Whitespace already in [code] is dropped rather than spelled: the
/// recovery key arrives pre-grouped, and "space" read aloud twelve times is
/// twelve chances to write one down.
String spelledOut(String code, {int groupSize = 4}) {
  final characters = code.replaceAll(RegExp(r'\s+'), '').split('');
  if (characters.isEmpty) return '';
  final groups = <String>[];
  for (var i = 0; i < characters.length; i += groupSize) {
    groups.add(characters.skip(i).take(groupSize).join(' '));
  }
  return groups.join(', ');
}

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
