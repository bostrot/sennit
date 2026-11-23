import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart' show IdentityGraph, MergedTimeline;
import 'package:weft_store/weft_store.dart';

import '../services/ai/auto_reply_service.dart' show AutoReplyEndpoint;
import '../services/ai/event_title.dart' show recentConversationTranscript;
import '../services/ai/llm_budget.dart' show AiFeature;
import '../services/ai/person_memory.dart';
import 'providers.dart';
import 'stores.dart';

/// The three switches of personal memory, read out of the settings store.
///
/// Every one of them off unless set — see [WeftSettings.personMemoryInAi] —
/// and every one read per use rather than captured, so turning the memory
/// off affects the next reply chip and not the next launch.
@immutable
class PersonMemorySettings {
  const PersonMemorySettings({
    this.useInAi = false,
    this.suggestFacts = false,
    this.encryptedChats = false,
  });

  factory PersonMemorySettings.fromStore(SettingsStore settings) =>
      PersonMemorySettings(
        useInAi: settings.getBool(WeftSettings.personMemoryInAi),
        suggestFacts: settings.getBool(WeftSettings.personMemorySuggest),
        encryptedChats: settings.getBool(
          WeftSettings.personMemoryEncryptedChats,
        ),
      );

  /// The master switch: whether a note is ever sent to the model, with
  /// anything. Off means no note in any prompt and no facts proposed.
  final bool useInAi;

  /// Whether facts are proposed on their own after a quick message, on top of
  /// the "Learn from chat" button that always proposes when asked.
  final bool suggestFacts;

  /// Whether an end-to-end encrypted conversation may be sent to learn from.
  final bool encryptedChats;

  /// Whether a conversation may be sent to propose facts from, given whether
  /// any of it is [encrypted].
  bool mayLearnFrom({required bool encrypted}) =>
      useInAi && (!encrypted || encryptedChats);

  void writeTo(SettingsStore settings) {
    settings.setBool(WeftSettings.personMemoryInAi, value: useInAi);
    settings.setBool(WeftSettings.personMemorySuggest, value: suggestFacts);
    settings.setBool(
      WeftSettings.personMemoryEncryptedChats,
      value: encryptedChats,
    );
  }

  PersonMemorySettings copyWith({
    bool? useInAi,
    bool? suggestFacts,
    bool? encryptedChats,
  }) => PersonMemorySettings(
    useInAi: useInAi ?? this.useInAi,
    suggestFacts: suggestFacts ?? this.suggestFacts,
    encryptedChats: encryptedChats ?? this.encryptedChats,
  );
}

final personMemorySettingsProvider = Provider<PersonMemorySettings>((ref) {
  ref.watch(settingsRevisionProvider);
  try {
    return PersonMemorySettings.fromStore(ref.read(storesProvider).settings);
  } on Object {
    // Stores not bootstrapped: everything off, the direction a gate fails in.
    return const PersonMemorySettings();
  }
});

/// Writes [settings] and tells every reader.
void savePersonMemorySettings(WidgetRef ref, PersonMemorySettings settings) {
  settings.writeTo(ref.read(storesProvider).settings);
  ref.read(settingsRevisionProvider.notifier).bump();
}

/// Every note, waiting fact and dismissal, as the keychain holds them.
///
/// Published first and written second, unlike the settings-table notifiers:
/// the keychain is a channel call, and the editor should not wait on it to
/// show what was typed. A write that fails leaves this run's state ahead of
/// the disk, which the next save catches up.
class PersonMemoryNotifier extends Notifier<MemoryBook> {
  @override
  MemoryBook build() {
    try {
      return MemoryBook.decode(ref.read(storesProvider).personMemory);
    } on Object {
      return MemoryBook.empty;
    }
  }

  void _publish(MemoryBook next) {
    state = next;
    try {
      final stores = ref.read(storesProvider);
      unawaited(
        stores.setPersonMemory(next.isEmpty ? null : next.encode()).catchError((
          Object error,
        ) {
          // The type only: the message of a keychain error can quote what
          // it was asked to store.
          debugPrint('weft: person memory: not saved: ${error.runtimeType}');
        }),
      );
    } on Object {
      // No stores — a widget test pumping a screen directly. In memory only.
    }
  }

  /// The current book, for a caller holding the notifier across an await.
  MemoryBook get book => state;

  void saveNote(List<String> keys, String note) =>
      _publish(state.withNote(keys, note));

  void propose(List<String> keys, List<String> facts) =>
      _publish(state.withProposals(keys, facts));

  void accept(List<String> keys, String fact) =>
      _publish(state.accept(keys, fact));

  void promote(List<String> chatKeys, List<String> personKeys, String fact) =>
      _publish(state.promote(chatKeys, personKeys, fact));

  void dismiss(List<String> keys, String fact) =>
      _publish(state.dismiss(keys, fact));

