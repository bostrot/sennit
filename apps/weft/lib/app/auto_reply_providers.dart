import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

import '../data/auto_reply_transport.dart';
import '../services/ai/auto_reply_service.dart';
import '../services/billing/entitlements.dart';
import '../services/status/status_feed.dart' show isStatusBroadcastChat;
import 'billing_providers.dart';
import 'calendar_providers.dart';
import 'labels.dart';
import 'llm_settings.dart';
import 'person_memory_providers.dart';
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// The user's auto-reply rules.
///
/// One JSON blob in [WeftSettings.autoReplyRules], read as a unit because
/// `shouldReply` reads it as a unit. `AutoReplyRule.listFromJson` never throws,
/// so a blob from a newer build degrades rule by rule rather than leaving the
/// user with a feature that silently stopped.
class AutoReplyRules extends Notifier<List<AutoReplyRule>> {
  @override
  List<AutoReplyRule> build() {
    try {
      return AutoReplyRule.listFromJson(
        ref.read(storesProvider).settings.getJson(WeftSettings.autoReplyRules),
      );
    } on Object {
      // Stores not bootstrapped — a widget test pumping the screen directly,
      // or a launch that has not finished. `Object` rather than `StateError`
      // because Riverpod wraps what a provider throws, so the bootstrap's own
      // `StateError` never arrives as one. No rules is the safe direction to
      // fail in: nothing is ever sent.
      return const [];
    }
  }

  /// Replaces the list and persists it.
  ///
  /// Writes first and publishes second, so a rebuild triggered by the new state
  /// cannot read the old blob back out of the database.
  void replaceAll(List<AutoReplyRule> rules) {
    final next = List<AutoReplyRule>.unmodifiable(rules);
    try {
      ref
          .read(storesProvider)
          .settings
          .setJson(WeftSettings.autoReplyRules, AutoReplyRule.listToJson(next));
      ref.read(settingsRevisionProvider.notifier).bump();
    } on Object {
      // Same as above: in-memory only.
    }
    state = next;
  }

  /// Adds a rule, or replaces the one with the same id.
  ///
  /// One method for both because the editor cannot tell them apart and should
  /// not have to: it hands back a rule with an id, and whether that id was
  /// already in the list is this method's business.
  void save(AutoReplyRule rule) {
    final index = state.indexWhere((r) => r.id == rule.id);
    if (index < 0) {
      replaceAll([...state, rule]);
      return;
    }
    replaceAll([
      for (var i = 0; i < state.length; i++)
        if (i == index) rule else state[i],
    ]);
  }

  void remove(String ruleId) => replaceAll([
    for (final rule in state)
      if (rule.id != ruleId) rule,
  ]);

  /// Flips one rule's switch, leaving everything else about it alone.
  void setEnabled(String ruleId, {required bool enabled}) {
    final rule = state.where((r) => r.id == ruleId).firstOrNull;
    if (rule == null || rule.enabled == enabled) return;
    save(rule.copyWith(enabled: enabled));
  }
}

final autoReplyRulesProvider =
    NotifierProvider<AutoReplyRules, List<AutoReplyRule>>(AutoReplyRules.new);

/// The last few auto-reply attempts, so the settings screen can say what
/// happened.
///
/// In memory and bounded — see [kAutoReplyAttemptHistory]. A feature that sends
/// messages on someone's behalf must not fail where only a developer can see
/// it, and persisting the log would mean writing a copy of the conversation
/// into the settings table.
class AutoReplyLog extends Notifier<List<AutoReplyAttempt>> {
  @override
  List<AutoReplyAttempt> build() => const [];

  /// Records an attempt, newest first.
  void add(AutoReplyAttempt attempt) {
    state = [attempt, ...state.take(kAutoReplyAttemptHistory - 1)];
  }

  void clear() => state = const [];
}

final autoReplyLogProvider =
    NotifierProvider<AutoReplyLog, List<AutoReplyAttempt>>(AutoReplyLog.new);

