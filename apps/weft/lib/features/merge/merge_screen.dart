import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../data/chat_repository.dart';

/// Merge management: what the scorer proposes, and what is already merged.
///
/// Every suggestion shows its evidence — "Same phone number", "Very similar
/// name" — because a merge the user can't understand is a merge they won't
/// trust. Nothing merges without a tap; dismissals and unmerges are sticky.
class MergeScreen extends ConsumerStatefulWidget {
  const MergeScreen({super.key});

  @override
  ConsumerState<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends ConsumerState<MergeScreen> {
  /// Applies [action] and then says what it did — out loud *and* on screen.
  ///
  /// The card disappearing used to be the whole visible report, which is no
  /// report at all when the action throws (nothing announced, nothing moved,
  /// nothing explained) and a thin one even when it works. Now every decision
  /// ends in a sentence: the outcome as a snack bar, or the failure as one.
  Future<void> _decide(Future<void> Function() action, String outcome) async {
    try {
      await action();
    } on Object catch (error) {
      debugPrint('weft: merge decision failed: $error');
      if (mounted) {
        showWeftMessage(context, context.l10n.mergeFailed('$error'));
      }
      return;
    }
    if (!mounted) return;
    setState(() {});
    showWeftMessage(context, outcome);
  }

  /// Two pickers and a confirmation: the user names both sides themselves.
  Future<void> _manualMerge(ChatRepository repository) async {
    final handles =
        repository.identityGraph
            .contacts()
            .expand((contact) => contact.handles)
            .toList()
          ..sort(
            (a, b) => handleLabel(
              a,
            ).toLowerCase().compareTo(handleLabel(b).toLowerCase()),
          );
    if (handles.length < 2) {
      showWeftMessage(context, context.l10n.mergeNothingToMerge);
      return;
    }

    final first = await _pickHandle('Merge which conversation?', handles);
    if (first == null || !mounted) return;

    final firstContact = repository.identityGraph.contactIdOf(first.id);
    final second = await _pickHandle('Merge ${handleLabel(first)} with…', [
      // Everything not already the same person.
      for (final handle in handles)
        if (repository.identityGraph.contactIdOf(handle.id) != firstContact)
          handle,
    ]);
    if (second == null || !mounted) return;

    await _decide(
      () => repository.mergeHandles(first.id, second.id),
      'Merged ${handleLabel(first)} with ${handleLabel(second)}. '
      'They are now one conversation.',
    );
  }

  Future<NetworkHandle?> _pickHandle(
    String title,
    List<NetworkHandle> handles,
  ) {
    return showWeftPanel<NetworkHandle>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _HandlePickerSheet(title: title, handles: handles),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(chatRepositoryProvider);
    // Watching chats keeps this screen current as merges rebuild the inbox.
    ref.watch(chatsProvider);

    final suggestions = repository.identityGraph.suggestions();
    final merged = repository.identityGraph
        .contacts()
        .where((c) => c.isMerged)
        .toList();

    return Scaffold(
      // Suggestions need a matching signal, and people rename themselves per
      // app — "Mum" on WhatsApp is "Petra" on Signal, and no scorer bridges
      // that. Manual merge is the user asserting what only they know.
      appBar: WeftAppBar(
        title: Text(context.l10n.commonMergedChats),
        actions: [
          // In the toolbar on a desktop, floating on a phone — see the note in
          // `bridges_screen.dart`.
          if (context.isDesktop)
            TextButton.icon(
              onPressed: () => _manualMerge(repository),
              icon: const Icon(Icons.call_merge_rounded, size: 16),
              label: Text(context.l10n.mergeTwoChats),
            ),
        ],
      ),
      floatingActionButton: context.isDesktop
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _manualMerge(repository),
              icon: const Icon(Icons.call_merge_rounded),
              label: Text(context.l10n.mergeTwoChats),
            ),
      body: WeftReadingPane(
        child: ListView(
          // Bottom is the clearance rather than [WeftSpace.lg] like the other
          // three sides: the extended FAB below floats over this list, and at
          // 16 it covered the last merged contact's *Unmerge* button outright.
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            WeftSpace.lg,
            WeftSpace.lg,
            WeftSpace.fabClearance,
          ),
          children: [
            Text(
              context.l10n.mergeIntro,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.xl),
            _SectionTitle(context.l10n.mergeSuggestions),
            const SizedBox(height: WeftSpace.sm),
            if (suggestions.isEmpty)
              Text(
                context.l10n.mergeNoSuggestions,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else
              for (final candidate in suggestions)
                _SuggestionCard(
                  candidate: candidate,
                  onMerge: () => _decide(
                    () =>
                        repository.mergeHandles(candidate.a.id, candidate.b.id),
                    'Merged ${handleLabel(candidate.a)} with '
                    '${handleLabel(candidate.b)}. They are now one conversation.',
                  ),
                  onReject: () => _decide(
                    () => repository.rejectSuggestion(
                      candidate.a.id,
                      candidate.b.id,
                    ),
                    '${handleLabel(candidate.a)} and ${handleLabel(candidate.b)} '
                    'kept separate. This suggestion will not come back.',
                  ),
                ),
            const SizedBox(height: WeftSpace.xl),
            _SectionTitle(context.l10n.mergeMergedSection),
            const SizedBox(height: WeftSpace.sm),
            if (merged.isEmpty)
              Text(
                context.l10n.mergeNothingMerged,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else
              for (final contact in merged)
                _MergedCard(
                  contact: contact,
                  onUnmerge: (handle) => _decide(
                    () => repository.unmergeHandle(handle.id),
                    '${handleLabel(handle)} is a separate conversation again.',
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.candidate,
    required this.onMerge,
    required this.onReject,
  });

  final MergeCandidate candidate;
  final VoidCallback onMerge;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The proposal is one statement, not seven nodes. Two handles, a
            // percentage and a row of evidence chips read in isolation are the
            // parts of a sentence with the sentence taken out — and the two
            // buttons below act on the whole of it.
            Semantics(
              container: true,
              excludeSemantics: true,
              label: _proposalLabel(candidate),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _HandleChip(handle: candidate.a),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: WeftSpace.sm,
                        ),
                        child: Icon(
                          Icons.merge_rounded,
                          size: 18,
                          color: palette.mergedAccent,
                        ),
                      ),
                      _HandleChip(handle: candidate.b),
                      const Spacer(),
                      Text(
                        context.l10n.mergeScore(
                          (candidate.score * 100).round(),
                        ),
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  // The evidence, verbatim from the scorer.
                  Wrap(
                    spacing: WeftSpace.xs,
                    runSpacing: WeftSpace.xs,
                    children: [
                      for (final signal in candidate.signals)
                        Chip(
                          label: Text(signal.explanation),
                          labelStyle: context.text.labelSmall,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide.none,
                          backgroundColor: context.colors.surfaceContainerHigh,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: WeftSpace.sm),
            // `Wrap`, not `Row` — the same 2.0× finding as the message request
            // card's action row, and the same shape of consequence: *Merge* was
            // the button that went off the edge, so a suggestion could be
            // rejected at large text but not accepted.
            // `double.infinity` is load-bearing, not defensive. A `Wrap` sizes
            // to its widest run, and `WrapAlignment.end` distributes *free*
            // space — so a shrink-wrapped `Wrap` has none to distribute and the
            // buttons stop at the widest run's edge instead of the card's. The
            // `Row` this replaced filled the card for free, and dropping the
            // width is how swapping one for the other silently moves a button
            // 85 points in from the trailing margin at 1.0×. Caught in the
            // re-walk, not in review.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: WeftSpace.sm,
                runSpacing: WeftSpace.xs,
                children: [
                  // Both buttons name whom they act on and what happens. On a
                  // screen with four suggestions, four buttons reading "Merge"
                  // are four ways to merge the wrong two people.
                  NamedButton(
                    label: context.l10n.mergeRejectSemantics(
                      handleLabel(candidate.a),
                      handleLabel(candidate.b),
                    ),
                    onPressed: onReject,
                    child: TextButton(
                      onPressed: onReject,
                      child: Text(context.l10n.mergeNotSamePerson),
                    ),
                  ),
                  NamedButton(
                    label: context.l10n.mergeAcceptSemantics(
                      handleLabel(candidate.a),
                      handleLabel(candidate.b),
                    ),
                    onPressed: onMerge,
                    child: FilledButton.icon(
                      onPressed: onMerge,
                      icon: const Icon(Icons.merge_rounded, size: 18),
                      label: Text(context.l10n.mergeAccept),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MergedCard extends StatelessWidget {
  const _MergedCard({required this.contact, required this.onUnmerge});

  final UnifiedContact contact;
  final ValueChanged<NetworkHandle> onUnmerge;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Consumer(
                  builder: (context, ref, _) => WeftAvatar(
                    label: contact.displayName,
                    imageUrl: contact.avatarUrl,
                    imageHeaders: ref.watch(mediaHeadersProvider),
                    networks: contact.networks,
                    size: 40,
                  ),
                ),
                const SizedBox(width: WeftSpace.md),
                Expanded(
                  child: Text(
                    contact.displayName,
                    style: context.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.sm),
            for (final handle in contact.handles)
              Row(
                children: [
                  NetworkGlyph(network: handle.network, size: 18),
                  const SizedBox(width: WeftSpace.sm),
                  Expanded(
                    child: Text(
                      handle.displayName ?? handle.remoteId,
                      style: context.text.bodySmall,
                    ),
                  ),
                  // Same problem as Merge, one row down: a contact with three
                  // legs has three buttons reading "Unmerge".
                  NamedButton(
                    label: context.l10n.mergeUnmergeSemantics(
                      handleLabel(handle),
                      contact.displayName,
                    ),
                    onPressed: () => onUnmerge(handle),
                    child: TextButton(
                      onPressed: () => onUnmerge(handle),
                      child: Text(context.l10n.mergeUnmerge),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A person and the network they are that person on.
///
/// Every label on this screen needs it, and the two halves are never useful
/// apart: "Anna" appears twice in a suggestion, and it is the network that says
/// which Anna is which.
@visibleForTesting
String handleLabel(NetworkHandle handle) =>
    '${handle.displayName ?? handle.remoteId} on ${handle.network.label}';

/// The suggestion as one sentence: who, how sure, and on what evidence.
String _proposalLabel(MergeCandidate candidate) => semanticsSentence([
  '${handleLabel(candidate.a)} and ${handleLabel(candidate.b)} may be the '
      'same person',
  '${(candidate.score * 100).round()}% confident',
  if (candidate.signals.isNotEmpty)
    'because ${candidate.signals.map((s) => s.explanation).join(', ')}',
]);

/// A section title that a screen reader can jump between.
///
/// "Suggestions" and "Merged" divide this screen into its two halves, and a
/// reader navigating by heading found neither.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        title,
        style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _HandleChip extends StatelessWidget {
  const _HandleChip({required this.handle});

  final NetworkHandle handle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NetworkGlyph(network: handle.network, size: 20),
        const SizedBox(width: WeftSpace.xs),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Text(
            handle.displayName ?? handle.remoteId,
            style: context.text.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Searchable list of every known handle, one tap to choose.
class _HandlePickerSheet extends StatefulWidget {
  const _HandlePickerSheet({required this.title, required this.handles});

  final String title;
  final List<NetworkHandle> handles;

  @override
  State<_HandlePickerSheet> createState() => _HandlePickerSheetState();
}

class _HandlePickerSheetState extends State<_HandlePickerSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? widget.handles
        : [
            for (final handle in widget.handles)
              if (handleLabel(handle).toLowerCase().contains(query) ||
                  handle.remoteId.toLowerCase().contains(query))
                handle,
          ];

    return WeftDraggableSheet(
      initialSize: 0.7,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.sm),
                WeftLabelledField(
                  label: context.l10n.mergeSearchLabel,
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: context.l10n.mergeSearchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final handle = visible[index];
                return ListTile(
                  leading: NetworkGlyph(
                    network: handle.network,
                    size: 28,
                    semanticsLabel: '',
                  ),
                  title: Text(handleLabel(handle)),
                  subtitle: Text(
                    context.l10n.handleOnNetwork(
                      handle.network.label,
                      handle.remoteId,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context).pop(handle),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
