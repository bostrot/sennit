import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/intents.dart';
import '../../app/providers.dart';
import '../../app/share_providers.dart';
import '../../services/attachments/send_attachments.dart';
import '../chat/attachment_preview_sheet.dart';

/// "Share to Weft": pick the conversation the shared content goes to.
///
/// Text and files take the same route out — `send` and
/// `sendAttachment`, exactly as the composer calls them — so a share is the
/// composer's send path with the picker replaced by an intent. What is different
/// is that the files arrive as `content://` URIs the app cannot open, which is
/// why the sheet resolves them the moment it opens rather than at the tap: a
/// 200 MB video has to be turned away *before* the user has chosen who to send
/// it to, not after.
Future<void> showShareTargetSheet(BuildContext context, SharedPayload payload) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ShareTargetSheet(payload: payload),
  );
}

class _ShareTargetSheet extends ConsumerStatefulWidget {
  const _ShareTargetSheet({required this.payload});

  final SharedPayload payload;

  @override
  ConsumerState<_ShareTargetSheet> createState() => _ShareTargetSheetState();
}

class _ShareTargetSheetState extends ConsumerState<_ShareTargetSheet> {
  /// Null while the platform is still copying the shared files out of their
  /// grants — which is a real wait for a video, and the reason the state is
  /// nullable rather than an empty list that would read as "nothing shared".
  ResolvedShare? _resolved;

  /// A send in flight. The list stops taking taps: two conversations chosen in
  /// quick succession would send the batch twice, and the second tap is always
  /// a mis-tap on a sheet that is about to close.
  bool _sending = false;

  /// The user asked for the list back after arriving with a target already
  /// chosen. A Direct Share row is four small faces and a mis-tap on it is
  /// ordinary; without this the only way out is to cancel the share and start
  /// again in the other app.
  bool _pickingAnother = false;

  @override
  void initState() {
    super.initState();
    if (widget.payload.uris.isEmpty) {
      _resolved = const ResolvedShare();
    } else {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final resolved = await ref
        .read(sharedFileResolverProvider)
        .resolveSharedFiles(widget.payload);
    if (!mounted) return;
    setState(() => _resolved = resolved);
  }

  Future<void> _sendTo(String chatId, String title) async {
    final resolved = _resolved;
    if (_sending || resolved == null) return;
    setState(() => _sending = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repository = ref.read(chatRepositoryProvider);
    final text = widget.payload.text?.trim() ?? '';
    final problems = <String>[];

    // Text first: a photo shared with a caption reads the wrong way round when
    // the sentence lands after the picture.
    if (text.isNotEmpty) {
      try {
        await repository.send(chatId, text);
      } on Object catch (error) {
        debugPrint('weft: shared text failed to send: $error');
        problems.add('The message could not be sent.');
      }
    }

    problems.addAll(
      await sendAttachments(repository, chatId, resolved.sources),
    );

    final sent = (text.isNotEmpty ? 1 : 0) + resolved.sources.length;
    // A share is the strongest signal the ranker gets: the user picked this
    // conversation out of every conversation, for this content, on purpose.
    // Only when something actually went — a share that failed entirely should
    // not promote the chat it failed to reach.
    if (sent > problems.length) {
      unawaited(ref.read(shareShortcutServiceProvider).noteSend(chatId));
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          problems.isEmpty
              ? 'Sent to $title'
              : [
                  if (sent > problems.length) 'Sent to $title.',
                  ...problems,
                ].join('\n'),
        ),
      ),
    );
    navigator.pop();
  }

