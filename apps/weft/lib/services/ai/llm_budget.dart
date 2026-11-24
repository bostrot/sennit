import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'llm_request.dart';

/// The AI features that ask the model something, as far as how much they may
/// send and how long the answer may be.
enum AiFeature {
  /// The chips on a notification: two short answers, added to it when they
  /// are written.
  smartReplies,

  /// A quick message the user tapped for.
  quickMessage,

  /// An auto-reply, written in the background.
  autoReply,

  /// The to-do assistant's review of a conversation.
  todo,

  /// A calendar entry's title.
  eventTitle,

  /// "Learn from chat": facts worth remembering from a conversation.
  learnFacts,

  /// A person's note cut down to a few lines.
  condense,
}

/// Whether [feature] writes a message the user sends — in their name, so in
/// their style.
bool writesAsUser(AiFeature feature) => switch (feature) {
  AiFeature.smartReplies ||
  AiFeature.quickMessage ||
  AiFeature.autoReply => true,
  _ => false,
};

/// The context window assumed for a model nothing could be detected for.
///
/// Small on purpose: every model people run today has at least this, and a
/// prompt sized for a bigger window would be cut off — or refused — by one
/// that does not have it. The settings screen says this is a guess.
const int kLlmFallbackContextTokens = 8192;

/// The answer length a hosted API gets unless the user says otherwise.
///
/// Every token is paid for there, so a hosted model is not taken for a
/// thinking one and each feature first asks for the short answer it needs.
/// This is only the room for the one retry after an answer was cut off — what
/// a hosted reasoning model needs to finish, and paid for only when used.
const int kLlmHostedAnswerTokens = 4096;

/// The answer length a self-hosted model gets unless the user says otherwise.
///
/// Generous, because a local thinking model spends the answer's budget on its
/// reasoning first and nothing is paid for: a Qwen behind litellm used a
/// thousand tokens thinking about a six-line chat. A model that needs none of
/// it stops at its answer and the rest is never used.
const int kLlmLocalAnswerTokens = 8192;

/// Tokens set aside for the instructions and worked examples every prompt
/// carries around the conversation.
const int kLlmPromptOverheadTokens = 1500;

/// How many characters one token is reckoned at, when a budget in tokens has
/// to become one in characters.
///
/// Low on purpose: English runs at about four, German and emoji-heavy chat
/// at fewer, and running over a context window costs more than leaving a
/// little of it unused.
const int kLlmCharsPerToken = 3;

/// The least conversation any feature sends, in characters, however small the
/// window: the figure every feature used before it was known.
const int kLlmMinTranscriptChars = 2400;

/// What the user set for the configured model, and what was detected about it.
///
/// Stored per base URL and model (see [LlmModelSettings.keyFor]), so switching
/// to another model and back keeps each one's numbers.
@immutable
class LlmModelSettings {
  const LlmModelSettings({
    this.contextTokens,
    this.answerTokens,
    this.thinking,
    this.detectedContextTokens,
    this.detectedOutputTokens,
    this.detectedFrom,
  });

  static const LlmModelSettings none = LlmModelSettings();

  /// The context window the user typed, or null for "detect it".
  final int? contextTokens;

  /// The answer length the user typed, or null for the default.
  final int? answerTokens;

  /// Whether the user said this is a thinking model, or null for the default.
  final bool? thinking;

  /// The context window the server reported, or null.
  final int? detectedContextTokens;

  /// The longest answer the server reported, or null.
  final int? detectedOutputTokens;

  /// Which kind of server reported it ("litellm", "ollama", …), or null when
  /// nothing was ever detected.
  final String? detectedFrom;

  /// The key one model's settings are filed under.
  static String keyFor(String baseUrl, String model) =>
      '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}|${model.trim()}';

