import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_merge/weft_merge.dart';

import '../../app/providers.dart';
import '../../app/transcription_service.dart';
import '../merge/merge_screen.dart';

/// One conversation — merged across networks or not.
///
/// The timeline is driven by [MergedTimeline], so a merged chat and a plain one
/// take exactly the same code path; a plain chat is simply a merge of one.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.chatId, this.initialEventId});

  final String chatId;

  /// When set — a search result, a link — history loads until this event is
  /// present, the list jumps to it, and the bubble pulses. Landing at the
  /// bottom of the chat when the user asked for a specific message reads as
  /// the tap having done nothing.
  final String? initialEventId;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  /// Null until [_open] resolves; the timeline has to be fetched before it can
  /// be read.
  MergedTimeline? _timeline;
  MergedTimelineView _view = const MergedTimelineView(
    messages: [],
    watermark: null,
    hasMoreHistory: true,
  );
  bool _loading = false;

  /// Set when the chat cannot be opened at all; rendered instead of a timeline.
  String? _unavailable;

  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// Keys for built bubbles, so a jump can scroll to one that is on screen.
  final Map<String, GlobalKey> _messageKeys = {};

  /// Highlighted bubble, cleared shortly after the jump.
  String? _highlightEventId;

  /// Events with a transcription in flight. On-device whisper takes seconds,
  /// and without this the button looked like it did nothing at all.
  final Set<String> _transcribing = {};

  /// Already written to the search index this session.
  ///
  /// Backfill hands back the *whole* loaded list each time, so indexing it
  /// wholesale meant re-writing every row on every page — synchronous SQLite
  /// on the UI thread, growing with scroll depth. That is what made scrolling
  /// progressively jankier the further back you went.
  final Set<String> _indexed = {};

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) _open();
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    // A chat id can name something that isn't there: deep links arrive from
    // outside the app's control, and a link may be stale, be for an account
    // that has since left the room, or simply be wrong. Failing here must be a
    // rendered state, not an unhandled exception.
    try {
      final timeline = await ref
          .read(chatRepositoryProvider)
          .timelineFor(widget.chatId);
      if (!mounted) return;
      setState(() {
        _timeline = timeline;
        _unavailable = null;
        _view = timeline.view();
      });
      await _loadOlder();
      if (widget.initialEventId != null) await _jumpTo(widget.initialEventId!);
    } on ArgumentError {
      if (!mounted) return;
      setState(() => _unavailable = 'That conversation is not in your inbox.');
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _unavailable = e.message);
    }
  }

  /// Loads history until [eventId] is visible, then scrolls to and highlights
  /// it. Bounded: a very old result stops after [maxRounds] of backfill rather
  /// than paging the whole conversation on one tap.
  Future<void> _jumpTo(String eventId, {int maxRounds = 40}) async {
    final timeline = _timeline;
    if (timeline == null) return;

    var rounds = 0;
    while (!_view.messages.any((m) => m.eventId == eventId) &&
        timeline.hasMoreHistory &&
        rounds++ < maxRounds) {
      final next = await timeline.loadMoreUntilVisibleGrowth();
      if (!mounted) return;
      setState(() => _view = next);
    }

    if (!_view.messages.any((m) => m.eventId == eventId) || !mounted) return;

    setState(() => _highlightEventId = eventId);
    // Scrolls to the widget itself rather than to an index: index-anchored
    // scrolling is what made the list snap back whenever an image finished
    // loading and changed a row's height.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (var attempt = 0; attempt < 10 && mounted; attempt++) {
        final target = _messageKeys[eventId]?.currentContext;
        if (target != null && target.mounted) {
          await Scrollable.ensureVisible(
            target,
            alignment: 0.4,
            duration: WeftMotion.normal,
          );
          return;
        }
        // Not built yet: let the list extend toward it and try again.
        await _loadOlder();
        await Future<void>.delayed(WeftMotion.fast);
      }
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _highlightEventId == eventId) {
        setState(() => _highlightEventId = null);
      }
    });
  }

  Future<void> _loadOlder() async {
    final timeline = _timeline;
    if (timeline == null || _loading || !timeline.hasMoreHistory) return;
    setState(() => _loading = true);
    // Keeps pulling until the visible list actually grows: one round can lower
    // the watermark without revealing anything, and a "load older" that appears
    // to do nothing is worse than a slightly slower one.
    final next = await timeline.loadMoreUntilVisibleGrowth();
    if (!mounted) return;
    setState(() {
      _view = next;
      _loading = false;
    });
    _indexNewMessages(next.messages);
  }

  /// Indexes only messages not seen before, and after the frame so the write
  /// never lands in the middle of a scroll.
  void _indexNewMessages(List<WeftMessage> messages) {
    final fresh = messages
        .where((m) => !_indexed.contains(m.eventId))
        .toList(growable: false);
    if (fresh.isEmpty) return;

    for (final m in fresh) {
      _indexed.add(m.eventId);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final title = ref
          .read(chatsProvider)
          .value
          ?.where((c) => c.id == widget.chatId)
          .firstOrNull
          ?.title;
      ref
          .read(chatRepositoryProvider)
          .indexMessages(widget.chatId, fresh, chatTitle: title ?? '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = _unavailable;
    if (unavailable != null) return _unavailableScaffold(context, unavailable);

    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final chat = chats.where((c) => c.id == widget.chatId).firstOrNull;
    if (chat == null) {
      // Still syncing, or genuinely gone; either way there is nothing to draw
      // yet and the timeline load will settle it.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: context.colors.surfaceContainerLowest,
      appBar: _ChatAppBar(chat: chat),
      body: Column(
        children: [
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // Reversed list: "extent after" is older history.
                if (n.metrics.extentAfter < 600) _loadOlder();
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: WeftSpace.lg,
                  vertical: WeftSpace.md,
                ),
                itemCount: _view.messages.length + 1,
                itemBuilder: (context, i) {
                  if (i == _view.messages.length) return _historyFooter();
                  var message = _view.messages[i];
                  // Transcripts arrive after the event was mapped; overlay the
                  // session cache so a finished transcription shows in place.
                  final cachedTranscript = ref
                      .watch(transcriptionServiceProvider)
                      .cached(message.eventId);
                  if (cachedTranscript != null && message.transcript == null) {
                    message = message.copyWith(
                      transcript: cachedTranscript.text,
                    );
                  }
                  final older = i + 1 < _view.messages.length
                      ? _view.messages[i + 1]
                      : null;
                  return Column(
                    key: _messageKeys.putIfAbsent(
                      message.eventId,
                      GlobalKey.new,
                    ),
                    children: [
                      if (_needsDayDivider(message, older))
                        _DayDivider(date: message.timestamp),
                      _MessageBubble(
                        message: message,
                        highlighted: message.eventId == _highlightEventId,
                        transcribing: _transcribing.contains(message.eventId),
                        onTranscribe:
                            message.canTranscribe && message.transcript == null
                            ? () => _transcribe(message)
                            : null,
                        onRetranscribe:
                            message.canTranscribe && message.transcript != null
                            ? () => _retranscribe(message)
                            : null,
                        showNetwork: chat.isMerged,
                        groupedWithPrevious:
                            older != null &&
                            older.isOwn == message.isOwn &&
                            older.network == message.network &&
                            message.timestamp
                                    .difference(older.timestamp)
                                    .inMinutes <
                                5,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          _Composer(
            chat: chat,
            controller: _composer,
            onSend: _send,
            onPickNetwork: (n) => ref
                .read(chatRepositoryProvider)
                .setSendNetwork(widget.chatId, n),
          ),
        ],
      ),
    );
  }

  Widget _historyFooter() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(WeftSpace.lg),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_view.hasMoreHistory) {
      return Padding(
        padding: const EdgeInsets.all(WeftSpace.md),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadOlder,
            icon: const Icon(Icons.history_rounded, size: 16),
            label: const Text('Load older messages'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(WeftSpace.lg),
      child: Center(
        child: Text(
          'Beginning of the conversation',
          style: context.text.labelSmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _unavailableScaffold(BuildContext context, String message) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 40,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(height: WeftSpace.lg),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: WeftSpace.sm),
              Text(
                'It may have been left, or the link may be out of date.',
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _needsDayDivider(WeftMessage current, WeftMessage? older) {
    if (older == null) return true;
    return !DateUtils.isSameDay(current.timestamp, older.timestamp);
  }

  /// Auto-detection sometimes picks wrong on short clips; the fix is one
  /// long-press away, not a settings hunt.
  Future<void> _retranscribe(WeftMessage message) async {
    const languages = {
      'en': 'English',
      'de': 'Deutsch',
      'es': 'Español',
      'fr': 'Français',
      'it': 'Italiano',
      'pt': 'Português',
      'pl': 'Polski',
      'ru': 'Русский',
      'tr': 'Türkçe',
      'ar': 'العربية',
      'zh': '中文',
      'ja': '日本語',
    };
    final language = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: WeftSpace.xl),
            child: Text('Re-transcribe in…'),
          ),
          for (final entry in languages.entries)
            ListTile(
              title: Text(entry.value),
              onTap: () => Navigator.of(context).pop(entry.key),
            ),
        ],
      ),
    );
    if (language != null) await _transcribe(message, language: language);
  }

  Future<void> _transcribe(WeftMessage message, {String? language}) async {
    if (_transcribing.contains(message.eventId)) return;
    setState(() => _transcribing.add(message.eventId));

    final service = ref.read(transcriptionServiceProvider);
    try {
      await service.transcribe(message, languageOverride: language);
      if (mounted) setState(() {});
    } on Object catch (e) {
      // Deliberately Object, not Exception: a native transcription backend can
      // fail with an Error, and swallowing that made the button look inert.
      debugPrint('weft: transcription failed for ${message.eventId}: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Transcription failed: $e')));
    } finally {
      if (mounted) setState(() => _transcribing.remove(message.eventId));
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    await ref.read(chatRepositoryProvider).send(widget.chatId, text);
    if (mounted) setState(() {});
  }
}

class _ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ChatAppBar({required this.chat});

  final Chat chat;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: 64,
      backgroundColor: context.colors.surfaceContainerLowest,
      title: Row(
        children: [
          Consumer(
            builder: (context, ref, _) => WeftAvatar(
              label: chat.title,
              imageUrl: chat.avatarUrl,
              imageHeaders: ref.watch(mediaHeadersProvider),
              networks: chat.networks,
              size: 38,
            ),
          ),
          const SizedBox(width: WeftSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chat.title,
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (chat.isMerged)
                  Text(
                    'Merged · ${chat.networks.map((n) => n.label).join(', ')}',
                    style: context.text.labelSmall?.copyWith(
                      color: context.palette.mergedAccent,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    chat.networks.firstOrNull?.label ?? '',
                    style: context.text.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: chat.isMerged ? 'Manage merge' : 'Merge with…',
          icon: const Icon(Icons.merge_rounded),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const MergeScreen())),
        ),
        IconButton(
          tooltip: 'Search in conversation',
          icon: const Icon(Icons.search_rounded),
          onPressed: () {},
        ),
      ],
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WeftSpace.lg),
      child: Row(
        children: [
          Expanded(child: Divider(color: context.palette.divider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
            child: Text(
              DateFormat.MMMd().format(date),
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Divider(color: context.palette.divider)),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showNetwork,
    required this.groupedWithPrevious,
    this.highlighted = false,
    this.transcribing = false,
    this.onTranscribe,
    this.onRetranscribe,
  });

  /// Pulse marking the message a jump landed on.
  final bool highlighted;

  /// A transcription is running for this message.
  final bool transcribing;

  final WeftMessage message;

  /// Set for an untranscribed voice message when an endpoint is configured.
  final VoidCallback? onTranscribe;

  /// Long-press action on an existing transcript.
  final VoidCallback? onRetranscribe;

  /// In a merged chat every bubble states which network it came from —
  /// otherwise the merged view loses information the user needs.
  final bool showNetwork;

  final bool groupedWithPrevious;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final own = message.isOwn;
    final accent = palette.networkColor(message.network);

    return AnimatedContainer(
      duration: WeftMotion.slow,
      curve: WeftMotion.standard,
      decoration: BoxDecoration(
        color: highlighted
            ? context.colors.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: WeftRadius.allMd,
      ),
      padding: EdgeInsets.only(top: groupedWithPrevious ? 2 : WeftSpace.sm),
      child: Row(
        mainAxisAlignment: own
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.md,
                vertical: WeftSpace.sm,
              ),
              decoration: BoxDecoration(
                color: own ? palette.ownBubble : palette.peerBubble,
                borderRadius: BorderRadius.only(
                  topLeft: WeftRadius.lg,
                  topRight: WeftRadius.lg,
                  bottomLeft: own ? WeftRadius.lg : WeftRadius.xs,
                  bottomRight: own ? WeftRadius.xs : WeftRadius.lg,
                ),
                // A merged chat marks each bubble's origin with a hairline in
                // the network's colour — readable without stealing attention.
                border: showNetwork
                    ? Border(left: BorderSide(color: accent, width: 3))
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showNetwork && !groupedWithPrevious) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NetworkGlyph(network: message.network, size: 12),
                        const SizedBox(width: WeftSpace.xs),
                        Text(
                          message.network.label,
                          style: context.text.labelSmall?.copyWith(
                            color: own
                                ? palette.ownBubbleText.withValues(alpha: 0.8)
                                : accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                  ],
                  if (message.attachmentUrl != null &&
                      (message.kind == MessageKind.image ||
                          message.kind == MessageKind.video ||
                          message.kind == MessageKind.sticker))
                    _AttachmentContent(message: message)
                  else if (message.kind == MessageKind.voice)
                    _VoiceContent(
                      message: message,
                      own: own,
                      transcribing: transcribing,
                      onTranscribe: onTranscribe,
                      onRetranscribe: onRetranscribe,
                    )
                  else
                    Text(
                      message.body,
                      style: context.text.bodyMedium?.copyWith(
                        color: own
                            ? palette.ownBubbleText
                            : palette.peerBubbleText,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        DateFormat.Hm().format(message.timestamp),
                        style: context.text.labelSmall?.copyWith(
                          fontSize: 10,
                          color:
                              (own
                                      ? palette.ownBubbleText
                                      : palette.peerBubbleText)
                                  .withValues(alpha: 0.6),
                        ),
                      ),
                      if (own) ...[
                        const SizedBox(width: 3),
                        Icon(
                          Icons.done_all_rounded,
                          size: 13,
                          color: palette.ownBubbleText.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An image, video poster or sticker, loaded through the repository so an
/// encrypted attachment is decrypted locally before display.
///
/// Without this an image message rendered as its `body` — often just the
/// filename, or "Forwarded" for a forwarded picture — which looked like the
/// picture had been lost.
class _AttachmentContent extends ConsumerStatefulWidget {
  const _AttachmentContent({required this.message});

  final WeftMessage message;

  @override
  ConsumerState<_AttachmentContent> createState() => _AttachmentContentState();
}

class _AttachmentContentState extends ConsumerState<_AttachmentContent> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(widget.message.roomId, widget.message.eventId);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.message.body;
    // Bridges label a forwarded picture "Forwarded" in the body; showing that
    // under the image is noise, not a caption.
    final showCaption =
        caption.isNotEmpty &&
        caption.toLowerCase() != 'forwarded' &&
        !caption.startsWith('image.') &&
        !caption.startsWith('video.');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: WeftRadius.allSm,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, minWidth: 140),
            child: switch ((_bytes, _failed)) {
              (final Uint8List bytes, _) => Image.memory(
                bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(context, broken: true),
              ),
              (_, true) => _placeholder(context, broken: true),
              _ => _placeholder(context, broken: false),
            },
          ),
        ),
        if (widget.message.kind == MessageKind.video)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_circle_outline_rounded, size: 14),
                const SizedBox(width: WeftSpace.xs),
                Text('Video', style: context.text.labelSmall),
              ],
            ),
          ),
        if (showCaption)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Text(caption, style: context.text.bodyMedium),
          ),
      ],
    );
  }

  Widget _placeholder(BuildContext context, {required bool broken}) {
    return Container(
      width: 180,
      height: 120,
      color: context.colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: broken
          ? Icon(
              Icons.broken_image_outlined,
              color: context.colors.onSurfaceVariant,
            )
          : const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

/// Voice message with a waveform placeholder and, when available, the
/// transcript produced by the user's own STT endpoint.
class _VoiceContent extends StatelessWidget {
  const _VoiceContent({
    required this.message,
    required this.own,
    this.transcribing = false,
    this.onTranscribe,
    this.onRetranscribe,
  });

  final WeftMessage message;
  final bool own;
  final bool transcribing;
  final VoidCallback? onTranscribe;
  final VoidCallback? onRetranscribe;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow_rounded, size: 22, color: onBubble),
            const SizedBox(width: WeftSpace.sm),
            // Waveform takes the space the bubble actually has rather than a
            // fixed 22 bars: previously the bubble stretched to full width
            // while the bars and timestamp stopped around the middle.
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final barCount = ((constraints.maxWidth - 60) / 5.5)
                      .floor()
                      .clamp(8, 48);
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Deterministic pseudo-waveform: real amplitude data arrives with
                      // the recorder in M9.
                      for (var i = 0; i < barCount; i++)
                        Container(
                          width: 2.5,
                          height:
                              6 +
                              ((message.eventId.hashCode >> (i % 28)) & 0x0F)
                                  .toDouble(),
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: onBubble.withValues(alpha: 0.55),
                            borderRadius: WeftRadius.pill,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            Text(
              _duration(message.durationMs),
              style: context.text.labelSmall?.copyWith(
                color: onBubble.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
        if (transcribing)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                Text(
                  'Transcribing…',
                  style: context.text.labelSmall?.copyWith(
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          )
        else if (message.transcript == null && onTranscribe != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onTranscribe,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              icon: Icon(
                Icons.graphic_eq_rounded,
                size: 14,
                color: onBubble.withValues(alpha: 0.8),
              ),
              label: Text(
                'Transcribe',
                style: context.text.labelSmall?.copyWith(
                  color: onBubble.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        if (message.transcript != null) ...[
          const SizedBox(height: WeftSpace.sm),
          GestureDetector(
            onLongPress: onRetranscribe,
            child: Container(
              padding: const EdgeInsets.all(WeftSpace.sm),
              decoration: BoxDecoration(
                color: onBubble.withValues(alpha: 0.08),
                borderRadius: WeftRadius.allSm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 13,
                    color: onBubble.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: WeftSpace.xs),
                  Flexible(
                    child: Text(
                      message.transcript!,
                      style: context.text.bodySmall?.copyWith(
                        color: onBubble.withValues(alpha: 0.9),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _duration(int? ms) {
    if (ms == null) return '';
    final total = Duration(milliseconds: ms);
    final m = total.inMinutes;
    final s = total.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// The composer, including the send-network chip.
///
/// In a merged chat the chip is the answer to "which app does this actually go
/// out on?" — always visible, never a hidden default.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.chat,
    required this.controller,
    required this.onSend,
    required this.onPickNetwork,
  });

  final Chat chat;
  final TextEditingController controller;
  final VoidCallback onSend;
  final ValueChanged<ChatNetwork> onPickNetwork;

  @override
  Widget build(BuildContext context) {
    final sendNetwork = chat.sendNetwork;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        WeftSpace.md,
        WeftSpace.sm,
        WeftSpace.md,
        WeftSpace.md,
      ),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.palette.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (chat.isMerged && sendNetwork != null) ...[
              _SendNetworkChip(
                chat: chat,
                current: sendNetwork,
                onPick: onPickNetwork,
              ),
              const SizedBox(width: WeftSpace.sm),
            ],
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Attach',
              onPressed: () {},
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: sendNetwork == null
                      ? 'Message'
                      : 'Message via ${sendNetwork.label}',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send_rounded, size: 18),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}

class _SendNetworkChip extends StatelessWidget {
  const _SendNetworkChip({
    required this.chat,
    required this.current,
    required this.onPick,
  });

  final Chat chat;
  final ChatNetwork current;
  final ValueChanged<ChatNetwork> onPick;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.networkColor(current);

    return PopupMenuButton<ChatNetwork>(
      tooltip: 'Send via…',
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final n in chat.networks)
          PopupMenuItem(
            value: n,
            child: Row(
              children: [
                NetworkGlyph(network: n, size: 20),
                const SizedBox(width: WeftSpace.md),
                Text(n.label),
                if (n == current) ...[
                  const Spacer(),
                  Icon(Icons.check_rounded, size: 16, color: accent),
                ],
              ],
            ),
          ),
      ],
      child: AnimatedContainer(
        duration: WeftMotion.fast,
        curve: WeftMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.sm,
          vertical: WeftSpace.sm,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.15),
          borderRadius: WeftRadius.pill,
          border: Border.all(color: accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NetworkGlyph(network: current, size: 18),
            const SizedBox(width: WeftSpace.xs),
            Icon(Icons.expand_more_rounded, size: 16, color: accent),
          ],
        ),
      ),
    );
  }
}