  /// The chat the share was already aimed at, or null to ask.
  ///
  /// Resolved against the visible chats rather than trusted: the id comes from
  /// a shortcut the launcher may have been holding for weeks, and the chat
  /// behind it can have been archived, left or unmerged since. A stale target
  /// falls back to the picker, which is what a plain share does — the one thing
  /// that must not happen is sending to an id nothing on screen accounts for.
  Chat? _preselected(List<Chat> chats) {
    final id = widget.payload.targetChatId;
    if (id == null || _pickingAnother) return null;
    return chats.firstWhereOrNull((chat) => chat.id == id);
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(visibleChatsProvider);
    final resolved = _resolved;
    final text = widget.payload.text?.trim() ?? '';
    // Nothing left to send — every shared file failed to resolve and there was
    // no text alongside them, or the files are still being read. Either way the
    // list would be a row of taps that do nothing.
    final hasContent =
        resolved != null && (text.isNotEmpty || resolved.sources.isNotEmpty);
    // Chosen outside the app — a Direct Share face, or the iOS extension's own
    // picker. The list below is then not a question that still needs asking.
    final target = _preselected(chats);

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
                  target == null ? 'Share to…' : 'Send to ${target.title}',
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.xs),
                Text(
                  _summary(text, resolved),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (resolved != null && resolved.sources.isNotEmpty)
                  _SharedFileStrip(sources: resolved.sources),
                // Rejections are shown here rather than after the tap: a file
                // too large to send is a fact about the share, not about the
                // conversation the user is about to choose.
                for (final problem in resolved?.problems ?? const <String>[])
                  Padding(
                    padding: const EdgeInsets.only(top: WeftSpace.xxs),
                    child: Text(
                      problem,
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: target != null
                ? _PreselectedTarget(
                    chat: target,
                    enabled: hasContent && !_sending,
                    onSend: () => _sendTo(target.id, target.title),
                    onChooseAnother: _sending
                        ? null
                        : () => setState(() => _pickingAnother = true),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: chats.length,
                    itemBuilder: (context, i) {
                      final chat = chats[i];
                      return ListTile(
                        enabled: hasContent && !_sending,
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
                        onTap: () => _sendTo(chat.id, chat.title),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// What is about to be sent, in one line.
  String _summary(String text, ResolvedShare? resolved) {
    if (resolved == null) {
      final count = widget.payload.uris.length;
      return count == 1 ? 'Reading 1 file…' : 'Reading $count files…';
    }

    final files = resolved.sources;
    final bytes = files.fold(0, (sum, source) => sum + source.sizeBytes);
    final fileSummary = switch (files.length) {
      0 => null,
      1 => '${files.single.basename} · ${formatAttachmentSize(bytes)}',
      _ => '${files.length} files · ${formatAttachmentSize(bytes)}',
    };

    if (text.isEmpty) return fileSummary ?? 'Nothing to send';
    final quoted = '"${_preview(text)}"';
    return fileSummary == null ? quoted : '$quoted · $fileSummary';
  }

  static String _preview(String text) =>
      text.length > 120 ? '${text.substring(0, 120)}…' : text;
}

/// The conversation the share was already aimed at, and a way out of it.
///
/// Shown instead of the target list when the intent carried a `targetChatId` —
/// an Android Direct Share face or the iOS extension's picker. The user has
/// already answered "who", so asking again is the sheet arguing with the
/// choice they just made in another app.
///
/// It is still a confirmation and not an immediate send. The strip above shows
/// *what* is about to go, which is the half a share sheet's four small faces
/// cannot show, and a share is unrecallable in a way that earns one tap.
class _PreselectedTarget extends StatelessWidget {
  const _PreselectedTarget({
    required this.chat,
    required this.enabled,
    required this.onSend,
    required this.onChooseAnother,
  });

  final Chat chat;

  /// False while the files are still being read, and after the send has begun.
  final bool enabled;

  final VoidCallback onSend;

  /// Null once a send is in flight — there is no longer another chat to choose.
  final VoidCallback? onChooseAnother;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: WeftAvatar(
            label: chat.title,
            networks: chat.networks,
            size: 40,
          ),
          title: Text(chat.title),
          subtitle: const Text('Chosen from the share sheet'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: WeftSpace.xl),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: enabled ? onSend : null,
                  icon: const Icon(Icons.send),
                  label: Text('Send to ${chat.title}'),
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onChooseAnother,
          child: const Text('Choose another chat'),
        ),
      ],
    );
  }
}

/// The shared files, as pictures rather than as a count.
///
/// A share sheet is opened from another app, so the user has already lost sight
/// of what they picked; "3 files" is not enough to catch having shared the wrong
/// screenshot. The tiles are the composer's own — [AttachmentSourceThumbnail] —
/// so a photo looks the same on the way in as it does on the way out.
class _SharedFileStrip extends StatelessWidget {
  const _SharedFileStrip({required this.sources});

  final List<AttachmentSource> sources;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.sm),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: sources.length,
          separatorBuilder: (_, _) => const SizedBox(width: WeftSpace.xs),
          itemBuilder: (context, i) {
            final source = sources[i];
            return Tooltip(
              message: source.basename,
              child: AttachmentSourceThumbnail(
                source: source,
                // The same sniff the plan will run, so the icon here and the
                // bubble that follows cannot disagree about what this is.
                kind: messageKindFor(sniffMimeType(source)),
                size: 64,
              ),
            );
          },
        ),
      ),
    );
  }
}
