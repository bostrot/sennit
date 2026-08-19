import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart' show RoomTrust;
import 'package:weft_merge/weft_merge.dart';
import 'package:weft_richtext/weft_richtext.dart';

import '../../app/a11y.dart';
import '../../app/call_providers.dart';
import '../../app/intents.dart';
import '../../app/providers.dart';
import '../../app/share_providers.dart';
import '../../app/transcription_service.dart';
import '../../data/chat_repository.dart';
import '../../services/attachments/attachment_picker.dart';
import '../../services/attachments/send_attachments.dart';
import '../auth/verification_screen.dart';
import '../call/start_call.dart';
import '../merge/merge_screen.dart';
import '../share/share_target_sheet.dart';
import 'attachment_bubble.dart';
import 'attachment_preview_sheet.dart';
import 'attachment_source_sheet.dart';
import 'edit_history_sheet.dart';
import 'emoji_picker_sheet.dart';
import 'link_preview_card.dart';
import 'media_viewer.dart';
import 'message_actions_sheet.dart';
import 'reaction_bar.dart';
import 'reply_chip.dart';
import 'rich_text_view.dart';
import 'send_network_chip.dart';
import 'sms_composer_bar.dart';
import 'unverified_devices_banner.dart';

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

  /// What the composer is answering or rewriting, or null for a plain message.
  ComposerContext? _composerContext;

  /// Events with a transcription in flight. On-device whisper takes seconds,
  /// and without this the button looked like it did nothing at all.
  final Set<String> _transcribing = {};

  /// The newest message a screen reader has already been told about.
  ///
  /// Set without announcing on the first populated frame — the opening load is
  /// the whole visible history, and announcing it would read the conversation
  /// aloud from the top the moment it opens.
  String? _announcedEventId;

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
    // Cleared per conversation, not per widget: on a two-pane desktop the same
    // [State] serves every chat the user clicks through, and without this the
    // newest message of the chat they just *opened* would be announced as one
    // that had arrived.
    _announcedEventId = null;
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

  /// Announces a message that arrived while the conversation was open.
  ///
  /// A live region on the list itself would be wrong twice over: the list's
  /// label is the whole timeline, and backfilling older history changes it just
  /// as much as a new message does. What a reader needs is the one sentence
  /// that the sighted user got for free by watching a bubble appear, so this
  /// announces only when the *newest* message changed and it is not the user's
  /// own — a send the user just made is not news to them.
  ///
  /// `_view.messages` is newest-first, matching the reversed list.
  void _announceIncoming(List<WeftMessage> messages, {required bool merged}) {
    final newest = messages.firstOrNull;
    if (newest == null) return;

    final previous = _announcedEventId;
    _announcedEventId = newest.eventId;
    if (previous == null || previous == newest.eventId || newest.isOwn) return;

    final body = newest.kind == MessageKind.text && !newest.redacted
        ? messageDocument(newest).plainText
        : messageKindLabel(newest.kind);
    announce(
      context,
      semanticsSentence([
        'New message from ${newest.senderName}',
        if (merged) 'on ${newest.network.label}',
        body,
      ]),
    );
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

  /// Re-reads the timeline after something changed underneath it.
  ///
  /// A reaction, an edit and a redaction are all timeline events, and the
  /// sources re-derive their messages when the timeline they wrap moves — but
  /// nothing in this view was listening, so until now the model held a reaction
  /// the screen did not show. That is the worst of the failure modes available
  /// here, because nothing looks broken.
  ///
  /// Called after every relation action rather than on a subscription: the
  /// action is the moment the user is looking, and a `MergedTimeline` has no
  /// change stream of its own to listen to.
  void _refresh() {
    final timeline = _timeline;
    if (timeline == null || !mounted) return;
    setState(() => _view = timeline.view());
  }

  /// Runs a repository action, reporting a refusal rather than throwing it.
  ///
  /// Every relation action can fail for a reason the user can do nothing about
  /// — the target event has aged out of the room's history, the homeserver said
  /// no — and an unhandled exception out of a tap handler takes the whole
  /// timeline with it. Deliberately [Object]: `react` and friends throw
  /// [StateError], but the transport below them can fail with an Error.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      debugPrint('weft: message action failed: $error');
      _showMessage('That did not go through.');
      return;
    }
    _refresh();
  }

  /// The reply chip's target, resolved across every loaded leg.
  ///
  /// [WeftMessage.replyPreview] is filled by the mapper only for a target in
  /// the reply's *own* room, and a null there means "unresolved", not "not a
  /// reply". In a merged conversation the answer may well be on another leg, so
  /// this is where the whole merged candidate set is searched — and where an
  /// unpaginated target finally becomes a stub rather than nothing.
  ReplyPreview? _replyPreviewFor(WeftMessage message) {
    if (message.replyToEventId == null) return null;
    return message.replyPreview ??
        resolveReplyTarget(
          replyToEventId: message.replyToEventId,
          loaded: _view.messages,
        );
  }

  /// A sender id as a name, from whoever is already on screen.
  ///
  /// The reaction tally carries handles, not display names, and there is no
  /// per-user lookup on the repository. The loaded timeline is the cheapest
  /// honest source: anybody whose reaction is visible has almost always spoken
  /// in the conversation too. An id nobody has spoken under is shown as itself
  /// rather than as an invented name.
  String _nameFor(String senderId) {
    for (final message in _view.messages) {
      if (message.senderId == senderId && message.senderName.isNotEmpty) {
        return message.senderName;
      }
    }
    return senderId;
  }

  Future<void> _openActions(WeftMessage message) async {
    final choice = await showMessageActionsSheet(
      context,
      message: message,
      canTranscribe: message.canTranscribe,
      hasTranscript: message.transcript != null,
    );
    if (choice == null || !mounted) return;

    switch (choice.action) {
      case MessageAction.reply:
        setState(() => _composerContext = ComposerContext.reply(message));
      case MessageAction.edit:
        _startEdit(message);
      case MessageAction.react:
        await _react(message, choice.emoji!);
      case MessageAction.moreReactions:
        await _pickReaction(message);
      case MessageAction.copy:
        await _copy(message);
      case MessageAction.forward:
        // The share sheet the rest of the app already uses: forwarding is
        // choosing a conversation and sending, which is exactly what it does.
        if (mounted) {
          await showShareTargetSheet(
            context,
            SharedPayload(text: messageDocument(message).plainText),
          );
        }
      case MessageAction.delete:
        await _delete(message);
      case MessageAction.transcribe:
        await _transcribe(message);
      case MessageAction.retranscribe:
        await _retranscribe(message);
    }
  }

  void _startEdit(WeftMessage message) {
    // The fallback goes: an edit of a reply must not put the quoted context
    // back into the words the user is about to re-send.
    _composer.text = stripReplyFallback(message.body);
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    setState(() => _composerContext = ComposerContext.edit(message));
  }

  /// The plain-text projection, never the markup.
  ///
  /// Copying a formatted message has to put "meet at six" on the clipboard, not
  /// `<p>meet at <b>six</b></p>` — the same projection the search index and the
  /// notification bodies take.
  Future<void> _copy(WeftMessage message) async {
    final text = messageDocument(message).plainText;
    await Clipboard.setData(ClipboardData(text: text));
    _showMessage('Copied to the clipboard.');
  }

  Future<void> _delete(WeftMessage message) async {
    if (!await confirmRedaction(context)) return;
    if (!mounted) return;
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .redact(widget.chatId, message.eventId),
    );
  }

  Future<void> _pickReaction(WeftMessage message) async {
    final key = await showEmojiPickerSheet(context);
    if (key == null || !mounted) return;
    await _react(message, key);
  }

  /// Adds the reader's reaction, or takes it back when it is already there.
  ///
  /// The toggle is decided from the tally rather than from a second server
  /// round trip, and un-reacting redacts [ReactionTally.localEventId] — the
  /// annotation event itself, which aggregation carries precisely because there
  /// is no recovering it from the chip afterwards.
  Future<void> _react(WeftMessage message, String key) async {
    final normalised = normaliseReactionKey(key);
    final existing = message.reactions
        .where((t) => t.key == normalised && t.byLocalUser)
        .firstOrNull;
    if (existing != null) {
      await _toggleReaction(message, existing);
      return;
    }

    final repository = ref.read(chatRepositoryProvider);
    ref.read(reactionRecentsProvider.notifier).note(key);
    await _run(() => repository.react(widget.chatId, message.eventId, key));
  }

  Future<void> _toggleReaction(WeftMessage message, ReactionTally tally) async {
    final repository = ref.read(chatRepositoryProvider);
    final localEventId = tally.localEventId;

    if (tally.byLocalUser && localEventId != null) {
      await _run(() => repository.unreact(widget.chatId, localEventId));
      return;
    }
    ref.read(reactionRecentsProvider.notifier).note(tally.key);
    await _run(
      () => repository.react(widget.chatId, message.eventId, tally.key),
    );
  }

  /// Opens a link a message carried.
  ///
  /// [label] is what the sender wrote as the anchor text, and the reason this
  /// is not a bare `launchUrl`. The parser guarantees the *scheme* is safe; it
  /// cannot guarantee the sender was honest, and an anchor reading
  /// `bank.example` that points at `bank.example.evil.test` is the oldest trick
  /// there is. Formatted bodies arrive from bridged networks and from anyone
  /// who can get an event into a room, so a label that names a different host
  /// asks first. A label that is not pretending to be a url — the ordinary case
  /// — opens straight away.
  Future<void> _openLink(String url, String label) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    if (linkLabelMisleads(label, uri) && !await _confirmLink(url)) return;

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showMessage('Nothing on this device opens that link.');
    } on Object catch (error) {
      // Deliberately Object: a platform with no handler registered throws out
      // of the method channel rather than answering false.
      debugPrint('weft: could not open $url: $error');
      _showMessage('Nothing on this device opens that link.');
    }
  }

  Future<bool> _confirmLink(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open this link?'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The text of this link does not match where it goes.'),
            const SizedBox(height: WeftSpace.sm),
            SelectableText(url, style: context.text.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _openMention(RichMention mention) {
    switch (mention.kind) {
      case MentionKind.roomAlias:
      case MentionKind.roomId:
        final chat = ref
            .read(chatRepositoryProvider)
            .chatForRoom(mention.targetId);
        if (chat == null) {
          _showMessage('${mention.targetId} is not in your inbox.');
          return;
        }
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ChatView(chatId: chat.id)),
          ),
        );
      case MentionKind.user:
      case MentionKind.roomWide:
        // Opening a DM from a mention needs the start-chat flow, which is the
        // same thing `OpenUserLink` is waiting on in the router. Naming the
        // person is the honest interim answer.
        _showMessage(mention.targetId);
    }
  }

  /// Opens the existing verification flow from the banner.
  ///
  /// No device id: the banner fires when *this* account has an unverified
  /// device, and asking every other device is what lets whichever one the user
  /// can reach answer. The trust is recomputed on return rather than assumed —
  /// the user may well have pressed "Not now".
  Future<void> _verifyOwnDevice() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            VerificationScreen(onContinue: () => Navigator.of(context).pop()),
      ),
    );
    if (mounted) ref.invalidate(chatTrustProvider(widget.chatId));
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = _unavailable;
    if (unavailable != null) return _unavailableScaffold(context, unavailable);

    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final chat = chats.where((c) => c.id == widget.chatId).firstOrNull;
    // Uploads sit *below* the settled messages in a reversed list, which is the
    // bottom of the thread: a photo the user just picked belongs where the next
    // message would go, not above the history they were reading.
    final uploads =
        ref.watch(chatUploadsProvider(widget.chatId)).value ??
        const <UploadTask>[];
    if (chat == null) {
      // Still syncing, or genuinely gone; either way there is nothing to draw
      // yet and the timeline load will settle it.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // After the frame rather than during it: an announcement is a platform call
    // and a build is not the place to make one, and the message being announced
    // has to be on screen by the time a reader goes looking for it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _announceIncoming(_view.messages, merged: chat.isMerged);
    });

    return Scaffold(
      backgroundColor: context.colors.surfaceContainerLowest,
      appBar: _ChatAppBar(chat: chat),
      body: Column(
        children: [
          UnverifiedDevicesBanner(
            // Absent while the key store is being read, which is the honest
            // default: a warning that flashes in and out on every open would
            // be trained away within a day.
            trust:
                ref.watch(chatTrustProvider(widget.chatId)).value ??
                RoomTrust.none,
            onVerify: _verifyOwnDevice,
          ),
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
                itemCount: uploads.length + _view.messages.length + 1,
                itemBuilder: (context, index) {
                  if (index < uploads.length) {
                    // Reversed: index 0 is the newest, and the newest upload is
                    // the last one enqueued.
                    return _uploadBubble(
                      chat,
                      uploads[uploads.length - 1 - index],
                    );
                  }
                  final i = index - uploads.length;
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
                        replyPreview: _replyPreviewFor(message),
                        highlighted: message.eventId == _highlightEventId,
                        transcribing: _transcribing.contains(message.eventId),
                        onOpen: rendersAsAttachment(message)
                            ? () => _openMedia(message)
                            : null,
                        onTranscribe:
                            message.canTranscribe && message.transcript == null
                            ? () => _transcribe(message)
                            : null,
                        onRetranscribe:
                            message.canTranscribe && message.transcript != null
                            ? () => _retranscribe(message)
                            : null,
                        onActions: () => _openActions(message),
                        onJumpToReply: (eventId) => _jumpTo(eventId),
                        onToggleReaction: (tally) =>
                            _toggleReaction(message, tally),
                        onAddReaction: () => _pickReaction(message),
                        onShowReactionSenders: (tally) =>
                            showReactionSendersSheet(
                              context,
                              tally: tally,
                              nameFor: _nameFor,
                            ),
                        onShowEditHistory: () =>
                            showEditHistorySheet(context, message: message),
                        onTapLink: _openLink,
                        onTapMention: _openMention,
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
            composing: _composerContext,
            onCancelContext: _cancelComposerContext,
            onSend: _send,
            onAttach: () => _attach(chat),
            onPickNetwork: _pickNetwork,
          ),
        ],
      ),
    );
  }

  /// One in-flight upload, wearing the same bubble chrome a sent message wears.
  ///
  /// Built from [uploadEchoMessage] rather than from a hand-made widget so the
  /// thread does not visibly change shape at the moment the event lands: the
  /// network hairline, the grouping padding and the timestamp row are literally
  /// the ones the settled bubble will use.
  Widget _uploadBubble(Chat chat, UploadTask task) {
    final network =
        chat.sources
            .where((s) => s.roomId == task.roomId)
            .firstOrNull
            ?.network ??
        chat.networks.firstOrNull ??
        ChatNetwork.matrix;
    final repository = ref.read(chatRepositoryProvider);

    return _MessageBubble(
      message: uploadEchoMessage(
        task,
        network: network,
        senderId: _localSenderId,
      ),
      content: UploadProgressBubble(
        task: task,
        own: true,
        onCancel: () => repository.cancelUpload(task.id),
        onRetry: () => repository.retryUpload(task.id),
      ),
      showNetwork: chat.isMerged,
      groupedWithPrevious: false,
    );
  }

  Widget _historyFooter() {
    if (_loading) {
      // A live region: the spinner replaces the "Load older messages" button
      // the reader just pressed, and without it the button simply disappears
      // from under them with nothing said.
      return Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading older messages',
            excludeSemantics: true,
            child: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
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
        child: Semantics(
          liveRegion: true,
          child: Text(
            'Beginning of the conversation',
            style: context.text.labelSmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
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
    // On-device whisper takes seconds, and the only sign it started is a
    // spinner replacing a button inside a bubble the reader may not be on.
    // Both ends are announced for the same reason the button exists at all.
    announce(context, 'Transcribing…');

    final service = ref.read(transcriptionServiceProvider);
    try {
      final transcript = await service.transcribe(
        message,
        languageOverride: language,
      );
      if (!mounted) return;
      setState(() {});
      announce(context, 'Transcript: ${transcript.text}');
    } on Object catch (e) {
      // Deliberately Object, not Exception: a native transcription backend can
      // fail with an Error, and swallowing that made the button look inert.
      debugPrint('weft: transcription failed for ${message.eventId}: $e');
      if (!mounted) return;
      _showMessage('Transcription failed: $e');
    } finally {
      if (mounted) setState(() => _transcribing.remove(message.eventId));
    }
  }

  /// Sends, replies or saves an edit, depending on what the composer is in.
  ///
  /// The context is cleared *before* the round trip, not after: the composer
  /// has already been emptied, and a bar still saying "Replying to Anna" over
  /// an empty field is a state the user cannot get out of by typing.
  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final composing = _composerContext;
    _composer.clear();
    setState(() => _composerContext = null);

    final repository = ref.read(chatRepositoryProvider);
    switch (composing?.mode) {
      case ComposerMode.edit:
        await _run(
          () => repository.editMessage(
            widget.chatId,
            composing!.message.eventId,
            text,
          ),
        );
        // Deliberately no `_noteSend`: an edit is not a message sent to this
        // conversation, and counting it would push a chat up the share ranker
        // for a typo the user fixed.
        return;
      case ComposerMode.reply:
        await _run(
          () => repository.sendReply(
            widget.chatId,
            text,
            replyToEventId: composing!.message.eventId,
          ),
        );
      case null:
        await _run(() => repository.send(widget.chatId, text));
    }
    _noteSend();
  }

  void _cancelComposerContext() {
    // Cancelling an edit empties the field, because what is in it is the
    // *message's* words — put there by [_startEdit], not typed. Leaving them
    // behind would arm the composer with a duplicate of a message that is
    // already in the thread. Cancelling a reply keeps the text, which the user
    // did type and may still want to send.
    if (_composerContext?.mode == ComposerMode.edit) _composer.clear();
    setState(() => _composerContext = null);
  }

  /// Tells the share-target ranker this conversation was written to.
  ///
  /// The echo moves the chat up on recency by itself; what only this call site
  /// knows is that the *user* sent it, which is the frequency term — the
  /// difference between the conversations that made a noise and the ones they
  /// talk in. Not awaited: nothing on screen waits for a launcher.
  void _noteSend() =>
      unawaited(ref.read(shareShortcutServiceProvider).noteSend(widget.chatId));

  /// Opens [message] full screen, in the company of the rest of the
  /// conversation's media.
  ///
  /// The gallery is built from the *loaded* timeline rather than fetched: it is
  /// the pictures the user has already scrolled past, which is what "swipe to
  /// the previous photo" means to them. Anything the viewer can only show on its
  /// own — a PDF, a song — opens as a gallery of one rather than being dropped
  /// between two photographs.
  void _openMedia(WeftMessage message) {
    final gallery = viewableMedia(_view.messages);
    final index = gallery.indexWhere(
      (m) => m.eventId == message.eventId && m.roomId == message.roomId,
    );
    unawaited(
      openMediaViewer(
        context,
        items: index < 0 ? [message] : gallery,
        initialIndex: index < 0 ? 0 : index,
      ),
    );
  }

  void _pickNetwork(ChatNetwork network) {
    unawaited(
      ref.read(chatRepositoryProvider).setSendNetwork(widget.chatId, network),
    );
  }

  /// Pick → confirm → send, in that order.
  ///
  /// Three separate steps because each can be abandoned and none of them should
  /// leave anything behind: dismissing the source sheet picks nothing, cancelling
  /// the preview sends nothing, and removing every file from the preview is the
  /// same as cancelling it.
  Future<void> _attach(Chat chat) async {
    final picker = ref.read(attachmentPickerProvider);
    final source = await showAttachmentSourceSheet(context, picker);
    if (source == null || !mounted) return;

    final List<AttachmentSource> picked;
    try {
      picked = await picker.pick(source);
    } on Object catch (error) {
      // Deliberately Object: a picker is a method channel, and a platform that
      // denies the photo permission throws rather than returning nothing.
      debugPrint('weft: attachment picker failed: $error');
      _showMessage('Could not open the picker.');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final confirmed = await showAttachmentPreviewSheet(
      context,
      chat: chat,
      sources: picked,
      onPickNetwork: _pickNetwork,
    );
    if (confirmed == null || confirmed.isEmpty || !mounted) return;

    await _sendAttachments(confirmed);
  }

  /// Sends each confirmed file, reporting the ones that will never be sent.
  ///
  /// The loop itself is [sendAttachments], shared with the share sheet — the
  /// two paths differ only in where the files came from.
  Future<void> _sendAttachments(List<AttachmentSource> sources) async {
    final problems = await sendAttachments(
      ref.read(chatRepositoryProvider),
      widget.chatId,
      sources,
    );
    if (problems.length < sources.length) _noteSend();
    if (problems.isNotEmpty) _showMessage(problems.join('\n'));
  }

  /// Reports something to the user, in both channels.
  ///
  /// [showWeftMessage] rather than a bare `SnackBar`: every string that reaches
  /// here is the only report of an operation that failed, and a bar that sets
  /// no live region and vanishes on a timer is not a report a screen-reader
  /// user ever receives.
  void _showMessage(String message) {
    if (!mounted) return;
    showWeftMessage(context, message);
  }
}

/// Sender id on an upload's stand-in message.
///
/// Never rendered: the echo is always the user's own, so the bubble draws it on
/// the own side with no sender line. It exists because [WeftMessage] requires an
/// id, and inventing a plausible-looking Matrix user id here would be a value
/// something downstream could one day believe.
const String _localSenderId = 'local:self';

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
      // The title is one thing — who this conversation is with, and on what —
      // so it is one node, marked as the screen's heading. Three nodes read in
      // isolation ("Anna", "Merged · WhatsApp, Signal", and an avatar reading
      // "AK") is the same failure the inbox row had.
      title: MergeSemantics(
        child: Semantics(
          header: true,
          child: Row(
            children: [
              Consumer(
                builder: (context, ref, _) => WeftAvatar(
                  label: chat.title,
                  imageUrl: chat.avatarUrl,
                  imageHeaders: ref.watch(mediaHeadersProvider),
                  networks: chat.networks,
                  size: 38,
                  // The lines beside it already say all of this.
                  semanticsLabel: '',
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
                        'Merged · '
                        '${chat.networks.map((n) => n.label).join(', ')}',
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
        ),
      ),
      actions: [
        // Disabled rather than hidden, with the reason in its tooltip: a
        // conversation with no Matrix-native leg cannot carry a call, and a
        // button that quietly disappeared for bridged chats would read as Weft
        // having lost the feature.
        Consumer(
          builder: (context, ref, _) {
            final availability = ref.watch(callAvailabilityProvider(chat.id));
            final target = availability.target;
            return IconButton(
              tooltip: availability.message,
              icon: const Icon(Icons.call_rounded),
              onPressed: target == null
                  ? null
                  : () => startCall(context, ref, target),
            );
          },
        ),
        IconButton(
          tooltip: chat.isMerged ? 'Manage merge' : 'Merge with…',
          icon: const Icon(Icons.merge_rounded),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const MergeScreen())),
        ),
        // Disabled rather than inert. `onPressed: () {}` is a button that
        // announces itself as enabled, takes a tap and does nothing — which a
        // reader has no way to distinguish from a tap that failed. There is no
        // in-conversation search yet; the tooltip says so and the button says
        // so by being unavailable. Search across every chat is on the inbox.
        IconButton(
          tooltip: 'Search in conversation — not available yet',
          icon: const Icon(Icons.search_rounded),
          onPressed: null,
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
    // A heading, which is what it is: the two rules either side are the visual
    // form of "a new section starts here", and marking it as a header is what
    // lets a reader jump between days instead of scrolling through them.
    return Semantics(
      header: true,
      container: true,
      excludeSemantics: true,
      label: 'Messages from ${DateFormat.MMMd().format(date)}',
      child: Padding(
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
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showNetwork,
    required this.groupedWithPrevious,
    this.replyPreview,
    this.content,
    this.highlighted = false,
    this.transcribing = false,
    this.onOpen,
    this.onTranscribe,
    this.onRetranscribe,
    this.onActions,
    this.onJumpToReply,
    this.onToggleReaction,
    this.onAddReaction,
    this.onShowReactionSenders,
    this.onShowEditHistory,
    this.onTapLink,
    this.onTapMention,
  });

  /// Opens the attachment full screen. Null for a message that has none.
  final VoidCallback? onOpen;

  /// What this message is answering, already resolved across every leg of a
  /// merged chat. Null when it is not a reply.
  final ReplyPreview? replyPreview;

  /// Long-press: the action sheet.
  final VoidCallback? onActions;

  /// Reply-chip tap. Takes the target's event id rather than closing over it,
  /// so the bubble does not need to know how the list scrolls.
  final ValueChanged<String>? onJumpToReply;

  final ValueChanged<ReactionTally>? onToggleReaction;
  final VoidCallback? onAddReaction;
  final ValueChanged<ReactionTally>? onShowReactionSenders;

  /// Tap-through on the "edited" marker.
  final VoidCallback? onShowEditHistory;

  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

  /// Replaces the bubble's own content.
  ///
  /// Set only for an in-flight upload, which is driven by an `UploadTask` rather
  /// than by the stand-in message supplying the chrome around it.
  final Widget? content;

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

  /// Who said this, and on what — the two facts a reader cannot get from the
  /// words, because the side of the screen a bubble sits on and the hairline
  /// down its edge are both purely visual.
  ///
  /// Deliberately *not* the whole bubble as one node. The body carries links
  /// and mention pills that have to stay reachable as controls, and merging
  /// them into a sentence would trade six findings for a worse one.
  String get _senderLabel => semanticsSentence([
    message.isOwn ? 'You' : message.senderName,
    if (showNetwork) 'on ${message.network.label}',
  ]);

  /// The metadata row as one clause: when it was sent, and — for the user's own
  /// messages — how far it got. Currently three nodes, one of which is an
  /// unlabelled 13dp tick.
  String get _metaLabel => semanticsSentence([
    'Sent ${DateFormat.Hm().format(message.timestamp)}',
    if (message.isOwn) deliveryStateLabel(message.deliveryState),
  ]);

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
      child: Column(
        crossAxisAlignment: own
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: own
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Semantics(
                  // The bubble is a group, not a control: it holds a body whose
                  // links and mention pills must stay individually reachable.
                  // What the group adds is the header a sighted user reads off
                  // the bubble's position and colour — who, and on what leg.
                  container: true,
                  label: _senderLabel,
                  onLongPress: onActions,
                  onLongPressHint: onActions == null ? null : 'show actions',
                  child: GestureDetector(
                    // Long-press rather than a visible affordance: a button per
                    // bubble is six controls per screen the reader has to look
                    // past to read the conversation.
                    onLongPress: onActions,
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
                        // A merged chat marks each bubble's origin with a
                        // hairline in the network's colour — readable without
                        // stealing attention.
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
                                NetworkGlyph(
                                  network: message.network,
                                  size: 12,
                                ),
                                const SizedBox(width: WeftSpace.xs),
                                Text(
                                  message.network.label,
                                  style: context.text.labelSmall?.copyWith(
                                    // The label is text and owes 4.5:1; the
                                    // hairline beside it is a graphic and owes
                                    // 3:1, which is why they are two tokens.
                                    color: own
                                        ? palette.mutedOnBubble(
                                            true,
                                            alpha: 0.8,
                                          )
                                        : palette.networkTextColor(
                                            message.network,
                                          ),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                          ],
                          // Inside the bubble, above everything: the quote is
                          // part of what this message says, not chrome around it.
                          if (replyPreview != null)
                            ReplyChip(
                              preview: replyPreview!,
                              own: own,
                              onTap: onJumpToReply == null
                                  ? null
                                  : () => onJumpToReply!(replyPreview!.eventId),
                            ),
                          if (content != null)
                            content!
                          // Before the attachment and voice branches, not after:
                          // a redacted event keeps whatever `attachmentUrl` it
                          // was mapped with, and a deleted photo that still drew
                          // its own bubble would be a deletion that did nothing.
                          else if (message.redacted)
                            Text(
                              'Message deleted',
                              style: context.text.bodyMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: palette.mutedOnBubble(own),
                              ),
                            )
                          else if (rendersAsAttachment(message))
                            AttachmentBubble(
                              message: message,
                              own: own,
                              onOpen: onOpen,
                              transcribing: transcribing,
                              onTranscribe: onTranscribe,
                              onRetranscribe: onRetranscribe,
                            )
                          else if (message.kind == MessageKind.voice)
                            _VoiceContent(
                              message: message,
                              own: own,
                              transcribing: transcribing,
                              onTranscribe: onTranscribe,
                              onRetranscribe: onRetranscribe,
                            )
                          else
                            RichTextView.message(
                              message: message,
                              baseStyle:
                                  context.text.bodyMedium?.copyWith(
                                    color: own
                                        ? palette.ownBubbleText
                                        : palette.peerBubbleText,
                                  ) ??
                                  TextStyle(
                                    color: own
                                        ? palette.ownBubbleText
                                        : palette.peerBubbleText,
                                  ),
                              // Links and mention pills take the network's colour
                              // on a peer bubble and the bubble's own ink on the
                              // user's, where the accent would be invisible
                              // against the primary fill it is derived from.
                              accent: own ? palette.ownBubbleText : accent,
                              onTapLink: onTapLink,
                              onTapMention: onTapMention,
                            ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (message.isEdited && !message.redacted) ...[
                                _EditedMarker(
                                  message: message,
                                  own: own,
                                  onTap: onShowEditHistory,
                                ),
                                const SizedBox(width: WeftSpace.xs),
                              ],
                              // The time and the tick are one clause — "Sent
                              // 14:32, Read" — rather than a bare number followed
                              // by an unlabelled 13dp glyph whose only difference
                              // between delivered and read is its colour.
                              Semantics(
                                container: true,
                                excludeSemantics: true,
                                label: _metaLabel,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      DateFormat.Hm().format(message.timestamp),
                                      style: context.text.labelSmall?.copyWith(
                                        fontSize: 10,
                                        color: palette.mutedOnBubble(own),
                                      ),
                                    ),
                                    if (own) ...[
                                      const SizedBox(width: 3),
                                      Tooltip(
                                        message: deliveryStateLabel(
                                          message.deliveryState,
                                        ),
                                        excludeFromSemantics: true,
                                        child: Icon(
                                          // An upload still on the wire, and one
                                          // that failed, must not wear the same
                                          // double tick a delivered message does.
                                          switch (message.deliveryState) {
                                            DeliveryState.sending =>
                                              Icons.schedule_rounded,
                                            DeliveryState.failed =>
                                              Icons.error_outline_rounded,
                                            _ => Icons.done_all_rounded,
                                          },
                                          size: 13,
                                          color:
                                              message.deliveryState ==
                                                  DeliveryState.failed
                                              ? context.colors.error
                                              : palette.mutedOnBubble(
                                                  true,
                                                  alpha: 0.7,
                                                ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // Under the bubble rather than inside it, for the same reason the
          // reaction bar is: the card is *about* the message, not part of what
          // the sender said. It draws nothing at all unless the reader has
          // switched previews on and the homeserver had an answer — see
          // [LinkPreviewCard].
          if (content == null)
            LinkPreviewCard(message: message, own: own, onTapUrl: onTapLink),
          // Outside the bubble's decoration, deliberately. A chip on the own
          // bubble's primary fill would have to fight it for contrast, and the
          // bar belongs to the message rather than being part of what it says.
          if (message.reactions.isNotEmpty && onToggleReaction != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.xs),
              child: ReactionBar(
                tallies: message.reactions,
                own: own,
                onToggle: onToggleReaction!,
                onShowSenders: onShowReactionSenders,
                onAdd: onAddReaction,
              ),
            ),
        ],
      ),
    );
  }
}

/// The "edited" marker, and the way into the history behind it.
///
/// A marker with nothing behind it asks the reader to take the sender's word
/// for what a message used to say, which in a conversation that can be
/// screenshotted is exactly the wrong default. The tap target is the whole
/// marker rather than an added icon: the row it sits in is already the busiest
/// eight pixels of the bubble.
class _EditedMarker extends StatelessWidget {
  const _EditedMarker({required this.message, required this.own, this.onTap});

  final WeftMessage message;
  final bool own;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = palette.mutedOnBubble(own);
    final editedAt = message.editedAt;
    // Only when there is history to show. A message mapped outside an open
    // timeline knows it was edited and has no versions to open — offering the
    // sheet there would open an empty one, so there is nothing to announce as
    // a button either.
    final openable = message.editHistory.isNotEmpty && onTap != null;

    return Semantics(
      button: openable,
      // Its own node, not a fragment merged into the words above it: it is a
      // control, and a control that shares a node with the message body cannot
      // be reached separately from it.
      container: true,
      excludeSemantics: true,
      onTap: openable ? onTap : null,
      label: semanticsSentence([
        editedAt == null
            ? 'Edited'
            : 'Edited at ${DateFormat.Hm().format(editedAt)}',
        if (openable) 'show edit history',
      ]),
      child: Tooltip(
        message: openable ? 'Show edit history' : 'This message was edited',
        excludeFromSemantics: true,
        child: GestureDetector(
          onTap: openable ? onTap : null,
          child: Text(
            editedAt == null
                ? 'edited'
                : 'edited ${DateFormat.Hm().format(editedAt)}',
            style: context.text.labelSmall?.copyWith(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: ink,
              decoration: message.editHistory.isEmpty
                  ? null
                  : TextDecoration.underline,
              decorationColor: ink,
            ),
          ),
        ),
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
    final bubble = own ? palette.ownBubble : palette.peerBubble;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // One node for the recording itself: a reader was told the duration and
        // never that this was a voice message at all, because "0:42" beside a
        // row of coloured bars is the entire visual signal. Whether there is a
        // transcript belongs here too — it is the difference between a message
        // this reader can read and one they cannot.
        Semantics(
          container: true,
          excludeSemantics: true,
          label: semanticsSentence([
            'Voice message',
            formatMediaDuration(message.durationMs),
            if (transcribing)
              'transcribing'
            else if (message.transcript != null)
              'transcript below'
            else if (onTranscribe != null)
              'no transcript yet',
          ]),
          child: Row(
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
                              // A waveform bar is a graphic, not text, so 3:1
                              // rather than 4.5:1 — it can stay fainter than the
                              // duration beside it and still be seen.
                              color: WeftContrast.dim(
                                onBubble,
                                bubble,
                                alpha: 0.55,
                                minRatio: WeftContrast.uiComponent,
                              ),
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
                formatMediaDuration(message.durationMs) ?? '',
                style: context.text.labelSmall?.copyWith(
                  color: palette.muted(onBubble, bubble, alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
        AttachmentTranscript(
          message: message,
          own: own,
          transcribing: transcribing,
          onTranscribe: onTranscribe,
          onRetranscribe: onRetranscribe,
        ),
      ],
    );
  }
}

/// Whether the composer is writing a new message, answering one, or rewriting
/// one.
enum ComposerMode { reply, edit }

/// What the composer is pointed at.
///
/// One nullable value rather than two flags and a message, so "replying" and
/// "editing" cannot both be true — a composer in both states at once would have
/// to choose a send path at the moment the user pressed the button, which is
/// the worst possible time to be guessing.
@immutable
class ComposerContext {
  const ComposerContext.reply(this.message) : mode = ComposerMode.reply;
  const ComposerContext.edit(this.message) : mode = ComposerMode.edit;

  final ComposerMode mode;
  final WeftMessage message;
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
    required this.onAttach,
    required this.onPickNetwork,
    this.composing,
    this.onCancelContext,
  });

  final Chat chat;
  final TextEditingController controller;

  /// The message being answered or rewritten, or null for an ordinary send.
  ///
  /// Named `composing` rather than `context`, which is what it is: a widget
  /// field called `context` shadows the `BuildContext` every design-token
  /// extension hangs off, and `context.palette` would stop compiling for a
  /// reason nobody reading the call site could see.
  final ComposerContext? composing;

  /// Dismisses [context]. Required whenever one is set: a mode the user cannot
  /// leave is a trap, and the back gesture belongs to the route.
  final VoidCallback? onCancelContext;

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final ValueChanged<ChatNetwork> onPickNetwork;

  /// What the next send will do, in one phrase.
  ///
  /// Used as both the hint and the accessible name, so the two cannot drift and
  /// the mode survives the first keystroke.
  String _fieldLabel(ChatNetwork? sendNetwork) => switch (composing?.mode) {
    ComposerMode.edit => 'Edit message',
    ComposerMode.reply => 'Reply',
    null =>
      sendNetwork == null ? 'Message' : 'Message via ${sendNetwork.label}',
  };

  @override
  Widget build(BuildContext context) {
    final sendNetwork = chat.sendNetwork;
    final editing = composing?.mode == ComposerMode.edit;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        WeftSpace.md,
        WeftSpace.sm,
        WeftSpace.md,
        WeftSpace.md,
      ),
      decoration: BoxDecoration(
        color: context.colors.surface,
        // `border`, not `divider`: this bounds the composer rather than
        // separating two blocks of text, and a low-vision user relies on it to
        // find where the message goes.
        border: Border(top: BorderSide(color: context.palette.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (composing != null)
              _ComposerContextBar(
                composing: composing!,
                onCancel: onCancelContext,
              ),
            // Rebuilt per keystroke rather than with the whole view: the
            // segment count is a live number, and the encryption warning has to
            // be on screen before the first character is typed, not after.
            if (sendNetwork == ChatNetwork.sms)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) =>
                    SmsComposerBar(body: value.text),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (chat.isMerged && sendNetwork != null) ...[
                  SendNetworkChip(
                    chat: chat,
                    current: sendNetwork,
                    onPick: onPickNetwork,
                  ),
                  const SizedBox(width: WeftSpace.sm),
                ],
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: 'Attach',
                  // An edit replaces one event's text. There is no such thing
                  // as editing a message into a photo, so the picker is closed
                  // rather than left to fail somewhere further down.
                  onPressed: editing ? null : onAttach,
                ),
                Expanded(
                  // The hint is the *only* place the composer's mode is stated
                  // in words, and a hint disappears the moment a character is
                  // typed — so a reader who started replying and then typed had
                  // no way left to find out that the next send is a reply. The
                  // label says it whether the field is empty or not.
                  child: Semantics(
                    label: _fieldLabel(sendNetwork),
                    textField: true,
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      autofocus: composing != null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        hintText: _fieldLabel(sendNetwork),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                IconButton.filled(
                  onPressed: onSend,
                  icon: Icon(
                    editing ? Icons.check_rounded : Icons.send_rounded,
                    size: 18,
                  ),
                  tooltip: editing ? 'Save edit' : 'Send',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar above the input saying what the next send will do.
///
/// It states the mode in words as well as with an icon. "Replying to Anna" and
/// "Editing your message" produce very different events, and a composer that
/// only differed by a small glyph would let a reply be sent as a replacement of
/// something the user last touched ten minutes ago.
class _ComposerContextBar extends StatelessWidget {
  const _ComposerContextBar({required this.composing, this.onCancel});

  final ComposerContext composing;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final editing = composing.mode == ComposerMode.edit;
    final message = composing.message;
    final preview = ReplyPreview(
      eventId: message.eventId,
      roomId: message.roomId,
      senderId: message.senderId,
      senderName: editing ? 'Editing your message' : message.senderName,
      kind: message.kind,
      network: message.network,
      body: replyPreviewText(message),
      redacted: message.redacted,
    );

    // A live region, because this bar *appearing* is the whole event: it is put
    // there by a long-press three bubbles up the thread, and a reader who was
    // reading the timeline gets no other sign that the composer has changed
    // what it does.
    return Semantics(
      liveRegion: true,
      container: true,
      label: editing
          ? 'Editing your message'
          : 'Replying to ${message.senderName}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: WeftSpace.xs),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                editing ? Icons.edit_outlined : Icons.reply_rounded,
                size: 16,
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            Expanded(
              child: ReplyChip(preview: preview, own: false, compact: true),
            ),
            IconButton(
              tooltip: editing ? 'Cancel edit' : 'Cancel reply',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}
