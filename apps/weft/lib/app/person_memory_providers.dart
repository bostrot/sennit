import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart' show MatrixNotificationSession;
import 'package:weft_merge/weft_merge.dart' show IdentityGraph, MergedTimeline;
import 'package:weft_store/weft_store.dart';

import '../services/ai/auto_reply_service.dart' show AutoReplyEndpoint;
import '../services/ai/conversation_context.dart' show kAiContextMessages;
import '../services/ai/event_title.dart' show recentConversationTranscript;
import '../services/ai/llm_budget.dart' show AiFeature;
import '../services/ai/memory_learner.dart';
import '../services/ai/person_memory.dart';
import '../services/ai/writing_style.dart';
import '../services/status/status_feed.dart' show isStatusBroadcastChat;
import 'auto_reply_providers.dart' show autoReplyEndpointProvider;
import 'providers.dart';
import 'search_providers.dart' show appInForegroundProvider;
import 'session_providers.dart';
import 'stores.dart';

/// The three switches of personal memory, read out of the settings store.
///
/// The master switch and the encrypted-chat one off unless set — see
/// [WeftSettings.personMemoryInAi] — automatic learning on, under the master
/// switch; every one read per use rather than captured, so turning the memory
/// off affects the next reply chip and not the next launch.
@immutable
class PersonMemorySettings {
  const PersonMemorySettings({
    this.useInAi = false,
    this.autoLearn = true,
    this.encryptedChats = false,
  });

  factory PersonMemorySettings.fromStore(SettingsStore settings) =>
      PersonMemorySettings(
        useInAi: settings.getBool(WeftSettings.personMemoryInAi),
        autoLearn: settings.getBool(
          WeftSettings.personMemoryAutoLearn,
          fallback: true,
        ),
        encryptedChats: settings.getBool(
          WeftSettings.personMemoryEncryptedChats,
        ),
      );

  /// The master switch: whether memory is ever sent to the model, with
  /// anything. Off means no memory in any prompt and nothing learned.
  final bool useInAi;

  /// Whether the memory keeps itself up to date in the background, on top of
  /// the "Learn now" button that always learns when asked. See
  /// `MemoryLearner`.
  final bool autoLearn;

  /// Whether learning runs on its own now: both switches on.
  bool get learnsAutomatically => useInAi && autoLearn;

  /// Whether an end-to-end encrypted conversation may be sent to learn from.
  final bool encryptedChats;

  /// Whether a conversation may be sent to propose facts from, given whether
  /// any of it is [encrypted].
  bool mayLearnFrom({required bool encrypted}) =>
      useInAi && (!encrypted || encryptedChats);

  void writeTo(SettingsStore settings) {
    settings.setBool(WeftSettings.personMemoryInAi, value: useInAi);
    settings.setBool(WeftSettings.personMemoryAutoLearn, value: autoLearn);
    settings.setBool(
      WeftSettings.personMemoryEncryptedChats,
      value: encryptedChats,
    );
  }

