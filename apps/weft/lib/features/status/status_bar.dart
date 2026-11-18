import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import '../../app/localisation.dart';

import '../../app/providers.dart';
import '../../services/status/status_feed.dart';
import 'status_viewer.dart';

/// The story ring row over the inbox: one avatar per contact with a current
/// status. Draws nothing when the account has no status broadcast, the toggle
/// is off, or nobody has posted in two days.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(statusFeedProvider).value ?? const [];
    if (entries.isEmpty) return const SizedBox.shrink();
    final headers = ref.watch(mediaHeadersProvider);

    return SizedBox(
      height: 92,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _StatusRing(
            entry: entry,
            headers: headers,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => StatusViewer(entry: entry),
              ),
            ),
            onLongPress: () async {
              final hide = await showWeftPanel<bool>(
                context: context,
                showDragHandle: true,
                builder: (context) => SafeArea(
                  child: ListTile(
                    leading: const Icon(Icons.visibility_off_outlined),
                    title: Text(
                      context.l10n.statusHideSender(entry.senderName),
                    ),
                    subtitle: Text(context.l10n.statusHideSubtitle),
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
              );
              if (hide == true) {
                ref
                    .read(hiddenStatusSendersProvider.notifier)
                    .hide(entry.senderId);
              }
            },
          );
        },
      ),
    );
  }
}

class _StatusRing extends StatelessWidget {
  const _StatusRing({
    required this.entry,
    required this.onTap,
    this.onLongPress,
    this.headers,
  });

  final StatusEntry entry;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final firstName = entry.senderName.split(' ').first;

    return WeftFocusable(
      button: true,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: context.l10n.statusLongPressHint,
      label: semanticsSentence([
        context.l10n.statusRingSemantics(entry.senderName),
        context.l10n.statusUpdateCount(entry.messages.length),
      ]),
      borderRadius: WeftRadius.allMd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The ring is the point: it is what says "unseen status" the way
            // every story UI has taught people to read it.
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    context.palette.networkColor(ChatNetwork.whatsapp),
                    context.colors.primary,
                    context.palette.networkColor(ChatNetwork.whatsapp),
                  ],
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  shape: BoxShape.circle,
                ),
                child: WeftAvatar(
                  label: entry.senderName,
                  imageUrl: entry.avatarUrl,
                  imageHeaders: headers,
                  size: 52,
                  showNetworkBadge: false,
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.xs),
            SizedBox(
              width: 64,
              child: Text(
                firstName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: context.text.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
