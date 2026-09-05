/// The vocabulary a screen reader hears, shared by every surface that has to
/// build a label out of optional parts.
///
/// What is left here is *mechanics*, not vocabulary: joining clauses and
/// spelling a code out are the same in every language, so they belong to the
/// design system. The words themselves — what a delivery state or a message
/// kind is called — moved to the app, which is the only place that has
/// translations. See [WeftDesignStrings].
library;

/// Joins the parts of a merged semantics label into one sentence.
///
/// Null and blank parts are dropped rather than becoming ", , ". A label built
/// by interpolating optional fields is otherwise full of empty clauses, and a
/// screen reader announces every one of them as a real pause.
String semanticsSentence(List<String?> parts) => parts
    .where((part) => part != null && part.trim().isNotEmpty)
    .map((part) => part!.trim())
    .join(', ');

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
