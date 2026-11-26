import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import '../services/ai/llm_budget.dart';
import '../services/ai/llm_limits.dart';
import '../services/ai/on_device/on_device_models.dart';
import 'stores.dart';

/// The endpoint every AI feature asks: the model on the phone when the user
/// picked one and this build can run it, otherwise the configured server.
///
/// Either may be empty — nothing configured — which every feature reads as
/// "stay dormant".
({String baseUrl, String model}) llmEndpointOf(SettingsStore settings) {
  final onDevice = onDeviceLlmModelOf(settings);
  if (onDevice != null) {
    return (baseUrl: kOnDeviceLlmBaseUrl, model: onDevice.id);
  }
  return (
    baseUrl: (settings.getString(WeftSettings.llmBaseUrl) ?? '').trim(),
    model: (settings.getString(WeftSettings.llmModel) ?? '').trim(),
  );
}

/// The on-device model the AI features use, or null when they use the
/// server — none picked, or not one this build can run.
OnDeviceLlmSpec? onDeviceLlmModelOf(SettingsStore settings) {
  if (!onDeviceLlmSupported) return null;
  return OnDeviceLlmSpec.byId(
    settings.getString(WeftSettings.onDeviceLlmModel),
  );
}

/// What is stored for [model] at [baseUrl]: the user's numbers and what the
/// server reported.
LlmModelSettings llmModelSettingsOf(
  SettingsStore settings, {
  required String baseUrl,
  required String model,
}) {
  final all = settings.getJson(WeftSettings.llmModelLimits);
  return LlmModelSettings.fromJson(
    all?[LlmModelSettings.keyFor(baseUrl, model)],
  );
}

/// Stores [value] for [model] at [baseUrl], leaving every other model's as it
/// is.
void storeLlmModelSettings(
  SettingsStore settings, {
  required String baseUrl,
  required String model,
  required LlmModelSettings value,
}) {
  final all = {...?settings.getJson(WeftSettings.llmModelLimits)};
  final key = LlmModelSettings.keyFor(baseUrl, model);
  final json = value.toJson();
  if (json.isEmpty) {
    all.remove(key);
  } else {
    all[key] = json;
  }
  settings.setJson(WeftSettings.llmModelLimits, all);
}

/// [settings] with what [limits] says filled in as detected — or the detected
/// numbers cleared, when [limits] is null.
LlmModelSettings withDetected(LlmModelSettings settings, LlmLimits? limits) =>
    settings.copyWith(
      detectedContextTokens: () => limits?.contextTokens,
      detectedOutputTokens: () => limits?.outputTokens,
      detectedFrom: () => limits?.from,
    );

/// The models whose limits were asked for this run, so a server that says
/// nothing is not asked again on every settings change.
final Set<String> _detectionTried = {};

/// Asks the configured server for its model's limits once per run, when
/// nothing was ever detected for it, and stores what it says.
///
/// In the background and best effort: until it answers, and when it never
/// does, the features run on the fallback window. Only the limits endpoints
/// are asked (see [detectLlmLimits]) — nothing about any chat.
void detectLlmLimitsInBackground(
  Ref ref, {
  required String baseUrl,
  required String model,
  String? apiKey,
}) {
  final key = LlmModelSettings.keyFor(baseUrl, model);
  if (!_detectionTried.add(key)) return;
  // Read now: [ref] belongs to a provider that rebuilds whenever a setting
  // changes, and may be gone by the time the server answers.
  final SettingsStore settings;
  try {
    settings = ref.read(storesProvider).settings;
  } on Object {
    _detectionTried.remove(key);
    return;
  }
  final revision = ref.read(settingsRevisionProvider.notifier);
  unawaited(() async {
    try {
      final limits = await detectLlmLimits(
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
      );
      if (limits == null) return;
      final current = llmModelSettingsOf(
        settings,
        baseUrl: baseUrl,
        model: model,
      );
      final next = withDetected(current, limits);
      if (next == current) return;
      storeLlmModelSettings(
        settings,
        baseUrl: baseUrl,
        model: model,
        value: next,
      );
      revision.bump();
    } on Object catch (error) {
      debugPrint('weft: llm limits: ${error.runtimeType}');
    }
  }());
}
