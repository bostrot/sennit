import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/llm_settings.dart';
import '../ai/conversation_context.dart';
import '../ai/llm_budget.dart';
import '../ai/person_memory.dart' show AiMemory;
import '../ai/smart_replies.dart';

/// What [WeftNotificationService.suggestReplies] is set to.
typedef ReplySuggester =
    Future<List<String>> Function(
      NotificationContent content,
      List<WeftMessage> thread,
    );

/// The model the reply chips ask: the one set for them, or the AI model.
String smartReplyModel(SettingsStore settings) {
  final own = (settings.getString(WeftSettings.llmSuggestionModel) ?? '')
      .trim();
  return own.isNotEmpty
      ? own
      : (settings.getString(WeftSettings.llmModel) ?? '').trim();
}

/// The AI answer chips for message notifications, for every engine that
/// posts them: the UI's, the sync daemon's and the one a UnifiedPush poke
/// boots headless — the last being the only one on a phone without Google
/// services, and for a long time the one that asked for no chips at all.
///
/// Everything is read per message rather than captured, so flipping a setting
/// needs no restart; every failure path is an empty list, because a
/// notification is not the place for an error. [calendar] and [memory] are
/// what the UI engine adds from its providers; a headless engine has neither
/// and leaves them out.
ReplySuggester notificationReplySuggester({
  required SettingsStore? Function() settings,
  required String? Function() apiKey,
  required bool Function() proUnlocked,
  required Set<String> Function() serviceChatIds,
  Future<String?> Function(List<String> transcript)? calendar,
  AiMemory? Function(NotificationContent content, List<WeftMessage> thread)?
  memory,
  @visibleForTesting http.Client? client,
}) {
  return (content, thread) async {
    // A bridge bot's login prompts are not a conversation to be witty in.
    if (serviceChatIds().contains(content.groupKey)) return const [];
    final SettingsStore? store;
    try {
      store = settings();
    } on Object {
      return const [];
    }
    if (store == null) return const [];
    if (!proUnlocked()) return const [];
    if (!store.getBool(WeftSettings.notifySmartReplies, fallback: true)) {
      debugPrint('weft: smart replies: the setting is off');
      return const [];
    }
    // Android is the one platform that draws them: its reply action takes
    // them as choices, and no other platform's notification has a place for
    // them. Anywhere else the completion would be spent on nothing.
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    final baseUrl = store.getString(WeftSettings.llmBaseUrl) ?? '';
    final model = smartReplyModel(store);
    if (baseUrl.trim().isEmpty || model.isEmpty) {
      debugPrint('weft: smart replies: no LLM endpoint is configured');
      return const [];
    }
    // Bounded by the service's own buffer — `kAiContextMessages` decides how
    // many messages leave the device — and then by the share of the model's
    // window the chips get, which keeps them fast. Projected by the same
    // function the auto-reply transcript goes through, so the two features
    // send the one endpoint the same shape of conversation.
    final budget = LlmBudget.resolve(
      baseUrl,
      llmModelSettingsOf(store, baseUrl: baseUrl, model: model),
    );
    final transcript = fitTranscript(
      transcriptLinesFor(thread),
      budget.forFeature(AiFeature.smartReplies).transcriptChars,
    );
    return suggestSmartReplies(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey(),
      budget: budget,
      chatTitle: content.title,
      transcript: transcript,
      calendar: await calendar?.call(transcript),
      memory: memory?.call(content, thread),
      client: client,
    );
  };
}
