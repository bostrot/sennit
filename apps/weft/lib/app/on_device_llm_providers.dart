import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/models_screen.dart' show modelInstallerProvider;
import '../services/ai/on_device/on_device_llm.dart';
import '../services/ai/on_device/on_device_models.dart';
import 'llm_settings.dart';
import 'stores.dart';

/// The model on the phone, set as [OnDeviceLlm.instance] for as long as the
/// app's UI isolate lives; null where this build cannot run one.
///
/// Read once when the app starts. Loading nothing then: the model is loaded
/// by the first request to [kOnDeviceLlmBaseUrl] and unloaded when it has
/// been idle a while, or when the system says memory is short.
final onDeviceLlmProvider = Provider<OnDeviceLlm?>((ref) {
  if (!onDeviceLlmSupported) return null;
  final installer = ref.watch(modelInstallerProvider);
  final llm = OnDeviceLlm(
    modelPath: (spec) async {
      if (!await installer.isInstalled(spec.model)) return null;
      final file = await installer.fileFor(
        spec.model,
        spec.model.files.first.name,
      );
      return file.path;
    },
    // The window the user set for the model, read per request: changing it
    // reloads the model with the new one at the next request.
    requestedContext: (spec) {
      try {
        return llmModelSettingsOf(
          ref.read(storesProvider).settings,
          baseUrl: kOnDeviceLlmBaseUrl,
          model: spec.id,
        ).contextTokens;
      } on Object {
        return null;
      }
    },
  );
  OnDeviceLlm.instance = llm;
  ref.onDispose(() {
    if (identical(OnDeviceLlm.instance, llm)) OnDeviceLlm.instance = null;
    unawaited(llm.unload());
  });
  return llm;
});
