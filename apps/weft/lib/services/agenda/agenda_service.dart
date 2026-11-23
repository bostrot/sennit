import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/auto_reply_providers.dart';
import '../../app/person_memory_providers.dart' show aiMemoryForPromptProvider;
import '../../app/providers.dart' show chatRepositoryProvider;
import '../../app/search_providers.dart';
import '../../app/stores.dart';
import '../ai/event_title.dart';
import '../ai/person_memory.dart' show AiMemory;
import '../ai/llm_budget.dart' show AiFeature;
import 'event_detector.dart';

/// Decides which messages deserve an "add to calendar" chip.
///
/// Two stages. The rule detector finds a concrete date, and it alone admits
/// the confident shapes — a time of day, or an intent word like "Termin".
/// The ambiguous shape — a date with neither — is referred to the small local
/// model when one is installed: the message is embedded and compared against
/// prototype appointment sentences, so "dinner next friday 8pm" and "das
/// Paket kam am 12.05." land on different sides of the same line. No model,
/// no referral — the rules alone still carry the common cases.
class AgendaService {
  AgendaService(this._ref);

  final Ref _ref;

  /// Per-session verdicts, so scrolling past a bubble twice detects once.
  final Map<String, AgendaCandidate?> _verdicts = {};
  final Set<String> _inFlight = {};

  /// Prototype vectors, embedded once per provider generation.
  List<Int8List>? _prototypes;
  EmbeddingProvider? _prototypeProvider;

  static const _prototypeSentences = [
    'let us meet on friday at three',
    'your appointment is scheduled for next week',
    'the deadline for the project is on monday',
    'we are visiting grandma on sunday afternoon',
    'the flight leaves tomorrow morning',
    'wir treffen uns am dienstag um vier',
    'dein termin ist nächste woche beim arzt',
    'die abgabe ist spätestens am freitag',
  ];

  bool get enabled =>
      storesOrNull(
        _ref,
      )?.settings.getBool(WeftSettings.agendaDetect, fallback: true) ??
      false;

  /// The cached verdict, when one exists. Null means "no event"; absence
  /// means "not looked yet" — ask [detect].
  AgendaCandidate? cached(String eventId) => _verdicts[eventId];

  bool hasVerdict(String eventId) => _verdicts.containsKey(eventId);

  /// Examines [message] once, remembering the answer.
  Future<AgendaCandidate?> detect(WeftMessage message) async {
    if (!enabled) return null;
    if (_verdicts.containsKey(message.eventId)) {
      return _verdicts[message.eventId];
    }
    if (!_inFlight.add(message.eventId)) return null;

    try {
      final verdict = await _examine(message);
      _verdicts[message.eventId] = verdict;
      return verdict;
    } finally {
      _inFlight.remove(message.eventId);
    }
  }

  /// Titles the model has already been asked for, so a second tap on the
  /// same chip opens the calendar at once.
  final Map<String, String> _titles = {};

  /// What to call [candidate] in a calendar.
  ///
  /// The configured LLM names it when there is one, from [conversation] around
  /// [message] — both sides of it, see [eventTitleTranscript] — rather than
  /// from the one message with the date, which is usually "friday at 7?" and
  /// names nothing. Without a model, when it fails, or when all it says is
  /// "Meeting", the rule-made [AgendaCandidate.title] stands. Asked only here
  /// — on the tap, not at detection — so a message leaves the device because
  /// its chip was used, never merely because it was scrolled past.
  Future<String> titleFor(
    WeftMessage message,
    AgendaCandidate candidate, {
    Iterable<WeftMessage> conversation = const [],
  }) async {
    final known = _titles[message.eventId];
    if (known != null) return known;
    final endpoint = _ref.read(autoReplyEndpointProvider);
    if (endpoint == null) return candidate.title;

    final suggested = await suggestEventTitle(
      baseUrl: endpoint.baseUrl,
      model: endpoint.model,
      apiKey: endpoint.apiKey,
      transcript: eventTitleTranscript(
        message,
        conversation,
        maxChars: endpoint.budget
            .forFeature(AiFeature.eventTitle)
            .transcriptChars,
      ),
      budget: endpoint.budget,
      memory: _memoryFor(message, conversation),
    );
    final title = chooseEventTitle(
      model: suggested,
      fallback: candidate.title,
      message: message.body,
    );
    if (title == candidate.title) return title;
    return _titles[message.eventId] = title;
  }

  /// What the title prompt is told about [message]'s chat and its people, or
  /// null — off, nothing noted, or no chat to look it up for.
  AiMemory? _memoryFor(
    WeftMessage message,
    Iterable<WeftMessage> conversation,
  ) {
    try {
      final chat = _ref
          .read(chatRepositoryProvider)
          .chatForRoom(message.roomId);
      if (chat == null) return null;
      return _ref.read(aiMemoryForPromptProvider)(chat, [
        ...conversation,
        message,
      ]);
    } on Object {
      // No repository — a widget test, or a session still starting.
      return null;
    }
  }

  Future<AgendaCandidate?> _examine(WeftMessage message) async {
    if (message.kind != MessageKind.text || message.redacted) return null;

    final now = DateTime.now();
    final candidate = detectAgendaEvent(message.body, now: now);
    if (candidate == null) return null;

    // A calendar adds what is ahead; "born on 12.05.1990" stays a sentence.
    if (candidate.start.isBefore(now.subtract(const Duration(hours: 1)))) {
      return null;
    }

    // Confident on rules alone.
    if (candidate.keywordMatched || candidate.hasTime) return candidate;

    // Date, no time, no intent word: only the model may admit it.
    final provider = _ref.read(embeddingProviderProvider);
    if (provider == null) return null;

    try {
      final prototypes = await _prototypesFor(provider);
      final embedded = await provider.embed([message.body]);
      final vector = embedded.first;
      var best = -1.0;
      for (final prototype in prototypes) {
        final score = quantizedSimilarity(vector, prototype);
        if (score > best) best = score;
      }
      return best >= 0.45 ? candidate : null;
    } on EmbeddingException {
      // The model being unavailable is not a reason to break chat rendering.
      return null;
    }
  }

  Future<List<Int8List>> _prototypesFor(EmbeddingProvider provider) async {
    if (_prototypes != null && identical(_prototypeProvider, provider)) {
      return _prototypes!;
    }
    final vectors = await provider.embed(_prototypeSentences);
    _prototypes = vectors;
    _prototypeProvider = provider;
    return vectors;
  }
}

final agendaServiceProvider = Provider<AgendaService>(AgendaService.new);
