import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/intents.dart';
import '../../app/providers.dart';
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

    problems.addAll(await sendAttachments(repository, chatId, resolved.sources));

    final sent = (text.isNotEmpty ? 1 : 0) + resolved.sources.length;
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
            child: ListView.builder(
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
