import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../chat/chat_view.dart';

/// The row that leads into the requests screen, or nothing when there are none.
///
/// A row in the inbox list rather than a badge in the app bar, because the one
/// thing it has to survive is being ignored: a request nobody opens is a
/// message nobody reads, and a small dot in the corner of a toolbar is exactly
/// what a person scrolling their inbox does not see. It sits above the
/// conversations and disappears the moment the last request is answered.
class RequestsEntry extends ConsumerWidget {
  const RequestsEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(pendingRequestsProvider);
    if (requests.isEmpty) return const SizedBox.shrink();

    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.lg,
        vertical: WeftSpace.xs,
      ),
      child: WeftFocusable(
        button: true,
        // One sentence: what the control is, and how many are waiting. Read as
        // two nodes it arrives as a heading followed by a bare number.
        label: semanticsSentence([
          l10n.requestsTitle,
          l10n.requestsWaiting(requests.length),
        ]),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const RequestsScreen())),
        borderRadius: WeftRadius.allMd,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.md,
            vertical: WeftSpace.sm,
          ),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHigh,
            borderRadius: WeftRadius.allMd,
          ),
          child: Row(
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                size: 20,
                color: context.colors.primary,
              ),
              const SizedBox(width: WeftSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.requestsTitle,
                      style: context.text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      l10n.requestsWaiting(requests.length),
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every conversation waiting to be accepted, with the three answers.
///
/// A screen rather than a section inside the inbox, and the reason is the
/// reading. These conversations are from people the user does not know; putting
/// them among the ones they do — even under a heading — means a stranger's
/// message sits three pixels from a friend's and is answered with the same
/// reflex. Somewhere separate is what makes "who is this?" the first question
/// rather than an afterthought.
class RequestsScreen extends ConsumerWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(pendingRequestsProvider);
    final l10n = context.l10n;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.requestsTitle)),
      body: requests.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(WeftSpace.xl),
                child: Text(
                  l10n.requestsEmpty,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: WeftSpace.sm),
              itemCount: requests.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      WeftSpace.lg,
                      WeftSpace.sm,
                      WeftSpace.lg,
                      WeftSpace.md,
                    ),
                    child: Text(
                      l10n.requestsExplainer,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return _RequestCard(chat: requests[i - 1]);
              },
            ),
    );
  }
}

/// One request: who, on what, what they said, and the three answers.
class _RequestCard extends ConsumerWidget {
  const _RequestCard({required this.chat});

  final Chat chat;

  Future<void> _answer(
    BuildContext context,
    WidgetRef ref,
    ChatRequestAction action,
  ) async {
    final l10n = context.l10n;
    final title = chat.title;
    final state = await ref
        .read(chatRepositoryProvider)
        .answerChatRequest(chat.id, action);
    if (!context.mounted) return;

    // Announced rather than left to the row vanishing. Decline and Block look
    // identical from the outside — the row goes — and which one happened is the
    // difference between "they can write again" and "they cannot".
    showWeftMessage(context, switch (state) {
      ChatRequestState.accepted => l10n.requestAccepted(title),
      ChatRequestState.declined => l10n.requestDeclined(title),
      ChatRequestState.blocked => l10n.requestBlocked(title),
      _ => l10n.chatActionFailed,
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final preview = chat.lastMessage?.body.trim();

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: WeftSpace.lg,
        vertical: WeftSpace.xs,
      ),
      color: context.colors.surfaceContainerHigh,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                WeftAvatar(
                  label: chat.title,
                  imageUrl: chat.avatarUrl,
                  imageHeaders: ref.watch(mediaHeadersProvider),
                  networks: chat.networks,
                  size: 40,
                  semanticsLabel: '',
                ),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          l10n.requestFrom(
                            chat.networks.firstOrNull?.label ??
                                ChatNetwork.unknown.label,
                          ),
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (preview != null && preview.isNotEmpty) ...[
              const SizedBox(height: WeftSpace.sm),
              // Two lines and no more. The preview is here so the user can tell
              // a person from a spammer without opening anything — which is the
              // point of a request — and a message long enough to argue its own
              // case is exactly what a spammer sends.
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodyMedium,
              ),
            ],
            const SizedBox(height: WeftSpace.sm),
            // A `Wrap` rather than a `Row` with a `Spacer`, which is what this
            // was until the Phase 10 walk photographed it at 2.0× text: four
            // buttons whose labels have all doubled in width do not fit a phone,
            // and a `Row` answers that by painting stripes over the last one.
            // *Accept* — the only one of the four that is not undoable and the
            // only one most people ever press — was the button that went under
            // them, clipped and untappable.
            //
            // The two groups stay two groups. `spaceBetween` puts *Read* at the
            // start and the three verdicts at the end exactly as the `Spacer`
            // did while they fit, and drops the verdicts onto their own line
            // rather than off the card when they do not.
            // `spaceBetween` needs a full-width box to have any space to
            // distribute — a `Wrap` sizes to its widest run, and a shrink-wrapped
            // one would sit the verdicts flush against *Read* instead of at the
            // card's trailing edge, which is what happened to the same swap in
            // `merge_screen.dart`. Here the `Column` above is
            // `CrossAxisAlignment.stretch`, so the width already arrives tight
            // and no `SizedBox` is needed. Written down because the two cards
            // look identical and only one of them needs the wrapper.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: WeftSpace.xs,
              children: [
                // Reading it does not accept it, and does not send a receipt:
                // `markRead` and `setTyping` both refuse a pending request. The
                // preview here is one line; the conversation may be several.
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatView(chatId: chat.id, preview: true),
                    ),
                  ),
                  child: Text(l10n.requestRead),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: WeftSpace.xs,
                  runSpacing: WeftSpace.xs,
                  children: [
                    TextButton(
                      onPressed: () =>
                          _answer(context, ref, ChatRequestAction.block),
                      style: TextButton.styleFrom(
                        foregroundColor: context.colors.error,
                      ),
                      child: Text(l10n.requestBlock),
                    ),
                    TextButton(
                      onPressed: () =>
                          _answer(context, ref, ChatRequestAction.decline),
                      child: Text(l10n.requestDecline),
                    ),
                    FilledButton(
                      onPressed: () =>
                          _answer(context, ref, ChatRequestAction.accept),
                      child: Text(l10n.requestAccept),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
