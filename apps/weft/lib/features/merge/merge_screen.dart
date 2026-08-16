import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import '../../app/providers.dart';

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
      appBar: AppBar(title: const Text('Merged chats')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          Text(
            'When the same person reaches you on several networks, their '
            'conversations can be woven into one thread. Weft suggests '
            'matches; only you confirm them.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.xl),
          Text(
            'Suggestions',
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          if (suggestions.isEmpty)
            Text(
              'None right now. Suggestions appear as contacts with matching '
              'phone numbers, names or avatars show up across networks.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            )
          else
            for (final candidate in suggestions)
              _SuggestionCard(
                candidate: candidate,
                onMerge: () async {
                  await repository.mergeHandles(candidate.a.id, candidate.b.id);
                  if (mounted) setState(() {});
                },
                onReject: () async {
                  await repository.rejectSuggestion(
                    candidate.a.id,
                    candidate.b.id,
                  );
                  if (mounted) setState(() {});
                },
              ),
          const SizedBox(height: WeftSpace.xl),
          Text(
            'Merged',
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          if (merged.isEmpty)
            Text(
              'Nothing is merged yet.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            )
          else
            for (final contact in merged)
              _MergedCard(
                contact: contact,
                onUnmerge: (handleId) async {
                  await repository.unmergeHandle(handleId);
                  if (mounted) setState(() {});
                },
              ),
        ],
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
            Row(
              children: [
                _HandleChip(handle: candidate.a),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
                  child: Icon(
                    Icons.merge_rounded,
                    size: 18,
                    color: palette.mergedAccent,
                  ),
                ),
                _HandleChip(handle: candidate.b),
                const Spacer(),
                Text(
                  '${(candidate.score * 100).round()}%',
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
            const SizedBox(height: WeftSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  child: const Text('Not the same person'),
                ),
                const SizedBox(width: WeftSpace.sm),
                FilledButton.icon(
                  onPressed: onMerge,
                  icon: const Icon(Icons.merge_rounded, size: 18),
                  label: const Text('Merge'),
                ),
              ],
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
  final ValueChanged<String> onUnmerge;

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
                  TextButton(
                    onPressed: () => onUnmerge(handle.id),
                    child: const Text('Unmerge'),
                  ),
                ],
              ),
          ],
        ),
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
