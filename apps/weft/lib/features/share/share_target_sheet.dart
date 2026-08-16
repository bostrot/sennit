import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/intents.dart';
import '../../app/providers.dart';

/// "Share to Weft": pick the conversation the shared content goes to.
///
/// Text is sent immediately on selection. Files are acknowledged but not yet
/// uploadable — media upload lands with the attachment pipeline — and the
/// sheet says so instead of silently dropping them.
Future<void> showShareTargetSheet(BuildContext context, SharedPayload payload) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ShareTargetSheet(payload: payload),
  );
}

class _ShareTargetSheet extends ConsumerWidget {
  const _ShareTargetSheet({required this.payload});

  final SharedPayload payload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(visibleChatsProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.xl,
              vertical: WeftSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Share to…',
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.xs),
                Text(
                  payload.text != null
                      ? '"${_preview(payload.text!)}"'
                      : '${payload.uris.length} file(s)',
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (payload.uris.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: WeftSpace.xs),
                    child: Text(
                      'File upload is not wired up yet — only shared text is '
                      'sent for now.',
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: chats.length,
              itemBuilder: (context, i) {
                final chat = chats[i];
                return ListTile(
                  leading: WeftAvatar(
                    label: chat.title,
                    networks: chat.networks,
                    size: 40,
                  ),
                  title: Text(chat.title),
                  subtitle: chat.lastMessage == null
                      ? null
                      : Text(
                          DateFormat.yMMMd().format(
                            chat.lastMessage!.timestamp,
                          ),
                        ),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(context);
                    final text = payload.text;
                    if (text != null && text.trim().isNotEmpty) {
                      await ref
                          .read(chatRepositoryProvider)
                          .send(chat.id, text);
                      messenger.showSnackBar(
                        SnackBar(content: Text('Sent to ${chat.title}')),
                      );
                    }
                    navigator.pop();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _preview(String text) =>
      text.length > 120 ? '${text.substring(0, 120)}…' : text;
}
