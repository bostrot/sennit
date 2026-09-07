import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';
import '../../app/retention_providers.dart';

/// The windows a conversation may be set to erase itself after.
///
/// A short list rather than a duration picker, and the shortest is an hour on
/// purpose. Braid sweeps once a minute and deletes from a message record it
/// fills as a chat is read — machinery that is honest at the scale of hours and
/// would be quietly wrong at the scale of seconds, which is the scale a
/// "5 minutes" option would promise.
const List<Duration> kRetentionWindows = [
  Duration(hours: 1),
  Duration(hours: 8),
  Duration(hours: 24),
  Duration(days: 7),
  Duration(days: 30),
  Duration(days: 90),
];

/// How long [policy] keeps a message, in words, for a settings row's subtitle.
String retentionSummary(BuildContext context, RetentionPolicy policy) {
  if (!policy.isActive) return context.l10n.retentionOff;
  final window = retentionWindowLabel(context, policy.after);
  return switch (policy.anchor) {
    RetentionAnchor.arrival => context.l10n.retentionSummaryArrival(window),
    RetentionAnchor.read => context.l10n.retentionSummaryRead(window),
  };
}

/// One window, in words. Hours below a day, days above it — "24 hours" and
/// "1 day" are the same length and only one of them is what people say.
String retentionWindowLabel(BuildContext context, Duration window) =>
    window.inHours < 24
    ? context.l10n.retentionHours(window.inHours)
    : context.l10n.retentionDays(window.inDays);

/// Opens the picker for [chatId].
Future<void> showRetentionSheet(BuildContext context, String chatId) {
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _RetentionSheet(chatId: chatId),
  );
}

class _RetentionSheet extends ConsumerWidget {
  const _RetentionSheet({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final policy = ref.watch(retentionPoliciesProvider).forChat(chatId);
    final notifier = ref.read(retentionPoliciesProvider.notifier);

    void choose(RetentionPolicy next) => notifier.setFor(chatId, next);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: WeftSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.retentionTitle,
                    style: context.text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  // Said before anything can be chosen, because the two halves
                  // of "delete" are not equally true and a user who assumed the
                  // stronger one would be assuming it about their own privacy.
                  Text(
                    l10n.retentionExplainer,
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: WeftSpace.md),
            RadioGroup<Duration>(
              groupValue: policy.isActive ? policy.after : Duration.zero,
              onChanged: (window) {
                if (window == null) return;
                choose(
                  window == Duration.zero
                      ? RetentionPolicy.off
                      : RetentionPolicy(after: window, anchor: policy.anchor),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<Duration>(
                    value: Duration.zero,
                    title: Text(l10n.retentionOff),
                  ),
                  for (final window in kRetentionWindows)
                    RadioListTile<Duration>(
                      value: window,
                      title: Text(retentionWindowLabel(context, window)),
                    ),
                ],
              ),
            ),
            // The anchor is only a question once something is being deleted.
            if (policy.isActive) ...[
              const Divider(height: WeftSpace.lg),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
                child: Text(
                  l10n.retentionAnchorTitle,
                  style: context.text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              RadioGroup<RetentionAnchor>(
                groupValue: policy.anchor,
                onChanged: (anchor) {
                  if (anchor == null) return;
                  choose(RetentionPolicy(after: policy.after, anchor: anchor));
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<RetentionAnchor>(
                      value: RetentionAnchor.arrival,
                      title: Text(l10n.retentionAnchorArrival),
                    ),
                    RadioListTile<RetentionAnchor>(
                      value: RetentionAnchor.read,
                      title: Text(l10n.retentionAnchorRead),
                      subtitle: Text(l10n.retentionAnchorReadNote),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
