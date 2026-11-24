import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/auto_reply_providers.dart' show autoReplyEndpointProvider;
import '../../app/localisation.dart';
import '../../app/person_memory_providers.dart';
import '../../services/ai/conversation_context.dart' show kAiContextMessages;
import '../../services/ai/llm_budget.dart' show AiFeature;

/// Personal memory's switches, and the one place that says what leaves the
/// device because of it.
///
/// The notes are written on each person's contact screen; this is where the
/// user decides whether any of them is ever sent.
class PersonMemorySettingsScreen extends ConsumerWidget {
  const PersonMemorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(personMemorySettingsProvider);
    final people = ref.watch(personMemoryProvider).notes.values.toSet().length;

    void save(PersonMemorySettings next) => savePersonMemorySettings(ref, next);

    Future<void> forgetAll() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.personMemoryForgetAllTitle),
          content: Text(l10n.personMemoryForgetAllBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.commonDelete),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      ref.read(personMemoryProvider.notifier).forgetAll();
      showWeftMessage(context, l10n.personMemoryForgotAll);
    }

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.personMemorySettingsTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.only(bottom: WeftSpace.xxl),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                WeftSpace.lg,
                WeftSpace.md,
                WeftSpace.lg,
                WeftSpace.sm,
              ),
              child: Text(
                l10n.personMemoryExplainer(
                  ref
                          .watch(autoReplyEndpointProvider)
                          ?.budget
                          .forFeature(AiFeature.learnFacts)
                          .maxMessages ??
                      kAiContextMessages,
                ),
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('person-memory-use-in-ai'),
              secondary: const Icon(Icons.auto_awesome_outlined),
              title: Text(l10n.personMemoryUseInAi),
              subtitle: Text(l10n.personMemoryUseInAiSubtitle),
              value: settings.useInAi,
              onChanged: (on) => save(settings.copyWith(useInAi: on)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.lightbulb_outline_rounded),
              title: Text(l10n.personMemorySuggestTitle),
              subtitle: Text(l10n.personMemorySuggestSubtitle),
              value: settings.useInAi && settings.suggestFacts,
              onChanged: settings.useInAi
                  ? (on) => save(settings.copyWith(suggestFacts: on))
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline_rounded),
              title: Text(l10n.personMemoryEncryptedTitle),
              subtitle: Text(l10n.personMemoryEncryptedSubtitle),
              value: settings.useInAi && settings.encryptedChats,
              onChanged: settings.useInAi
                  ? (on) => save(settings.copyWith(encryptedChats: on))
                  : null,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.phone_android_rounded),
              title: Text(l10n.personMemoryStoredTitle),
              subtitle: Text(l10n.personMemoryStoredBody(people)),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: context.colors.error,
              ),
              title: Text(
                l10n.personMemoryForgetAllTitle,
                style: TextStyle(color: context.colors.error),
              ),
              enabled: people > 0,
              onTap: forgetAll,
            ),
          ],
        ),
      ),
    );
  }
}
