import 'package:meta/meta.dart';
import 'package:weft_domain/weft_domain.dart';

/// How many conversations a spoken name is matched to before the caller has
/// to ask the user to say more.
const int kMaxRecipientMatches = 5;

/// Whether [chat] may be named by a voice assistant at all, as a recipient or
/// as a published conversation shortcut.
///
/// Archived chats are out because the user put them away. A chat request that
/// is still waiting, or was declined, is out for a stronger reason: answering
/// it from the car or from "Hey Google" would accept it without the user ever
/// seeing who it is from, and publishing it hands a stranger's name to the
/// launcher and the assistant before the user has said yes to them.
bool isVoiceAddressable(Chat chat) =>
    !chat.archived &&
    chat.request != ChatRequestState.pending &&
    chat.request != ChatRequestState.declined;

/// The conversations a spoken [query] could mean, best first.
///
/// Matched on the chat title, which for a DM is the person — already resolved
/// through the address book and the merge fold, so "Anna" finds the one merged
/// Anna rather than her WhatsApp and her Signal separately. An exact title
/// outranks a word that starts with the query, which outranks the query
/// appearing anywhere. Ties keep the order of [chats], which is the inbox's.
///
/// One list for every assistant: Siri asks for it to offer a choice, and the
/// Android App Action resolves through [resolveMessageRecipient], so "Anna"
/// cannot mean one person in the car and another on the phone.
List<Chat> rankMessageRecipients(
  List<Chat> chats,
  String query, {
  int max = kMaxRecipientMatches,
}) {
  final wanted = _fold(query);
  if (wanted.isEmpty) return const [];

  final ranked = <(int, int, Chat)>[];
  for (var i = 0; i < chats.length; i++) {
    final chat = chats[i];
    if (!isVoiceAddressable(chat)) continue;
    final rank = _rank(_fold(chat.title), wanted);
    if (rank != null) ranked.add((rank, i, chat));
  }
  ranked.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
  });
  return [for (final (_, _, chat) in ranked.take(max)) chat];
}

/// Which single conversation [query] names, if it names exactly one.
///
/// Stricter than [rankMessageRecipients], because the caller has no way to ask
/// back: an App Action hands Sennit a name and some text and is gone. So a
/// conversation is chosen only when nothing else is a plausible reading — the
/// one exact title, or the one match of any kind. "Alex" with an "Alex" and an
/// "Alexandra" in the inbox is Alex; "Al" with both is the user's call.
RecipientResolution resolveMessageRecipient(List<Chat> chats, String query) {
  final wanted = _fold(query);
  if (wanted.isEmpty) return const RecipientNotFound();

  final matches = rankMessageRecipients(chats, query, max: chats.length);
  if (matches.isEmpty) return const RecipientNotFound();

  final exact = [
    for (final chat in matches)
      if (_fold(chat.title) == wanted) chat,
  ];
  if (exact.length == 1) return RecipientResolved(exact.single);
  if (exact.isEmpty && matches.length == 1) {
    return RecipientResolved(matches.single);
  }
  final candidates = exact.isNotEmpty ? exact : matches;
  return RecipientAmbiguous(candidates.take(kMaxRecipientMatches).toList());
}

/// What [resolveMessageRecipient] made of a name.
@immutable
sealed class RecipientResolution {
  const RecipientResolution();
}

/// The name means this conversation and no other.
class RecipientResolved extends RecipientResolution {
  const RecipientResolved(this.chat);

  final Chat chat;
}

/// The name could mean any of [candidates], best first.
class RecipientAmbiguous extends RecipientResolution {
  const RecipientAmbiguous(this.candidates);

  final List<Chat> candidates;
}

/// No conversation goes by that name.
class RecipientNotFound extends RecipientResolution {
  const RecipientNotFound();
}

int? _rank(String title, String wanted) {
  if (title.isEmpty) return null;
  if (title == wanted) return 0;
  if (title.split(_whitespace).any((word) => word.startsWith(wanted))) {
    return 1;
  }
  if (title.contains(wanted)) return 2;
  return null;
}

/// Lower case with runs of whitespace collapsed: a recogniser that hears
/// "anna  maria" means the chat titled "Anna Maria".
String _fold(String value) =>
    value.trim().toLowerCase().replaceAll(_whitespace, ' ');

final RegExp _whitespace = RegExp(r'\s+');
