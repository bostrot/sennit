/// The auto-reply decision layer: whether a message deserves a machine-written
/// answer, which of the user's rules writes it, and the guards that stop two
/// auto-responders talking to each other for ever.
///
/// Pure Dart, and pointedly so. Nothing here calls a language model, sends a
/// message, or knows what a read receipt is. What it holds is the part that is
/// hard to get right and easy to test: audience matching across merged
/// conversations, precedence between overlapping rules, schedule windows that
/// wrap past midnight in a timezone that is not the test runner's, and the four
/// refusals that must hold whatever the user configured — no reply to a
/// stranger's chat request, none to the user's own words, none to another
/// machine's reply, and never more than [kAutoReplyMaxPerConversation] in
/// [kAutoReplyCapWindow].
///
/// The half that is *not* here is the half that needs a running app: calling
/// the user's own endpoint, and sending the answer without marking the
/// conversation read. Both live in `apps/weft/lib/services/ai/`, on top of the
/// decisions this package produces. Nothing in `lib/` may import Flutter or
/// touch I/O.
library;

// Consumers import this barrel, never src/.
export 'src/engine.dart';
export 'src/rule.dart';