  LlmModelSettings copyWith({
    int? Function()? contextTokens,
    int? Function()? answerTokens,
    bool? Function()? thinking,
    int? Function()? detectedContextTokens,
    int? Function()? detectedOutputTokens,
    String? Function()? detectedFrom,
  }) => LlmModelSettings(
    contextTokens: contextTokens == null ? this.contextTokens : contextTokens(),
    answerTokens: answerTokens == null ? this.answerTokens : answerTokens(),
    thinking: thinking == null ? this.thinking : thinking(),
    detectedContextTokens: detectedContextTokens == null
        ? this.detectedContextTokens
        : detectedContextTokens(),
    detectedOutputTokens: detectedOutputTokens == null
        ? this.detectedOutputTokens
        : detectedOutputTokens(),
    detectedFrom: detectedFrom == null ? this.detectedFrom : detectedFrom(),
  );

  Map<String, Object?> toJson() => {
    'context': ?contextTokens,
    'answer': ?answerTokens,
    'thinking': ?thinking,
    'detected_context': ?detectedContextTokens,
    'detected_output': ?detectedOutputTokens,
    'detected_from': ?detectedFrom,
  };

  static LlmModelSettings fromJson(Object? json) {
    if (json is! Map) return none;
    int? positive(Object? v) => v is int && v > 0 ? v : null;
    return LlmModelSettings(
      contextTokens: positive(json['context']),
      answerTokens: positive(json['answer']),
      thinking: json['thinking'] is bool ? json['thinking'] as bool : null,
      detectedContextTokens: positive(json['detected_context']),
      detectedOutputTokens: positive(json['detected_output']),
      detectedFrom: json['detected_from'] is String
          ? json['detected_from'] as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LlmModelSettings &&
      other.contextTokens == contextTokens &&
      other.answerTokens == answerTokens &&
      other.thinking == thinking &&
      other.detectedContextTokens == detectedContextTokens &&
      other.detectedOutputTokens == detectedOutputTokens &&
      other.detectedFrom == detectedFrom;

  @override
  int get hashCode => Object.hash(
    contextTokens,
    answerTokens,
    thinking,
    detectedContextTokens,
    detectedOutputTokens,
    detectedFrom,
  );
}

/// How much one AI feature may send, and how long an answer it asks for.
@immutable
class FeatureBudget {
  const FeatureBudget({
    required this.maxTokens,
    required this.retryMaxTokens,
    required this.maxMessages,
    required this.transcriptChars,
  });

  /// The `max_tokens` of the first request.
  final int maxTokens;

  /// The `max_tokens` of the one retry after an answer cut off at
  /// [maxTokens]; the same as [maxTokens] when there is no more room to give.
  final int retryMaxTokens;

  /// How many messages of the conversation may be sent.
  final int maxMessages;

  /// How many characters of conversation may be sent.
  final int transcriptChars;

  @override
  String toString() =>
      'FeatureBudget(max_tokens $maxTokens/$retryMaxTokens, '
      '$maxMessages messages, $transcriptChars chars)';
}

/// The configured model's context window and answer length, and what each AI
/// feature gets of them.
///
/// Every feature used to carry its own numbers — 120 tokens for the chips, a
/// dozen messages for a quick message, 400 characters of notes for a local
/// model — sized for the smallest model anyone might run. A model with a 200k
/// window was then sent a few hundred tokens of a conversation, and a thinking
/// model ran out of answer before it was done thinking. Now the window and the
/// answer length are the model's, detected or typed in, and the features take
/// a share of them.
@immutable
class LlmBudget {
  const LlmBudget({
    required this.contextTokens,
    required this.answerTokens,
    required this.thinking,
    required this.hosted,
    this.contextDetected = false,
  });

  /// The budget for [baseUrl] from what [settings] says, user's numbers
  /// first, then what was detected, then the defaults.
  ///
  /// The answer length is capped by the model's own limit when one was
  /// detected; a typed one is not, since the user may know better than the
  /// server's table.
  factory LlmBudget.resolve(
    String baseUrl, [
    LlmModelSettings settings = LlmModelSettings.none,
  ]) {
    final hosted = isHostedLlm(baseUrl);
    final context =
        settings.contextTokens ??
        settings.detectedContextTokens ??
        kLlmFallbackContextTokens;
    final detectedOutput = settings.detectedOutputTokens;
    var answer =
        settings.answerTokens ??
        (hosted ? kLlmHostedAnswerTokens : kLlmLocalAnswerTokens);
    if (settings.answerTokens == null && detectedOutput != null) {
      answer = math.min(answer, detectedOutput);
    }
    return LlmBudget(
      contextTokens: context,
      answerTokens: answer,
      thinking: settings.thinking ?? !hosted,
      hosted: hosted,
      contextDetected:
          settings.contextTokens == null &&
          settings.detectedContextTokens != null,
    );
  }

  /// The context window, in tokens: prompt and answer together.
  final int contextTokens;

  /// The longest answer any feature asks for, in tokens.
  final int answerTokens;

  /// Whether the model reasons before it answers, so every feature leaves it
  /// room to: a short answer is then only short after the thinking.
  final bool thinking;

  /// Whether the model is behind a hosted API, which every token is paid for.
  final bool hosted;

  /// Whether [contextTokens] came from the server rather than the user or the
  /// fallback.
  final bool contextDetected;

  /// The longest answer that still leaves half the window for the prompt — an
  /// 8k window with an 8k answer would leave none.
  int get _answerCap =>
      math.max(256, math.min(answerTokens, contextTokens ~/ 2));

  /// How long an answer [feature] needs when nothing is spent on thinking.
  static int naturalAnswerTokens(AiFeature feature) => switch (feature) {
    AiFeature.smartReplies => 120,
    AiFeature.eventTitle => 60,
    AiFeature.quickMessage => 512,
    AiFeature.autoReply => 1024,
    AiFeature.todo => 400,
    AiFeature.learnFacts => 1024,
    AiFeature.condense => 512,
  };

  /// The share of the prompt's room [feature]'s conversation may take, and
  /// the most it may take however big the window is.
  ///
  /// The ceilings are the time cap: a local model reads every token of the
  /// prompt before it writes one, at a few hundred to a few thousand a second,
  /// and a 200k window filled to the brim would be minutes of that for a
  /// birthday wish. Learning from a chat is the one feature the user waits
  /// for knowing it reads a lot, so it gets most; the chips get least, since
  /// they are worth most the moment the message arrives.
  static ({double share, int localCap, int hostedCap}) _inputShare(
    AiFeature feature,
  ) => switch (feature) {
    AiFeature.smartReplies => (share: 0.2, localCap: 1000, hostedCap: 1000),
    AiFeature.eventTitle => (share: 0.25, localCap: 2000, hostedCap: 2000),
    AiFeature.quickMessage => (share: 0.25, localCap: 3000, hostedCap: 2000),
    AiFeature.autoReply => (share: 0.3, localCap: 4000, hostedCap: 3000),
    AiFeature.todo => (share: 0.3, localCap: 4000, hostedCap: 3000),
    AiFeature.learnFacts => (share: 0.6, localCap: 32000, hostedCap: 12000),
    AiFeature.condense => (share: 0.3, localCap: 4000, hostedCap: 2000),
  };

  /// The most messages [feature] sends, however much room there is.
  static int _messageCap(AiFeature feature, {required bool hosted}) =>
      switch (feature) {
        AiFeature.smartReplies || AiFeature.autoReply || AiFeature.todo => 24,
        AiFeature.eventTitle => 16,
        AiFeature.quickMessage => 20,
        AiFeature.learnFacts => hosted ? 200 : 500,
        AiFeature.condense => 0,
      };

  /// What [feature] may send and ask for under this budget.
  FeatureBudget forFeature(AiFeature feature) {
    final natural = naturalAnswerTokens(feature);
    final cap = _answerCap;
    final int first;
    final int retry;
    if (feature == AiFeature.smartReplies) {
      // Short and fast whatever the model: they are worth most while the
      // notification is new. A thinking model is asked not to think, and gets
      // enough to think briefly should the server ignore that; no retry — the
      // second try would arrive after the notification was read.
      first = thinking ? math.min(cap, 1024) : math.min(cap, natural);
      retry = first;
    } else {
      first = thinking ? cap : math.min(cap, natural);
      retry = cap;
    }
    final room = math.max(
      0,
      contextTokens -
          retry -
          kLlmPromptOverheadTokens -
          (memoryChars + styleCharsFor(feature)) ~/ kLlmCharsPerToken,
    );
    final share = _inputShare(feature);
    final tokens = math.min(
      (room * share.share).floor(),
      hosted ? share.hostedCap : share.localCap,
    );
    return FeatureBudget(
      maxTokens: first,
      retryMaxTokens: retry,
      maxMessages: _messageCap(feature, hosted: hosted),
      // Never less than every feature sent before the window was known: a
      // small one still gets the newest messages and what led up to them.
      transcriptChars: math.max(
        kLlmMinTranscriptChars,
        tokens * kLlmCharsPerToken,
      ),
    );
  }

  /// The most characters of the user's notes any prompt carries.
  ///
  /// A tenth of what the window leaves after the answer, between the old
  /// fixed figures — 400 characters for a self-hosted model, 1200 for a
  /// hosted one — and 6000, past which notes stop being notes.
  int get memoryChars {
    final room = math.max(
      0,
      contextTokens - _answerCap - kLlmPromptOverheadTokens,
    );
    return ((room * kLlmCharsPerToken) ~/ 10).clamp(hosted ? 1200 : 400, 6000);
  }

  /// The share of [memoryChars] [feature]'s prompt carries.
  ///
  /// The chips and a calendar title are short answers wanted at once, and
  /// need little more than the names and the tone; a to-do review needs who
  /// is who; a message the user sends gets everything.
  int memoryCharsFor(AiFeature feature) => switch (feature) {
    AiFeature.smartReplies ||
    AiFeature.eventTitle => math.max(hosted ? 600 : 240, memoryChars ~/ 2),
    AiFeature.todo => math.max(hosted ? 800 : 300, (memoryChars * 2) ~/ 3),
    _ => memoryChars,
  };

  /// The most characters [feature]'s prompt spends on how the user writes —
  /// the style profiles and a few of their own messages, see
  /// `stylePromptBlock` — and none for a feature that does not write as the
  /// user.
  ///
  /// The chips get enough for the profiles and five to ten short examples,
  /// and no more: every character is read before the first word on a local
  /// model, and the chips are wanted now. A message the user sends gets room
  /// for ten.
  int styleCharsFor(AiFeature feature) => switch (feature) {
    AiFeature.smartReplies => hosted ? 1600 : 1300,
    AiFeature.quickMessage ||
    AiFeature.autoReply => (memoryChars ~/ 2).clamp(hosted ? 2000 : 1600, 2400),
    _ => 0,
  };

  /// The most of one person's note a prompt carries: a third of
  /// [memoryChars], so a group's few speakers and the chat itself all fit.
  int get personMemoryChars => (memoryChars ~/ 3).clamp(160, 2000);

  @override
  bool operator ==(Object other) =>
      other is LlmBudget &&
      other.contextTokens == contextTokens &&
      other.answerTokens == answerTokens &&
      other.thinking == thinking &&
      other.hosted == hosted &&
      other.contextDetected == contextDetected;

  @override
  int get hashCode => Object.hash(
    contextTokens,
    answerTokens,
    thinking,
    hosted,
    contextDetected,
  );

  @override
  String toString() =>
      'LlmBudget(context $contextTokens, answer $answerTokens, '
      '${thinking ? 'thinking' : 'not thinking'}, '
      '${hosted ? 'hosted' : 'self-hosted'})';
}