  void forget(List<String> keys) => _publish(state.forget(keys));

  void forgetAll() => _publish(MemoryBook.empty);

  /// Notes from a restored archive: under the keys that have none here, or,
  /// for a restore that [replace]s, instead of everything — the same two
  /// rules the archive's tables are restored by.
  void restore(MemoryBook archived, {bool replace = false}) =>
      _publish(replace ? archived : state.mergedWith(archived));
}

final personMemoryProvider = NotifierProvider<PersonMemoryNotifier, MemoryBook>(
  PersonMemoryNotifier.new,
);

/// The keys the person [chat] is with is filed under — see
/// [personMemoryKeys]. Empty for a group.
List<String> personMemoryKeysFor(IdentityGraph graph, Chat chat) {
  if (chat.isGroup) return const [];
  return personMemoryKeys(
    chat: chat,
    handles: chat.contactId == null
        ? const []
        : graph.handlesInContact(chat.contactId!),
  );
}

/// How many people of a group have their memory considered for one prompt.
const int kAiMemoryPeople = 8;

/// The people of [chat] whose memory a prompt may carry, most relevant first.
///
/// A direct chat has one: the person it is with, under the chat's title. A
/// group has whoever wrote in [recent], the latest speaker first — the one a
/// reply is most likely for — and at most [kAiMemoryPeople] of them. The user's
/// own messages and bridge notices are nobody.
List<MemoryPerson> memoryPeopleFor(
  IdentityGraph graph,
  Chat chat,
  Iterable<WeftMessage> recent,
) {
  if (!chat.isGroup) {
    final keys = personMemoryKeysFor(graph, chat);
    return keys.isEmpty ? const [] : [(name: chat.title, keys: keys)];
  }
  List<NetworkHandle> handlesOf(String matrixUserId) {
    final contact = graph.contactIdForUser(matrixUserId);
    return contact == null ? const [] : graph.handlesInContact(contact);
  }

  final seen = <String>{};
  final people = <MemoryPerson>[];
  final newestFirst = recent.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  for (final m in newestFirst) {
    if (m.isOwn || m.isBridgeNotice || !seen.add(m.senderId)) continue;
    people.add((
      name: m.senderName,
      keys: personKeysForSender(m.senderId, handlesOf),
    ));
    if (people.length >= kAiMemoryPeople) break;
  }
  return people;
}

/// What the prompts for [chat] are told, from [book]: the chat's note and the
/// notes of [people]. Null when there is none of either.
AiMemory? aiMemoryFrom(MemoryBook book, Chat chat, List<MemoryPerson> people) {
  final memory = AiMemory(
    chat: book.noteFor(chatMemoryKeys(chat)),
    people: [
      for (final person in people)
        if (book.noteFor(person.keys) case final note when note.isNotEmpty)
          (name: person.name, note: note),
    ],
  );
  return memory.isEmpty ? null : memory;
}

/// What to send with a prompt written for [chat], given the [recent]
/// messages the prompt is written from, or null.
///
/// The one gate every AI feature goes through: null while the master switch
/// is off, and null when nothing is noted. Untrimmed — the composers trim to
/// their endpoint's budget, in `memoryPromptBlock`.
final aiMemoryForPromptProvider =
    Provider<AiMemory? Function(Chat chat, Iterable<WeftMessage> recent)>((
      ref,
    ) {
      return (chat, recent) {
        if (!ref.read(personMemorySettingsProvider).useInAi) return null;
        final graph = ref.read(chatRepositoryProvider).identityGraph;
        return aiMemoryFrom(
          ref.read(personMemoryProvider),
          chat,
          memoryPeopleFor(graph, chat, recent),
        );
      };
    });

/// How asking the model about a conversation ended.
enum PersonFactsOutcome {
  /// New facts are waiting for the user; how many is [PersonFactsResult.added].
  proposed,

  /// The model answered, with nothing that is not already noted or waiting.
  nothingNew,

  /// The memory switch is off. Nothing was sent.
  memoryOff,

  /// The conversation is end-to-end encrypted and learning from encrypted
  /// chats is off. Nothing was sent.
  encrypted,

  /// No endpoint, or no Pro. Nothing was sent.
  noEndpoint,

  /// A conversation with nothing to learn from. Nothing was sent.
  nothingToSend,

  /// The request failed: the server could not be reached, or answered with an
  /// error status, which is [PersonFactsResult.status].
  failed,

  /// The model did not answer in the time it is given.
  timedOut,

  /// The model used its whole budget before it wrote an answer.
  cutOff,

  /// The model answered, but with no list of facts in it.
  unreadable,
}

typedef PersonFactsResult = ({
  PersonFactsOutcome outcome,
  int added,

  /// The HTTP status a [PersonFactsOutcome.failed] request was answered with.
  int? status,
});