  PersonMemorySettings copyWith({
    bool? useInAi,
    bool? autoLearn,
    bool? encryptedChats,
  }) => PersonMemorySettings(
    useInAi: useInAi ?? this.useInAi,
    autoLearn: autoLearn ?? this.autoLearn,
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

/// Every note, learned fact, waiting fact and dismissal, as the keychain
/// holds them.
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

  /// [update] written into the memory of the chat filed under [chatKeys] and
  /// of its [people] — see [MemoryBook.applyLearning]. Returns how much it
  /// changed.
  int learn(
    MemoryUpdate update, {
    required List<String> chatKeys,
    required List<MemoryPerson> people,
    required List<NumberedFact> numbered,
    List<String>? ownStyleKeys,
    DateTime? now,
  }) {
    final result = state.applyLearning(
      update,
      chatKeys: chatKeys,
      people: people,
      numbered: numbered,
      ownStyleKeys: ownStyleKeys,
      now: now ?? DateTime.now(),
    );
    final changed = result.added + result.updated + result.dropped;
    if (changed > 0) _publish(result.book);
    return changed;
  }

  /// What older versions kept for the direct chat under [chatKeys] moved
  /// into its person's memory — see [MemoryBook.foldChatInto]. Nothing is
  /// written when there is nothing to move.
  void fold(List<String> chatKeys, List<String> personKeys) {
    final next = state.foldChatInto(chatKeys, personKeys);
    if (!identical(next, state)) _publish(next);
  }

  /// Every direct chat's memory moved into its person's, once — see
  /// [MemoryBook.mergeDirectChats].
  void mergeDirectChats(
    Iterable<({List<String> chatKeys, List<String> personKeys})> chats,
  ) {
    final next = state.mergeDirectChats(chats);
    if (!identical(next, state)) _publish(next);
  }

  /// Temporary facts whose day has passed at [now] gone, or turned into what
  /// they became. Returns how many changed.
  int expire(DateTime now) {
    final result = state.expire(now);
    if (result.changed > 0) _publish(result.book);
    return result.changed;
  }

  /// What the model said of facts learned before facts were sorted — see
  /// [MemoryBook.classify].
  void classify(
    Map<String, FactClass> sorted, {
    required List<LearnedFact> asked,
    required DateTime now,
  }) => _publish(state.classify(sorted, asked: asked, now: now));

  void editLearned(List<String> keys, LearnedFact fact, String text) =>
      _publish(state.editLearned(keys, fact, text, now: DateTime.now()));

  void pinLearned(
    List<String> keys,
    LearnedFact fact, {
    required bool pinned,
  }) => _publish(state.pinLearned(keys, fact, pinned: pinned));

  void deleteLearned(List<String> keys, LearnedFact fact) =>
      _publish(state.deleteLearned(keys, fact));

  /// Takes back the last automatic update.
  void undoAutomatic() => _publish(state.undoAutomatic());

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

/// The keys the one memory shown for [chat] is filed under: for a direct
/// chat the person's — what was the chat's is folded into it, see
/// [MemoryBook.foldChatInto] — and for a group the group's own.
List<String> aboutKeysFor(IdentityGraph graph, Chat chat) =>
    chat.isGroup ? chatMemoryKeys(chat) : personMemoryKeysFor(graph, chat);

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

/// What the prompts for [chat] are told, from [book]: the chat's memory and
/// the memory of [people], notes and learned facts, and how everyone writes —
/// the style profiles, and the user's habits and [ownMessages] here. Null when
/// there is none.
///
/// A direct chat's is one memory, its person's — with whatever is still
/// filed under the chat's rooms, until that is folded in.
AiMemory? aiMemoryFrom(
  MemoryBook book,
  Chat chat,
  List<MemoryPerson> people, {
  Iterable<WeftMessage> ownMessages = const [],
}) {
  final chatKeys = chatMemoryKeys(chat);
  final examples = ownStyleExamples(ownMessages);
  final direct = chat.isGroup ? null : people.firstOrNull;
  final memory = AiMemory(
    chat: book.memoryFor([...?direct?.keys, ...chatKeys]),
    about: direct?.name,
    people: [
      if (direct == null)
        for (final person in people)
          if (book.memoryFor(person.keys) case final note when note.isNotEmpty)
            (name: person.name, note: note),
    ],
    style: AiStyle(
      mine: book.styleFor(chatKeys)?.text ?? '',
      usual: book.styleFor(const [kOwnStyleKey])?.text ?? '',
      habits: measureWritingHabits(examples)?.describe() ?? '',
      examples: examples,
      theirs: [
        for (final person in people)
          if (book.styleFor(person.keys) case final style?)
            (name: person.name, style: style.text),
      ],
    ),
  );
  return memory.isEmpty ? null : memory;
}

/// The user's messages seen per chat this run, for the reply chips on a
/// notification, which arrive with little of the conversation. See
/// [OwnMessageCache].
final ownMessageCacheProvider = Provider<OwnMessageCache>(
  (ref) => OwnMessageCache(),
);

/// What to send with a prompt written for [chat], given the [recent]
/// messages the prompt is written from, or null.
///
/// The one gate every AI feature goes through: null while the master switch
/// is off, and null when nothing is noted. Untrimmed — the composers trim to
/// their endpoint's budget, in `memoryPromptBlock`.
///
/// The user's own messages in [recent], with those seen earlier this run, are
/// the examples of how they write — minus an encrypted chat's while learning
/// from those is off: older messages are more than the feature itself sends.
final aiMemoryForPromptProvider =
    Provider<AiMemory? Function(Chat chat, Iterable<WeftMessage> recent)>((
      ref,
    ) {
      return (chat, recent) {
        final settings = ref.read(personMemorySettingsProvider);
        if (!settings.useInAi) return null;
        final graph = ref.read(chatRepositoryProvider).identityGraph;
        return aiMemoryFrom(
          ref.read(personMemoryProvider),
          chat,
          memoryPeopleFor(graph, chat, recent),
          ownMessages: ref.read(ownMessageCacheProvider).remember(chat.id, [
            for (final m in recent)
              if (settings.mayLearnFrom(encrypted: m.encrypted)) m,
          ]),
        );
      };
    });

/// How asking the model about a conversation ended.
enum PersonFactsOutcome {
  /// The memory was updated; how many facts changed is
  /// [PersonFactsResult.changed].
  learned,

  /// The model answered, with nothing that is not already remembered.
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

  /// The model answered, but with no changes in a shape that could be read.
  unreadable,
}

typedef PersonFactsResult = ({
  PersonFactsOutcome outcome,

  /// How many facts were added, rewritten or dropped.
  int changed,

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

/// Asks the model what to change in what is remembered about [chat] from its
/// [messages], and writes the answer into the chat's and its [people]'s
/// memory.
///
/// Never touches a note the user wrote or a fact they pinned:
/// [PersonMemoryNotifier.learn] only adds, rewrites and drops learned facts,
/// and the last update can be undone. Every gate is checked here, before
/// anything is sent, so the two ways in — the "Learn now" button and the
/// background `MemoryLearner` — cannot disagree about what may leave the
/// device: the master switch, the encrypted-chat switch, and the endpoint
/// (which is also the Pro gate). How much of the conversation goes is the
/// model's: its window's share for learning (see `LlmBudget`), up to hundreds
/// of messages on a big one.
Future<PersonFactsResult> learnPersonFacts({
  required PersonMemorySettings settings,
  required AutoReplyEndpoint? endpoint,
  required PersonMemoryNotifier memory,
  required Chat chat,
  required List<MemoryPerson> people,
  required Iterable<WeftMessage> messages,
  http.Client? client,
  Future<void>? cancel,
  DateTime? now,
}) async {
  PersonFactsResult done(
    PersonFactsOutcome outcome, {
    int changed = 0,
    int? status,
  }) => (outcome: outcome, changed: changed, status: status);
  if (!settings.useInAi) return done(PersonFactsOutcome.memoryOff);
  final roomKeys = chatMemoryKeys(chat);
  if (roomKeys.isEmpty) return done(PersonFactsOutcome.nothingToSend);
  // A direct chat learns into its person's memory, the one it shows.
  final direct = chat.isGroup ? null : people.firstOrNull;
  final keys = direct?.keys ?? roomKeys;
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
    // Which day "tomorrow" was said on decides when a temporary fact goes.
    dayMarker: (day) => '--- ${promptDay(day)} ---',
  );
  if (transcript.isEmpty) {
    debugPrint(
      'weft: learn facts: ${recent.length} messages loaded, none in words',
    );
    return done(PersonFactsOutcome.nothingToSend);
  }

  if (direct != null) memory.fold(roomKeys, direct.keys);
  final book = memory.book;
  final memoryChars = endpoint.budget.memoryChars;
  final numbered = book.numberedFacts(keys, people, maxChars: memoryChars);
  final style = styleLearningFor(book, chat, people, recent);
  Object? failure;
  final update = await requestMemoryUpdate(
    baseUrl: endpoint.baseUrl,
    model: endpoint.model,
    apiKey: endpoint.apiKey,
    transcript: transcript,
    chatTitle: chat.title,
    people: [for (final p in people) p.name],
    fixed: fixedMemoryText(book, keys, people, maxChars: memoryChars),
    numbered: numbered,
    style: style,
    today: now ?? DateTime.now(),
    budget: endpoint.budget,
    client: client,
    cancel: cancel,
    onError: (error) => failure = error,
  );
  if (failure != null || update == null) {
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
  final changed = memory.learn(
    // A profile only for someone who wrote enough here to have one.
    update.withStyles(style.mayLearn),
    chatKeys: keys,
    people: people,
    // Numbered against the book as it was sent; an edit made meanwhile is
    // found by its text, or the change to it is skipped.
    numbered: numbered,
    ownStyleKeys: roomKeys,
    now: now,
  );
  debugPrint(
    'weft: learn facts: ${recent.length} messages loaded, '
    '${transcript.length} sent, $update, $changed changed',
  );
  return changed > 0
      ? done(PersonFactsOutcome.learned, changed: changed)
      : done(PersonFactsOutcome.nothingNew);
}

/// What the learning prompt is told about how everyone in [chat] writes: the
/// style profiles in [book] so far, and the habits measured in [messages] —
/// the user's own, and each of [people]'s.
///
/// In a direct chat the person is whoever is not the user; in a group, the
/// sender of that name.
StyleLearning styleLearningFor(
  MemoryBook book,
  Chat chat,
  List<MemoryPerson> people,
  Iterable<WeftMessage> messages,
) {
  final list = messages.toList();
  String habitsOf(bool Function(WeftMessage m) whose) =>
      measureWritingHabits(wordsOf(list.where(whose)))?.describe() ?? '';
  final theirHabits = <String, String>{};
  for (final person in people) {
    final habits = habitsOf(
      (m) =>
          !m.isOwn &&
          !m.isBridgeNotice &&
          (!chat.isGroup || m.senderName == person.name),
    );
    if (habits.isNotEmpty) theirHabits[person.name] = habits;
  }
  return StyleLearning(
    mine: book.styleFor(chatMemoryKeys(chat))?.text ?? '',
    usual: book.styleFor(const [kOwnStyleKey])?.text ?? '',
    theirs: {
      for (final person in people)
        if (book.styleFor(person.keys) case final style?)
          person.name: style.text,
    },
    myHabits: habitsOf((m) => m.isOwn),
    theirHabits: theirHabits,
  );
}

/// What the user wrote and pinned about the chat under [chatKeys] and its
/// [people], for the learning prompt to leave alone: the notes and the pinned
/// facts, each cut to a share of [maxChars].
String fixedMemoryText(
  MemoryBook book,
  List<String> chatKeys,
  List<MemoryPerson> people, {
  required int maxChars,
}) {
  String fixed(List<String> keys, int chars) {
    final pinned = [
      for (final f in book.learnedFor(keys))
        if (f.pinned) '- ${f.text}',
    ];
    final text = [
      book.noteFor(keys),
      if (pinned.isNotEmpty) pinned.join('\n'),
    ].where((t) => t.isNotEmpty).join('\n');
    return trimPersonMemory(text, maxChars: chars);
  }

  // A direct chat's memory is its person's: one, under their name.
  final chatId = chatKeys.join('\u0000');
  final direct = people
      .where((p) => p.keys.join('\u0000') == chatId)
      .firstOrNull;
  final others = [
    for (final p in people)
      if (p != direct) p,
  ];
  final share = others.isEmpty ? maxChars : maxChars ~/ 2;
  final parts = [
    if (fixed(chatKeys, share) case final chat when chat.isNotEmpty)
      direct == null
          ? 'About this group:\n$chat'
          : 'About ${direct.name}:\n$chat',
    for (final p in others)
      if (fixed(p.keys, math.max(160, share ~/ others.length)) case final note
          when note.isNotEmpty)
        'About ${p.name}:\n$note',
  ];
  return parts.join('\n\n');
}

/// Where [MemoryLearner] keeps its per-chat counts: how many messages arrived
/// since each chat was last read, and when. Counts and times only, never
/// anything a message said.
const String kMemoryLearnLogSetting = 'ai.person_memory_learn_log';

/// The background learner, or null when this build cannot have one — demo
/// mode, or before the session is up. Whether it *acts* is
/// [PersonMemorySettings.learnsAutomatically] and an endpoint, read per check.
final memoryLearnerProvider = Provider<MemoryLearner?>((ref) {
  if (kDemoMode) return null;
  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final repository = ref.watch(chatRepositoryProvider);
  final settings = storesOrNull(ref)?.settings;
  final learner = MemoryLearner(
    incoming: MatrixNotificationSession.forClient(
      session.client,
    ).incomingMessages,
    chatForRoom: repository.chatForRoom,
    chatById: (id) => (ref.read(chatsProvider).value ?? const <Chat>[])
        .where((c) => c.id == id)
        .firstOrNull,
    isServiceChat: repository.serviceChatIds.contains,
    isBroadcast: isStatusBroadcastChat,
    enabled: () =>
        ref.read(personMemorySettingsProvider).learnsAutomatically &&
        ref.read(autoReplyEndpointProvider) != null,
    learn: (chat, state) => learnInBackground(ref, chat, state),
    load: () => {
      for (final MapEntry(:key, :value)
          in (settings?.getJson(kMemoryLearnLogSetting) ??
                  const <String, Object?>{})
              .entries)
        key: MemoryLearnState.fromJson(value),
    },
    save: settings == null
        ? null
        : (states) => settings.setJson(kMemoryLearnLogSetting, {
            for (final MapEntry(:key, :value) in states.entries)
              key: value.toJson(),
          }),
    foreground: ref.watch(appInForegroundProvider),
  );
  ref.onDispose(() => unawaited(learner.dispose()));
  return learner;
});

/// One background pass over [chat]: its recent history, as much as the model
/// has room for on the first pass and what arrived since the last one (with
/// some of what led up to it) after that, through [learnPersonFacts] and its
/// gates. True when the pass went through, whatever it learned.
Future<bool> learnInBackground(
  Ref ref,
  Chat chat,
  MemoryLearnState state,
) async {
  final endpoint = ref.read(autoReplyEndpointProvider);
  if (endpoint == null) return false;
  final repository = ref.read(chatRepositoryProvider);
  final most = endpoint.budget.forFeature(AiFeature.learnFacts).maxMessages;
  final wanted = state.lastLearned == null
      ? most
      : (state.newMessages + kAiContextMessages).clamp(
          kAiContextMessages,
          most,
        );
  final messages = await loadHistoryForAi(
    await repository.timelineFor(chat.id),
    wanted,
  );
  final settings = ref.read(personMemorySettingsProvider);
  // What the chips on this chat's next notification can show as the user's
  // voice, under the same gate as learning from it.
  ref.read(ownMessageCacheProvider).remember(chat.id, [
    for (final m in messages)
      if (settings.mayLearnFrom(encrypted: m.encrypted)) m,
  ]);
  final result = await learnPersonFacts(
    settings: settings,
    endpoint: endpoint,
    memory: ref.read(personMemoryProvider.notifier),
    chat: chat,
    people: memoryPeopleFor(repository.identityGraph, chat, messages),
    // The newest [wanted]: a chat already open has more loaded than that.
    messages: messages.length > wanted
        ? messages.sublist(messages.length - wanted)
        : messages,
  );
  debugPrint('weft: memory pass: ${result.outcome.name} ${result.changed}');
  return switch (result.outcome) {
    PersonFactsOutcome.failed ||
    PersonFactsOutcome.timedOut ||
    PersonFactsOutcome.cutOff ||
    PersonFactsOutcome.unreadable ||
    PersonFactsOutcome.noEndpoint ||
    PersonFactsOutcome.memoryOff => false,
    _ => true,
  };
}

/// How often temporary facts are checked for having passed while Sennit
/// runs; also on every start and every return to the front.
const Duration kMemoryExpiryTick = Duration(hours: 1);

/// Keeps personal memory tidy on the device, with no server: moves each
/// direct chat's memory into its person's, once the chats are known (see
/// [MemoryBook.mergeDirectChats]), and lets temporary facts go when their day
/// has passed ([MemoryBook.expire]).
///
/// And once, the facts learned before facts were sorted into lasting and
/// temporary are sorted — through the model, so only while automatic
/// learning is on and there is an endpoint, [kClassifyBatch] at a time, one
/// request after the other. A batch that fails is tried again on the next
/// start or return to the front.
class MemoryHousekeeper {
  MemoryHousekeeper({
    required PersonMemoryNotifier Function() memory,
    required bool Function() mayAsk,
    required AutoReplyEndpoint? Function() endpoint,
    ValueListenable<bool>? foreground,
    DateTime Function()? now,
  }) : _memory = memory,
       _mayAsk = mayAsk,
       _endpoint = endpoint,
       _foreground = foreground,
       _now = now ?? DateTime.now;

  final PersonMemoryNotifier Function() _memory;
  final bool Function() _mayAsk;
  final AutoReplyEndpoint? Function() _endpoint;
  final ValueListenable<bool>? _foreground;
  final DateTime Function() _now;

  Timer? _ticker;
  bool _sorting = false;
  bool _started = false;
  bool _disposed = false;
  bool _merged = false;
  List<({List<String> chatKeys, List<String> personKeys})>? _waiting;

  void start() {
    if (_started) return;
    _started = true;
    _foreground?.addListener(_onForeground);
    _ticker = Timer.periodic(kMemoryExpiryTick, (_) => tidy());
    if (_waiting case final chats?) directChatsKnown(chats);
    tidy();
  }

  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _foreground?.removeListener(_onForeground);
  }

  void _onForeground() {
    if (_foreground?.value ?? true) tidy();
  }

  /// The direct chats, each as its rooms' keys and its person's, for the
  /// move — held until [start] when they come before it. Once a run: the
  /// run after the one that moved them finds the book moved and drops its
  /// backup, and a chat missed is folded when it is opened or learned from.
  void directChatsKnown(
    List<({List<String> chatKeys, List<String> personKeys})> chats,
  ) {
    if (_disposed || _merged) return;
    if (!_started) {
      _waiting = chats;
      return;
    }
    _waiting = null;
    _merged = true;
    try {
      _memory().mergeDirectChats(chats);
    } on Object catch (error) {
      debugPrint('weft: memory merge failed: ${error.runtimeType}');
    }
  }

  /// Lets what has passed go, then sorts what was never sorted.
  void tidy() {
    if (_disposed) return;
    final changed = _memory().expire(_now());
    if (changed > 0) debugPrint('weft: memory: $changed facts expired');
    unawaited(sortOldFacts());
  }

  /// Sorts the facts learned before they were sorted as they are learned,
  /// a batch at a time, until none are left or a batch fails.
  Future<void> sortOldFacts() async {
    if (_sorting || _disposed) return;
    _sorting = true;
    try {
      while (!_disposed && _mayAsk()) {
        final endpoint = _endpoint();
        if (endpoint == null) return;
        final memory = _memory();
        final batch = memory.book.unchecked.take(kClassifyBatch).toList();
        if (batch.isEmpty) return;
        final sorted = await requestFactClasses(
          baseUrl: endpoint.baseUrl,
          model: endpoint.model,
          apiKey: endpoint.apiKey,
          facts: batch,
          today: _now(),
          budget: endpoint.budget,
        );
        if (sorted == null || _disposed) return;
        memory.classify(sorted, asked: batch, now: _now());
      }
    } on Object catch (error) {
      debugPrint('weft: sort facts failed: ${error.runtimeType}');
    } finally {
      _sorting = false;
    }
  }
}

/// The [MemoryHousekeeper], or null in demo mode. Started with the session,
/// like the learner.
final memoryHousekeeperProvider = Provider<MemoryHousekeeper?>((ref) {
  if (kDemoMode) return null;
  final keeper = MemoryHousekeeper(
    memory: () => ref.read(personMemoryProvider.notifier),
    mayAsk: () => ref.read(personMemorySettingsProvider).learnsAutomatically,
    endpoint: () => ref.read(autoReplyEndpointProvider),
    foreground: ref.watch(appInForegroundProvider),
  );
  ref.listen(chatsProvider, (_, next) {
    final chats = next.value;
    if (chats == null || chats.isEmpty) return;
    final graph = ref.read(chatRepositoryProvider).identityGraph;
    keeper.directChatsKnown([
      for (final chat in chats)
        if (!chat.isGroup)
          (
            chatKeys: chatMemoryKeys(chat),
            personKeys: personMemoryKeysFor(graph, chat),
          ),
    ]);
  }, fireImmediately: true);
  ref.onDispose(keeper.dispose);
  return keeper;
});