/// The user's endpoint as the auto-reply path needs it, or null when nothing
/// is configured.
///
/// Watches the settings revision rather than caching, so supplying an endpoint
/// on the endpoints screen makes the next incoming message answerable without a
/// restart.
final autoReplyEndpointProvider = Provider<AutoReplyEndpoint?>((ref) {
  ref.watch(settingsRevisionProvider);
  // The one gate for every LLM path that reads this: auto-replies and the
  // to-do assistant both go quiet without an endpoint.
  if (!proUnlocked(ref, ProFeature.aiReplies)) return null;
  final WeftStores stores;
  try {
    stores = ref.read(storesProvider);
  } on Object {
    return null;
  }
  final (:baseUrl, :model) = llmEndpointOf(stores.settings);
  if (baseUrl.isEmpty || model.isEmpty) return null;
  final limits = llmModelSettingsOf(
    stores.settings,
    baseUrl: baseUrl,
    model: model,
  );
  // A model configured before the window could be detected, or whose server
  // was down when it was saved, is asked once per run.
  if (limits.detectedFrom == null && limits.contextTokens == null) {
    detectLlmLimitsInBackground(
      ref,
      baseUrl: baseUrl,
      model: model,
      apiKey: stores.llmApiKey,
    );
  }
  return AutoReplyEndpoint.resolve(
    baseUrl: baseUrl,
    model: model,
    apiKey: stores.llmApiKey,
    limits: limits,
  );
});

/// The auto-reply service, or null when this build cannot have one.
///
/// Null in demo mode and null before the session is up — and null, crucially,
/// when the repository is not an [AutoReplyTransport]. That last one is the
/// feature's own safety catch: the unread guarantee is a property of *that*
/// implementation, and a service pointed at a repository that could only
/// `send` would break the one promise it exists to keep. Falling back would be
/// worse than being dormant.
final autoReplyServiceProvider = Provider<AutoReplyService?>((ref) {
  if (kNoMatrix) return null;

  final session = ref.watch(matrixSessionProvider);
  if (!session.isInitialized) return null;

  final repository = ref.watch(chatRepositoryProvider);
  final transport = repository is AutoReplyTransport
      ? repository as AutoReplyTransport
      : null;
  if (transport == null) return null;

  final matrixSession = MatrixNotificationSession.forClient(session.client);

  final service = AutoReplyService(
    // The same seam the notification pipeline subscribes to: already
    // decrypted, already mapped, one `WeftMessage` per event. A second mapping
    // here would be a second answer to a question the app has answered.
    incoming: matrixSession.incomingMessages,
    transport: transport,
    chatForRoom: repository.chatForRoom,
    // Read per message, never captured: a rule switched on affects the next
    // message rather than the next launch.
    rules: () => ref.read(autoReplyRulesProvider),
    labelsOf: (chatId) => ref.read(chatLabelsProvider.notifier).ofChat(chatId),
    isServiceChat: repository.serviceChatIds.contains,
    isBroadcast: isStatusBroadcastChat,
    ownUserIds: () => matrixSession.ownUserIds,
    endpoint: () => ref.read(autoReplyEndpointProvider),
    onAttempt: (attempt) =>
        ref.read(autoReplyLogProvider.notifier).add(attempt),
    // Busy times, when the conversation is about meeting up — "are you free
    // on Friday?" answered from the calendar rather than guessed.
    calendar: (transcript) => aiCalendarContext(ref, transcript),
    // What the user noted about the chat and its people, when they let it be
    // sent.
    memory: (chat, recent) => ref.read(aiMemoryForPromptProvider)(chat, recent),
  );

  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// A chat the dry-run preview can be asked about, or null when the inbox is
/// empty.
///
/// The newest conversation with something in it, because a preview against an
/// empty transcript proves nothing — the point of the button is to see what the
/// prompt does to *a real message*.
Chat? previewChatFor(List<Chat> chats) {
  for (final chat in chats) {
    if (chat.isPendingRequest) continue;
    if (chat.lastMessage == null) continue;
    return chat;
  }
  return null;
}
