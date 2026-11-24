import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/auto_reply_providers.dart' show autoReplyEndpointProvider;
import '../../app/localisation.dart';
import '../../app/person_memory_providers.dart';
import '../../services/ai/conversation_context.dart' show kAiContextMessages;
import '../../services/ai/llm_budget.dart' show AiFeature;
import '../../services/ai/writing_style.dart' show kOwnStyleKey;
import '../contact/person_memory_screen.dart' show LearnedFactTile;

/// The full explanation of personal memory: the two layers, when learning
/// runs and what it sends, where it is all kept.
Future<void> showMemoryDetails(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  final messages =
      ref
          .read(autoReplyEndpointProvider)
          ?.budget
          .forFeature(AiFeature.learnFacts)
          .maxMessages ??
      kAiContextMessages;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.personMemoryDetailsTitle),
      content: SingleChildScrollView(
        child: Text(l10n.personMemoryDetails(messages)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    ),
  );
}

/// Personal memory's switches, and the one place that says what leaves the
/// device because of it.
///
/// The notes are written, and what was learned is checked, on each chat's and
/// person's memory screen; this is where the user decides whether any of it is
/// ever sent, and whether it keeps itself up to date. The screen opens with
/// one or two lines; the whole story is behind "Learn more", in
/// [showMemoryDetails].
class PersonMemorySettingsScreen extends ConsumerWidget {
  const PersonMemorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(personMemorySettingsProvider);
    final book = ref.watch(personMemoryProvider);
    final people = book.notes.values.toSet().length;
    final usualStyle = book.styleFor(const [kOwnStyleKey]);

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
                0,
              ),
              child: Text(
                l10n.personMemoryExplainer,
                key: const ValueKey('person-memory-explainer'),
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: WeftSpace.sm),
                child: TextButton.icon(
                  key: const ValueKey('person-memory-learn-more'),
                  onPressed: () => showMemoryDetails(context, ref),
                  icon: const Icon(Icons.info_outline_rounded, size: 18),
                  label: Text(l10n.personMemoryLearnMore),
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
              key: const ValueKey('person-memory-auto-learn'),
              secondary: const Icon(Icons.update_rounded),
              title: Text(l10n.personMemoryAutoTitle),
              subtitle: Text(l10n.personMemoryAutoSubtitle),
              value: settings.learnsAutomatically,
              onChanged: settings.useInAi
                  ? (on) => save(settings.copyWith(autoLearn: on))
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
            if (usualStyle != null) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: Text(l10n.personMemoryUsualStyleTitle),
                subtitle: Text(l10n.personMemoryUsualStyleHint),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
                child: LearnedFactTile(
                  key: const ValueKey('person-memory-usual-style'),
                  memory: ref.read(personMemoryProvider.notifier),
                  keys: const [kOwnStyleKey],
                  fact: usualStyle,
                ),
              ),
            ],
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