/// [timeline]'s messages, paged back until there are [wanted] of them, the
/// history runs out, or [patience] is up — whichever comes first.
///
/// The time cap is for a chat on a slow homeserver: "Learn from chat" should
/// read what it could fetch in a few seconds rather than keep the user
/// waiting for the five-hundredth message.
Future<List<WeftMessage>> loadHistoryForAi(
  MergedTimeline timeline,
  int wanted, {
  Duration patience = const Duration(seconds: 10),
}) async {
  final stop = DateTime.now().add(patience);
  var messages = timeline.view().messages;
  while (messages.length < wanted &&
      timeline.hasMoreHistory &&
      DateTime.now().isBefore(stop)) {
    final bool added;
    try {
      added = await timeline
          .loadMore(count: (wanted - messages.length).clamp(30, 100))
          .timeout(stop.difference(DateTime.now()));
    } on Object catch (error) {
      debugPrint('weft: learn facts: history stopped: ${error.runtimeType}');
      break;
    }
    if (!added) break;
    messages = timeline.view().messages;
  }
  return messages;
}

/// Asks the model what is worth remembering from [chat]'s [messages], and
/// files the answer as facts waiting for the user under the chat's memory.
///
/// Never writes a note: [PersonMemoryNotifier.propose] only adds to what is
/// offered, and the user decides whether a fact goes into the chat's memory or
/// a person's. Every gate is checked here, before anything is sent, so the two
/// ways in — the "Learn from chat" button and the pass after a quick message —
/// cannot disagree about what may leave the device: the master switch, the
/// encrypted-chat switch, and the endpoint (which is also the Pro gate). How
/// much of the conversation goes is the model's: its window's share for
/// learning (see `LlmBudget`), up to hundreds of messages on a big one.
Future<PersonFactsResult> learnPersonFacts({
  required PersonMemorySettings settings,
  required AutoReplyEndpoint? endpoint,
  required PersonMemoryNotifier memory,
  required Chat chat,
  required List<MemoryPerson> people,
  required Iterable<WeftMessage> messages,
  http.Client? client,
  Future<void>? cancel,
}) async {
  PersonFactsResult done(
    PersonFactsOutcome outcome, {
    int added = 0,
    int? status,
  }) => (outcome: outcome, added: added, status: status);
  if (!settings.useInAi) return done(PersonFactsOutcome.memoryOff);
  final keys = chatMemoryKeys(chat);
  if (keys.isEmpty) return done(PersonFactsOutcome.nothingToSend);
  final recent = messages.toList();
  if (!settings.mayLearnFrom(encrypted: recent.any((m) => m.encrypted))) {
    return done(PersonFactsOutcome.encrypted);
  }
  if (endpoint == null) return done(PersonFactsOutcome.noEndpoint);
  final room = endpoint.budget.forFeature(AiFeature.learnFacts);
  final transcript = recentConversationTranscript(
    recent,
    maxMessages: room.maxMessages,
    maxChars: room.transcriptChars,
  );
  if (transcript.isEmpty) {
    debugPrint(
      'weft: learn facts: ${recent.length} messages loaded, none in words',
    );
    return done(PersonFactsOutcome.nothingToSend);
  }

  Object? failure;
  final before = memory.book.suggestionsFor(keys).length;
  final facts = await suggestPersonFacts(
    baseUrl: endpoint.baseUrl,
    model: endpoint.model,
    apiKey: endpoint.apiKey,
    transcript: transcript,
    chatTitle: chat.title,
    isGroup: chat.isGroup,
    known: aiMemoryFrom(memory.book, chat, people),
    budget: endpoint.budget,
    client: client,
    cancel: cancel,
    onError: (error) => failure = error,
  );
  if (failure != null) {
    debugPrint(
      'weft: learn facts: ${recent.length} messages loaded, '
      '${transcript.length} sent, failed: '
      '${failure is PersonFactsFailure ? failure : failure.runtimeType}',
    );
    return switch (failure) {
      PersonFactsFailure(error: PersonFactsError.cutOff) => done(
        PersonFactsOutcome.cutOff,
      ),
      PersonFactsFailure(error: PersonFactsError.unreadable) => done(
        PersonFactsOutcome.unreadable,
      ),
      PersonFactsFailure(:final status) => done(
        PersonFactsOutcome.failed,
        status: status,
      ),
      TimeoutException() => done(PersonFactsOutcome.timedOut),
      _ => done(PersonFactsOutcome.failed),
    };
  }
  memory.propose(keys, facts);
  final added = memory.book.suggestionsFor(keys).length - before;
  debugPrint(
    'weft: learn facts: ${recent.length} messages loaded, '
    '${transcript.length} sent, ${facts.length} facts read, $added new',
  );
  return added > 0
      ? done(PersonFactsOutcome.proposed, added: added)
      : done(PersonFactsOutcome.nothingNew);
}
