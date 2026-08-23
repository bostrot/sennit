import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_call/weft_call.dart' show CallBlocked, CallBlocker;
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
import '../../app/shortcuts.dart';
import '../../app/transcription_service.dart';
import '../../data/chat_repository.dart';
import '../../services/attachments/attachment_picker.dart';
import '../../services/attachments/send_attachments.dart';
import '../../services/audio/voice_player.dart';
import '../../services/audio/voice_recorder.dart';
import '../../services/schedule/scheduled_actions.dart';
import '../settings/integrations_screen.dart';
import 'paperless_picker_sheet.dart';
import '../auth/verification_screen.dart';
import '../call/external_call.dart';
import '../call/start_call.dart';
import '../contact/contact_profile.dart';
import '../merge/merge_screen.dart';
import '../share/share_target_sheet.dart';
import '../../services/agenda/device_calendar.dart';
import 'agenda_chip.dart';
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
import 'voice_recording_bar.dart';
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

  /// The composer's focus, held here rather than left to the `TextField` for
  /// one reason: `FocusComposerIntent` is pressed while the user is in the
  /// inbox list, which on a two-pane window is a *sibling* of this widget. The
  /// registry in `shortcuts.dart` is how the shortcut reaches across.
  final _composerFocus = FocusNode(debugLabel: 'Braid composer');

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

  /// The conversation's *current* id, which is not always the one this view
  /// was opened with: merging the person folds their rooms into a
  /// `merged:<contact>` chat, and the room id this route carries stops naming
  /// anything in the inbox. Every action and lookup below goes through this,
  /// so a merge underneath an open chat re-points the view instead of
  /// stranding it on a spinner that never ends.
  String get _chatId {
    final direct = ref
        .read(chatsProvider)
        .value
        ?.where((c) => c.id == widget.chatId)
        .firstOrNull;
    if (direct != null) return widget.chatId;
    return ref.read(chatRepositoryProvider).chatForRoom(widget.chatId)?.id ??
        widget.chatId;
  }

  /// What the open timeline was built for, to notice when [_chatId] moves.
  String? _timelineChatId;

  /// The repository's merge composition when the timeline was opened.
  int _timelineEpoch = 0;

  /// Held rather than read back in [dispose], where `ref` is already unsafe:
  /// a `ConsumerState` is unmounted before its `dispose` runs, and reading a
  /// provider through a dead `BuildContext` throws.
  late final ComposerHandle _composerHandle;

  @override
  void initState() {
    super.initState();
    _composerHandle = ref.read(composerHandleProvider)
      ..register(this, _composerFocus);
    // Every sync re-emits the chat list, which makes it the heartbeat this
    // view needs: until now nothing refreshed [_view] when the *other side*
    // did something, so an incoming message — a bridge bot answering a
    // command, most visibly — appeared only after reopening the chat or
    // touching it in a way that happened to call [_refresh].
    ref.listenManual(chatsProvider, (_, _) => _syncRefresh());
    _composer.addListener(_onComposerChanged);
    _open();
  }

  /// Who is typing and whether the peer is online, refreshed per sync tick.
  List<String> _typing = const [];
  bool _peerOnline = false;

  /// Rate-limits the outgoing typing signal: one every few seconds while the
  /// user keeps writing, an immediate "stopped" when the field empties. The
  /// 25s server-side timeout picks up a signal a killed process never
  /// retracted.
  DateTime _typingSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _typingSent = false;

  void _onComposerChanged() {
    final repository = ref.read(chatRepositoryProvider);
    final hasText = _composer.text.trim().isNotEmpty;
    if (hasText) {
      final now = DateTime.now();
      if (now.difference(_typingSentAt) > const Duration(seconds: 4)) {
        _typingSentAt = now;
        _typingSent = true;
        unawaited(
          repository.setTyping(_chatId, typing: true).catchError((Object e) {}),
        );
      }
    } else if (_typingSent) {
      _typingSent = false;
      _typingSentAt = DateTime.fromMillisecondsSinceEpoch(0);
      unawaited(
        repository.setTyping(_chatId, typing: false).catchError((Object e) {}),
      );
    }
  }

  /// What of the loaded view can change underneath us between syncs.
  ///
  /// Cheap fingerprint rather than deep equality: recomputing the merged view
  /// is O(loaded) and fine, but rebuilding the tree on every sync of every
  /// unrelated room is a scroll hitch the reader can feel. Reactions and edits
  /// are folded in so a remote edit updates the open bubble too.
  int _viewFingerprint(MergedTimelineView view) {
    var reactions = 0;
    var edited = 0;
    var redacted = 0;
    for (final m in view.messages) {
      reactions += m.reactions.length;
      if (m.isEdited) edited++;
      if (m.redacted) redacted++;
    }
    return Object.hash(
      view.messages.length,
      view.messages.firstOrNull?.eventId,
      reactions,
      edited,
      redacted,
    );
  }

  void _syncRefresh() {
    if (!mounted) return;
    // The conversation was merged (or unmerged) underneath this view: its id
    // moved, and the open timeline covers the wrong set of rooms. Reopen on
    // the new id — this is what turned the back-from-merge spinner into a
    // conversation again.
    final repository = ref.read(chatRepositoryProvider);
    if (_timelineChatId != null &&
        (_timelineChatId != _chatId ||
            _timelineEpoch != repository.timelineEpoch)) {
      _open();
      return;
    }
    // Ephemeral state rides the same heartbeat but not the same
    // fingerprint: someone starting to type changes no message.
    final typing = repository.typingIn(_chatId);
    final online = repository.presenceFor(_chatId)?.online ?? false;
    if (!listEquals(typing, _typing) || online != _peerOnline) {
      setState(() {
        _typing = typing;
        _peerOnline = online;
      });
    }
    final timeline = _timeline;
    if (timeline == null) return;
    final next = timeline.view();
    if (_viewFingerprint(next) == _viewFingerprint(_view)) return;
    setState(() => _view = next);
    _indexNewMessages(next.messages);
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) _open();
  }

  @override
  void dispose() {
    // Released before the node is disposed, and only if this widget still holds
    // the handle: pushing a conversation over another builds the new one first,
    // so an unconditional release here would clear the registration the
    // incoming screen has already made.
    _composerHandle.release(this);
    _composerFocus.dispose();
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
      final chatId = _chatId;
      _timelineChatId = chatId;
      _timelineEpoch = ref.read(chatRepositoryProvider).timelineEpoch;
      final timeline = await ref
          .read(chatRepositoryProvider)
          .timelineFor(chatId);
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

  DateTime _lastLoadOlderAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _loadOlder() async {
    final timeline = _timeline;
    if (timeline == null || _loading || !timeline.hasMoreHistory) return;
    _lastLoadOlderAt = DateTime.now();
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
          ?.where((c) => c.id == _chatId)
          .firstOrNull
          ?.title;
      ref
          .read(chatRepositoryProvider)
          .indexMessages(_chatId, fresh, chatTitle: title ?? '');
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
      homeAssistant: ref.read(homeAssistantProvider) != null,
    );
    if (choice == null || !mounted) return;

    switch (choice.action) {
      case MessageAction.reply:
        _enterComposerContext(ComposerContext.reply(message));
      case MessageAction.edit:
        _startEdit(message);
      case MessageAction.react:
        await _react(message, choice.emoji!);
      case MessageAction.moreReactions:
        await _pickReaction(message);
      case MessageAction.copy:
        await _copy(message);
      case MessageAction.selectText:
        await _selectText(message);
      case MessageAction.editInvite:
        await _editInvite(message);
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
      case MessageAction.editHistory:
        if (mounted) await showEditHistorySheet(context, message: message);
      case MessageAction.remind:
        await _remindLater(message);
      case MessageAction.sendToHomeAssistant:
        await _sendToHomeAssistant(message);
    }
  }

  Future<void> _sendToHomeAssistant(WeftMessage message) async {
    final client = ref.read(homeAssistantProvider);
    if (client == null) return;
    try {
      await client.fireMessageEvent({
        'sender': message.senderName,
        'sender_id': message.senderId,
        'network': message.network.id,
        'chat_id': _chatId,
        'body': messageDocument(message).plainText,
        'timestamp': message.timestamp.toIso8601String(),
      });
      _showMessage('Sent to Home Assistant as a weft_message event.');
    } on Object catch (error) {
      _showMessage('Home Assistant refused it: $error');
    }
  }

  /// "Remind me": a handful of natural offsets, then the OS carries it.
  Future<void> _remindLater(WeftMessage message) async {
    final now = DateTime.now();
    final tonight = DateTime(now.year, now.month, now.day, 19);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
    final choice = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('In one hour'),
              onTap: () =>
                  Navigator.of(context).pop(now.add(const Duration(hours: 1))),
            ),
            if (tonight.isAfter(now))
              ListTile(
                leading: const Icon(Icons.nights_stay_outlined),
                title: const Text('This evening (19:00)'),
                onTap: () => Navigator.of(context).pop(tonight),
              ),
            ListTile(
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text('Tomorrow morning (9:00)'),
              onTap: () => Navigator.of(context).pop(tomorrow),
            ),
            ListTile(
              leading: const Icon(Icons.edit_calendar_rounded),
              title: const Text('Pick a time…'),
              onTap: () async {
                final navigator = Navigator.of(context);
                final when = await _pickDateTime(context, from: now);
                navigator.pop(when);
              },
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final preview = messageDocument(message).plainText;
    await ref
        .read(reminderSchedulerProvider)
        .remind(
          chatId: _chatId,
          title: 'Reminder: ${message.isOwn ? 'you' : message.senderName}',
          body: preview.length > 120
              ? '${preview.substring(0, 117)}…'
              : preview,
          at: choice,
        );
    if (mounted) {
      _showMessage(
        'Will remind you at '
        '${DateFormat.MMMEd().add_Hm().format(choice)}.',
      );
    }
  }

  /// Date then time, composed; null when either step is dismissed.
  static Future<DateTime?> _pickDateTime(
    BuildContext context, {
    required DateTime from,
  }) async {
    final date = await showDatePicker(
      context: context,
      initialDate: from,
      firstDate: from,
      lastDate: from.add(const Duration(days: 365)),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(from.add(const Duration(hours: 1))),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  void _startEdit(WeftMessage message) {
    // The fallback goes: an edit of a reply must not put the quoted context
    // back into the words the user is about to re-send.
    _composer.text = stripReplyFallback(message.body);
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    _enterComposerContext(ComposerContext.edit(message));
  }

  /// Puts the composer into [context] and the caret in it.
  ///
  /// The focus is the part that was missing, and it was missing invisibly:
  /// `autofocus` on the `TextField` is read once, when its focus node first
  /// attaches, and the composer is on screen long before anyone long-presses a
  /// bubble — so flipping the flag to true did nothing at all. Reply and edit
  /// are both "now type", and a mode you have to click into before you can
  /// type or press Escape is a mode with one way in and one way out.
  void _enterComposerContext(ComposerContext context) {
    setState(() => _composerContext = context);
    _composerFocus.requestFocus();
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

  /// When the other side read [message] — set only on the newest own message,
  /// which is the one place a "Seen" line carries information rather than
  /// noise down the whole column.
  DateTime? _seenAt(WeftMessage message) {
    if (!message.isOwn) return null;
    final newestOwn = _view.messages.where((m) => m.isOwn).firstOrNull;
    if (newestOwn == null || newestOwn.eventId != message.eventId) return null;
    for (final marker
        in ref.read(chatRepositoryProvider).peerReadUpTo(_chatId)) {
      if (marker.roomId != message.roomId) continue;
      if (marker.eventId == message.eventId) return marker.at;
      // The receipt names some other event; if that event sits at or after
      // ours in the same room, ours has been read on the way.
      final receipted = _view.messages
          .where(
            (m) => m.eventId == marker.eventId && m.roomId == marker.roomId,
          )
          .firstOrNull;
      if (receipted != null &&
          !receipted.timestamp.isBefore(message.timestamp)) {
        return marker.at;
      }
    }
    return null;
  }

  static String _seenLabel(DateTime at) {
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? 'Seen at ${DateFormat.Hm().format(at)}'
        : 'Seen ${DateFormat.MMMEd().add_Hm().format(at)}';
  }

  /// The message in a view where a *part* of it can be selected and copied —
  /// long-press on the bubble acts on the whole message, so partial copy
  /// lives here.
  Future<void> _selectText(WeftMessage message) async {
    final text = messageDocument(message).plainText;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select text'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: context.text.bodyMedium),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _addInviteToCalendar(WeftMessage message) async {
    final invite = message.calendarInvite;
    if (invite == null) return;
    try {
      await addToDeviceCalendar(
        title: invite.title,
        start: invite.start,
        end: invite.end,
      );
    } on Object catch (error) {
      debugPrint('weft: add to calendar failed: $error');
      _showMessage('The calendar could not be opened.');
    }
  }

  /// Moves a calendar proposal the user already sent. The room sees an edit;
  /// a bridged peer sees their app's own edited-message treatment.
  Future<void> _editInvite(WeftMessage message) async {
    final invite = message.calendarInvite;
    if (invite == null) return;
    final when = await _pickDateTime(context, from: invite.start);
    if (when == null || !mounted) return;
    final end = invite.end;
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .editCalendarInvite(
            message.roomId,
            message.eventId,
            title: invite.title,
            start: when,
            end: end == null ? null : when.add(end.difference(invite.start)),
          ),
    );
  }

  Future<void> _delete(WeftMessage message) async {
    if (!await confirmRedaction(context)) return;
    if (!mounted) return;
    await _run(
      () => ref.read(chatRepositoryProvider).redact(_chatId, message.eventId),
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
    await _run(() => repository.react(_chatId, message.eventId, key));
  }

  Future<void> _toggleReaction(WeftMessage message, ReactionTally tally) async {
    final repository = ref.read(chatRepositoryProvider);
    final localEventId = tally.localEventId;

    if (tally.byLocalUser && localEventId != null) {
      await _run(() => repository.unreact(_chatId, localEventId));
      return;
    }
    ref.read(reactionRecentsProvider.notifier).note(tally.key);
    await _run(() => repository.react(_chatId, message.eventId, tally.key));
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
    if (mounted) ref.invalidate(chatTrustProvider(_chatId));
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = _unavailable;
    if (unavailable != null) return _unavailableScaffold(context, unavailable);

    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final chat = chats.where((c) => c.id == _chatId).firstOrNull;
    // Uploads sit *below* the settled messages in a reversed list, which is the
    // bottom of the thread: a photo the user just picked belongs where the next
    // message would go, not above the history they were reading.
    final uploads =
        ref.watch(chatUploadsProvider(_chatId)).value ?? const <UploadTask>[];
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
      appBar: _ChatAppBar(chat: chat, typing: _typing, online: _peerOnline),
      body: _escapeCancels(
        // Ordered rather than reading order: the timeline comes before the
        // composer whichever way the text runs, and the banner above them both
        // is a warning that has to be met before either.
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Column(
            children: [
              UnverifiedDevicesBanner(
                // Absent while the key store is being read, which is the honest
                // default: a warning that flashes in and out on every open would
                // be trained away within a day.
                trust:
                    ref.watch(chatTrustProvider(_chatId)).value ??
                    RoomTrust.none,
                onVerify: _verifyOwnDevice,
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      // Reversed list: "extent after" is older history. The
                      // cooldown matters: scroll notifications arrive per
                      // frame, and re-triggering a backfill the instant the
                      // previous one finished kept the list growing — and
                      // rebuilding — for as long as the reader sat near the
                      // old end, which read as the chat "lagging up".
                      if (n.metrics.extentAfter < 600 &&
                          !_loading &&
                          DateTime.now().difference(_lastLoadOlderAt) >
                              const Duration(milliseconds: 300)) {
                        _loadOlder();
                      }
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
                            .cached(message.eventId, roomId: message.roomId);
                        if (cachedTranscript != null &&
                            message.transcript == null) {
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
                            _SwipeToReply(
                              enabled: !message.redacted,
                              onReply: () => _enterComposerContext(
                                ComposerContext.reply(message),
                              ),
                              child: _MessageBubble(
                                message: message,
                                replyPreview: _replyPreviewFor(message),
                                highlighted:
                                    message.eventId == _highlightEventId,
                                transcribing: _transcribing.contains(
                                  message.eventId,
                                ),
                                onOpen: rendersAsAttachment(message)
                                    ? () => _openMedia(message)
                                    : null,
                                onTranscribe:
                                    message.canTranscribe &&
                                        message.transcript == null
                                    ? () => _transcribe(message)
                                    : null,
                                onRetranscribe:
                                    message.canTranscribe &&
                                        message.transcript != null
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
                                onTapLink: _openLink,
                                onTapMention: _openMention,
                                onRespondInvite: message.calendarInvite == null
                                    ? null
                                    : (reply, proposedStart) => _respondInvite(
                                        message,
                                        reply,
                                        proposedStart,
                                      ),
                                onAddInviteToCalendar:
                                    message.calendarInvite == null
                                    ? null
                                    : () => _addInviteToCalendar(message),
                                onEditInvite: message.calendarInvite == null
                                    ? null
                                    : () => _editInvite(message),
                                onVote: message.kind == MessageKind.poll
                                    ? (optionId) => _run(
                                        () => ref
                                            .read(chatRepositoryProvider)
                                            .votePoll(
                                              message.roomId,
                                              message.eventId,
                                              {optionId},
                                            ),
                                      )
                                    : null,
                                showNetwork: chat.isMerged,
                                showSender: chat.isGroup,
                                groupedWithPrevious:
                                    older != null &&
                                    older.isOwn == message.isOwn &&
                                    older.network == message.network &&
                                    message.timestamp
                                            .difference(older.timestamp)
                                            .inMinutes <
                                        5,
                              ),
                            ),
                            if (_seenAt(message) case final DateTime seen)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  top: 2,
                                  end: WeftSpace.xs,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: Text(
                                    _seenLabel(seen),
                                    style: context.text.labelSmall?.copyWith(
                                      color: context.colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              _ScheduledSendsBar(chatId: _chatId),
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: _recording
                    ? VoiceRecordingBar(
                        onCancel: () => setState(() => _recording = false),
                        onSend: (recording) => _sendVoiceNote(chat, recording),
                      )
                    : _Composer(
                        chat: chat,
                        controller: _composer,
                        focusNode: _composerFocus,
                        composing: _composerContext,
                        onCancelContext: _cancelComposerContext,
                        onSend: _send,
                        onAttach: () => _attach(chat),
                        onPickNetwork: _pickNetwork,
                        onRecordVoice: () => setState(() => _recording = true),
                        onSendLater: () => _sendLater(chat),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [child] with Escape wired to leaving reply or edit mode.
  ///
  /// Here rather than in the app-wide map, and *disabled* rather than absent
  /// when there is no mode to leave. Escape belongs to whatever is on top: a
  /// dialog over a conversation with a reply half-typed has to close on the
  /// first press, and an action that reports itself disabled lets `Shortcuts`
  /// pass the key on to the `DismissIntent` that does it.
  Widget _escapeCancels({required Widget child}) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape):
            CancelComposerContextIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          CancelComposerContextIntent:
              WeftGuardedAction<CancelComposerContextIntent>(
                onInvoke: _cancelComposerContext,
                // Disabled rather than absent: with nothing to cancel the key
                // has to reach the `DismissIntent` above, or a dialog over a
                // conversation would need two presses to close.
                enabled: () => _composerContext != null,
              ),
        },
        child: child,
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
  /// Whether the composer row is currently the voice recorder.
  bool _recording = false;

  Future<void> _sendVoiceNote(Chat chat, VoiceRecording recording) async {
    setState(() => _recording = false);
    final problems = await sendAttachments(
      ref.read(chatRepositoryProvider),
      _chatId,
      [recording.source],
      via: chat.sendNetwork,
      isVoiceNote: true,
      durationMs: recording.durationMs,
    );
    if (problems.isNotEmpty && mounted) _showMessage(problems.first);
  }

  /// Long-press on Send: pick a moment, park the text in the outbox.
  Future<void> _sendLater(Chat chat) async {
    final text = _composer.text.trim();
    if (text.isEmpty) {
      _showMessage('Write the message first, then hold Send to schedule it.');
      return;
    }
    final when = await _pickDateTime(context, from: DateTime.now());
    if (when == null || !mounted) return;
    if (!when.isAfter(DateTime.now())) {
      _showMessage('That time is already past.');
      return;
    }

    ref
        .read(messageSchedulerProvider.notifier)
        .schedule(
          ScheduledMessage(
            id: 'send-${DateTime.now().microsecondsSinceEpoch}',
            chatId: _chatId,
            chatTitle: chat.title,
            body: text,
            dueAtMs: when.millisecondsSinceEpoch,
            networkId: chat.sendNetwork?.id,
          ),
        );
    _composer.clear();
    _showMessage(
      'Scheduled for ${DateFormat.MMMEd().add_Hm().format(when)}. '
      'It sends while Braid is running.',
    );
  }

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
          () =>
              repository.editMessage(_chatId, composing!.message.eventId, text),
        );
        // Deliberately no `_noteSend`: an edit is not a message sent to this
        // conversation, and counting it would push a chat up the share ranker
        // for a typo the user fixed.
        return;
      case ComposerMode.reply:
        await _run(
          () => repository.sendReply(
            _chatId,
            text,
            replyToEventId: composing!.message.eventId,
          ),
        );
      case null:
        await _run(() => repository.send(_chatId, text));
    }
    // The message is the retraction: nothing is being typed any more.
    _typingSent = false;
    unawaited(
      repository.setTyping(_chatId, typing: false).catchError((Object e) {}),
    );
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
      unawaited(ref.read(shareShortcutServiceProvider).noteSend(_chatId));

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
      ref.read(chatRepositoryProvider).setSendNetwork(_chatId, network),
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
    final source = await showAttachmentSourceSheet(
      context,
      picker,
      paperless: ref.read(paperlessProvider) != null,
    );
    if (source == null || !mounted) return;

    if (source == AttachmentPickSource.location) {
      await _shareLocation(chat);
      return;
    }
    if (source == AttachmentPickSource.poll) {
      await _createPoll(chat);
      return;
    }
    if (source == AttachmentPickSource.calendar) {
      await _createCalendarInvite(chat);
      return;
    }
    if (source == AttachmentPickSource.paperless) {
      final staged = await showPaperlessPickerSheet(context, ref);
      if (staged == null || !mounted) return;
      final confirmed = await showAttachmentPreviewSheet(
        context,
        chat: chat,
        sources: [staged],
        onPickNetwork: _pickNetwork,
      );
      if (confirmed == null || confirmed.isEmpty || !mounted) return;
      await _sendAttachments(confirmed);
      return;
    }

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
  /// One-shot position → `m.location`. The permission dialog is the OS's,
  /// shown at the moment of sharing.
  Future<void> _shareLocation(Chat chat) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showMessage('Braid has no location permission.');
        return;
      }
      _showMessage('Getting your position…');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      await ref
          .read(chatRepositoryProvider)
          .sendLocation(
            _chatId,
            latitude: position.latitude,
            longitude: position.longitude,
            via: chat.sendNetwork,
          );
    } on Object catch (error) {
      debugPrint('weft: share location failed: $error');
      if (mounted) _showMessage('Could not get a position.');
    }
  }

  Future<void> _respondInvite(
    WeftMessage message,
    CalendarReply reply,
    DateTime? proposedStart,
  ) async {
    // The sender adopting a proposed time is not an *answer* — it is the next
    // version of the invitation, sent at that time.
    if (message.isOwn && proposedStart != null) {
      final invite = message.calendarInvite!;
      final chat = ref
          .read(chatsProvider)
          .value
          ?.where((c) => c.id == _chatId)
          .firstOrNull;
      await _run(
        () => ref
            .read(chatRepositoryProvider)
            .sendCalendarInvite(
              _chatId,
              title: invite.title,
              start: proposedStart,
              via: chat?.sendNetwork,
            ),
      );
      return;
    }
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .respondCalendarInvite(
            message.roomId,
            message.eventId,
            reply: reply,
            proposedStart: proposedStart,
          ),
    );
    if (reply == CalendarReply.accepted && message.calendarInvite != null) {
      // Accepting means it goes in the calendar — that is what accept *is*.
      final invite = message.calendarInvite!;
      try {
        await addToDeviceCalendar(
          title: invite.title,
          start: invite.start,
          end: invite.end,
        );
      } on Object catch (error) {
        debugPrint('weft: calendar add failed: $error');
      }
    }
  }

  Future<void> _createCalendarInvite(Chat chat) async {
    final title = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Propose a calendar entry'),
        content: TextField(
          controller: title,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'What is it?',
            hintText: 'Dinner at ours',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Pick a time'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), title.dispose);
    if (confirmed != true || title.text.trim().isEmpty || !mounted) return;

    final when = await _pickDateTime(context, from: DateTime.now());
    if (when == null || !mounted) return;

    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .sendCalendarInvite(
            _chatId,
            title: title.text.trim(),
            start: when,
            via: chat.sendNetwork,
          ),
    );
  }

  Future<void> _createPoll(Chat chat) async {
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (context) => const _PollComposerDialog(),
    );
    if (result == null || !mounted) return;
    final (question, options) = result;
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .createPoll(
            _chatId,
            question: question,
            options: options,
            via: chat.sendNetwork,
          ),
    );
  }

  Future<void> _sendAttachments(List<AttachmentSource> sources) async {
    final problems = await sendAttachments(
      ref.read(chatRepositoryProvider),
      _chatId,
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
  const _ChatAppBar({
    required this.chat,
    this.typing = const [],
    this.online = false,
  });

  final Chat chat;

  /// Names currently typing. Non-empty replaces the subtitle — "typing…" is
  /// the most current thing that can be said about a conversation.
  final List<String> typing;

  /// Whether the DM partner is online, where presence reaches this side.
  final bool online;

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
      title: Row(
        children: [
          // The avatar is a *button* now — it opens the contact profile — so
          // it stands outside the merged heading with its own 48dp target
          // and its own name, instead of turning the whole title row into
          // one enormous 40dp-tall tappable.
          Semantics(
            button: true,
            label: 'Contact details',
            child: Consumer(
              builder: (context, ref, _) => InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ContactProfileScreen(chatId: chat.id),
                  ),
                ),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: ExcludeSemantics(
                      child: WeftAvatar(
                        label: chat.title,
                        imageUrl: chat.avatarUrl,
                        imageHeaders: ref.watch(mediaHeadersProvider),
                        networks: chat.networks,
                        size: 38,
                        // The lines beside it already say all of this.
                        semanticsLabel: '',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: WeftSpace.sm),
          Expanded(
            child: MergeSemantics(
              child: Semantics(
                header: true,
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
                    if (typing.isNotEmpty)
                      Text(
                        chat.isGroup
                            ? '${typing.join(', ')} '
                                  '${typing.length == 1 ? 'is' : 'are'} '
                                  'typing…'
                            : 'typing…',
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else if (chat.isMerged)
                      Text(
                        'Merged · '
                        '${chat.networks.map((n) => n.label).join(', ')}'
                        '${online ? ' · online' : ''}',
                        style: context.text.labelSmall?.copyWith(
                          color: context.palette.mergedAccent,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(
                        '${chat.networks.firstOrNull?.label ?? ''}'
                        '${online ? ' · online' : ''}',
                        style: context.text.labelSmall?.copyWith(
                          color: online
                              ? context.palette.online
                              : context.colors.onSurfaceVariant,
                          fontWeight: online ? FontWeight.w600 : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        // Disabled rather than hidden, with the reason in its tooltip: a
        // conversation with no Matrix-native leg cannot carry a call, and a
        // button that quietly disappeared for bridged chats would read as Braid
        // having lost the feature.
        Consumer(
          builder: (context, ref, _) {
            final availability = ref.watch(callAvailabilityProvider(chat.id));
            final target = availability.target;
            if (target != null) {
              return IconButton(
                tooltip: availability.message,
                icon: const Icon(Icons.call_rounded),
                onPressed: () => startCall(context, ref, target),
              );
            }
            // No Matrix leg to call over — the call lives in the network's
            // own app, so the button opens the conversation there (or the
            // dialler, when all Weft knows is a number) instead of sitting
            // greyed out under a tooltip explaining itself. Only for the
            // *bridged* refusal: a group is refused as a group whatever apps
            // its members are on.
            if (availability is! CallBlocked ||
                availability.reason != CallBlocker.bridged) {
              return IconButton(
                tooltip: availability.message,
                icon: const Icon(Icons.call_rounded),
                onPressed: null,
              );
            }
            final contact = chat.contactId == null
                ? null
                : ref
                      .read(chatRepositoryProvider)
                      .identityGraph
                      .contacts()
                      .where((c) => c.id == chat.contactId)
                      .firstOrNull;
            final external = externalCallRouteFor(chat, contact);
            if (external == null) {
              return IconButton(
                tooltip: availability.message,
                icon: const Icon(Icons.call_rounded),
                onPressed: null,
              );
            }
            return IconButton(
              tooltip: external.label,
              icon: const Icon(Icons.phone_forwarded_rounded),
              onPressed: () async {
                final opened = await launchUrl(
                  external.uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  showWeftMessage(
                    context,
                    'Nothing on this device could open that call.',
                  );
                }
              },
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

/// Drag a bubble towards the reading direction to quote it — the reply
/// gesture every messenger has taught thumbs. The bubble follows the finger,
/// a reply arrow fades in behind it, and passing the threshold ticks once
/// and opens the composer in reply context; release before it and the bubble
/// springs back with nothing sent. Purely an accelerator: Reply stays on the
/// long-press sheet, which is also where switch access and screen readers
/// already find it.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.enabled,
    required this.onReply,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  double _drag = 0;
  bool _armed = false;

  static const double _trigger = 56;
  static const double _max = 84;

  void _update(DragUpdateDetails details, double direction) {
    final next = (_drag + details.delta.dx * direction).clamp(0.0, _max);
    if (next == _drag) return;
    final arming = next >= _trigger;
    if (arming && !_armed) unawaited(HapticFeedback.lightImpact());
    setState(() {
      _drag = next;
      _armed = arming;
    });
  }

  void _settle() {
    if (_armed) widget.onReply();
    setState(() {
      _drag = 0;
      _armed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final direction = rtl ? -1.0 : 1.0;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) => _update(details, direction),
      onHorizontalDragEnd: (_) => _settle(),
      onHorizontalDragCancel: _settle,
      child: Stack(
        children: [
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            child: Opacity(
              opacity: (_drag / _trigger).clamp(0.0, 1.0),
              child: Icon(
                Icons.reply_rounded,
                color: _armed
                    ? context.colors.primary
                    : context.colors.onSurfaceVariant,
              ),
            ),
          ),
          AnimatedContainer(
            // Instant under the finger, sprung on release.
            duration: _drag == 0 ? WeftMotion.fast : Duration.zero,
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_drag * direction, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// A stable, readable colour for one sender, derived from their id.
///
/// Hue from the hash, saturation fixed, lightness picked per theme so the
/// name clears the peer bubble's fill in both modes.
Color _senderColor(BuildContext context, String senderId) {
  final hue = (senderId.hashCode & 0x7fffffff) % 360;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return HSLColor.fromAHSL(
    1,
    hue.toDouble(),
    0.55,
    dark ? 0.72 : 0.34,
  ).toColor();
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showNetwork,
    this.showSender = false,
    required this.groupedWithPrevious,
    this.replyPreview,
    this.onVote,
    this.onRespondInvite,
    this.onAddInviteToCalendar,
    this.onEditInvite,
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
    this.onTapLink,
    this.onTapMention,
  });

  /// Opens the attachment full screen. Null for a message that has none.
  final VoidCallback? onOpen;

  /// Casts a vote on this message's poll. Null for everything else.
  final ValueChanged<String>? onVote;

  /// Answers this message's calendar invitation.
  final void Function(CalendarReply reply, DateTime? proposedStart)?
  onRespondInvite;

  /// Puts this message's invitation into the device calendar.
  final VoidCallback? onAddInviteToCalendar;

  /// Sender only: re-times this message's invitation.
  final VoidCallback? onEditInvite;

  /// Whether to print the sender's name above the content — group chats,
  /// where "who wrote this" is not answered by which side it sits on.
  final bool showSender;

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
                child: WeftFocusable(
                  // The bubble is a group, not a control: it holds a body whose
                  // links and mention pills must stay individually reachable,
                  // so its children keep speaking and keep their own focus
                  // nodes. What the group adds is the header a sighted user
                  // reads off the bubble's position and colour — who, and on
                  // what leg.
                  button: false,
                  excludeSemantics: false,
                  label: _senderLabel,
                  // Long-press rather than a visible affordance: a button per
                  // bubble is six controls per screen the reader has to look
                  // past to read the conversation. On a keyboard the same
                  // sheet is Enter, since there is no long-press to make — and
                  // deliberately not a tap, which would put a menu in front of
                  // anyone who touched a message.
                  onActivate: onActions,
                  onLongPress: onActions,
                  onLongPressHint: 'show actions',
                  borderRadius: WeftRadius.allLg,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 520),
                    padding: const EdgeInsets.symmetric(
                      horizontal: WeftSpace.md,
                      vertical: WeftSpace.sm,
                    ),
                    decoration: BoxDecoration(
                      color: own ? palette.ownBubble : palette.peerBubble,
                      // The tail is on the corner nearest the side of the thread
                      // the bubble sits on, and both are resolved from the
                      // reader's direction rather than from physical space: the
                      // row above already puts an own message at the *end*, so
                      // a physically-computed tail would point away from the
                      // speaker the moment the app is mirrored.
                      borderRadius: BorderRadiusDirectional.only(
                        topStart: WeftRadius.lg,
                        topEnd: WeftRadius.lg,
                        bottomStart: own ? WeftRadius.lg : WeftRadius.xs,
                        bottomEnd: own ? WeftRadius.xs : WeftRadius.lg,
                      ),
                      // A merged chat marks each bubble's origin with a
                      // hairline in the network's colour — readable without
                      // stealing attention. On the leading edge, which is the
                      // one facing the middle of the thread in either
                      // direction.
                      border: showNetwork
                          ? BorderDirectional(
                              start: BorderSide(color: accent, width: 3),
                            )
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showNetwork && !groupedWithPrevious) ...[
                          // Silent, all of it. The bubble's group node opens
                          // with "Anna Maven, on WhatsApp"; the glyph carries
                          // the network's name and the caption beside it
                          // repeats the same word, so on a device a merged
                          // thread announced every leg three times over —
                          // "Anna Maven, on WhatsApp. WhatsApp. WhatsApp."
                          // This row is how a *sighted* reader learns which
                          // network a bubble came from, and a reader who has
                          // already been told does not need it twice more.
                          ExcludeSemantics(
                            child: Row(
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
                          ),
                          const SizedBox(height: 3),
                        ],
                        // Groups say who wrote each message. Coloured by a
                        // stable hash of the sender so the same person keeps
                        // the same colour all the way up the thread; excluded
                        // from semantics because the bubble's group node
                        // already opens with the sender's name.
                        if (showSender && !own && !groupedWithPrevious) ...[
                          ExcludeSemantics(
                            child: Text(
                              message.senderName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: _senderColor(context, message.senderId),
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
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
                        else if (message.kind == MessageKind.location)
                          _LocationContent(message: message, own: own)
                        else if (message.calendarInvite != null)
                          _CalendarInviteContent(
                            message: message,
                            own: own,
                            onRespond: onRespondInvite,
                            onAddToCalendar: onAddInviteToCalendar,
                            onEditTime: own ? onEditInvite : null,
                          )
                        else if (message.kind == MessageKind.poll &&
                            message.poll != null)
                          _PollContent(
                            message: message,
                            own: own,
                            onVote: onVote ?? (_) {},
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
                              _EditedMarker(message: message, own: own),
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
            ],
          ),
          // Under the bubble rather than inside it, for the same reason the
          // reaction bar is: the card is *about* the message, not part of what
          // the sender said. It draws nothing at all unless the reader has
          // switched previews on and the homeserver had an answer — see
          // [LinkPreviewCard].
          if (content == null)
            LinkPreviewCard(message: message, own: own, onTapUrl: onTapLink),
          // Same reasoning, same place: the chip is an action *about* the
          // message. It renders nothing unless the detector found a date
          // worth offering — see [AgendaChip].
          if (content == null && !message.redacted)
            AgendaChip(message: message),
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
  const _EditedMarker({required this.message, required this.own});

  final WeftMessage message;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = palette.mutedOnBubble(own);
    final editedAt = message.editedAt;
    final hasHistory = message.editHistory.isNotEmpty;

    return Tooltip(
      message: hasHistory
          ? 'Edited — the versions are in the message actions'
          : 'This message was edited',
      excludeFromSemantics: true,
      // A statement, not a control. It used to open the edit history on tap,
      // which made a 10dp italic run the entire target for the operation
      // (TAP-15) — and a run of text inside a metadata line cannot be grown to
      // 48dp without pushing the bubble apart. The history moved to the
      // message actions sheet, where the other eight operations on a message
      // already are and where the keyboard can reach it.
      //
      // Still its own node rather than a fragment merged into the words above
      // it: "edited at 13:58" qualifies the message, and a reader who meets it
      // inside the paragraph cannot tell it apart from something that was said.
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: semanticsSentence([
          editedAt == null
              ? 'Edited'
              : 'Edited at ${DateFormat.Hm().format(editedAt)}',
          if (hasHistory) 'versions in the message actions',
        ]),
        child: Text(
          editedAt == null
              ? 'edited'
              : 'edited ${DateFormat.Hm().format(editedAt)}',
          style: context.text.labelSmall?.copyWith(
            fontSize: 10,
            fontStyle: FontStyle.italic,
            color: ink,
          ),
        ),
      ),
    );
  }
}

/// Voice message with a waveform placeholder and, when available, the
/// transcript produced by the user's own STT endpoint.
class _VoiceContent extends ConsumerWidget {
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

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(voicePlayerProvider.notifier).toggle(message);
    } on Exception catch (e) {
      if (context.mounted) {
        showWeftMessage(context, '$e'.replaceFirst('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bubble = own ? palette.ownBubble : palette.peerBubble;

    final playback = ref.watch(voicePlayerProvider);
    final isCurrent = playback.eventId == message.eventId;
    final playing = isCurrent && playback.playing;
    final loading = isCurrent && playback.loading;
    final progress = isCurrent ? playback.progress : 0.0;

    // While playing, the clock counts up; at rest it states the length.
    final shownDuration = isCurrent && playback.position > Duration.zero
        ? formatMediaDuration(playback.position.inMilliseconds)
        : formatMediaDuration(message.durationMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          // Max, not min: a voice note is drawn as a full-width instrument the
          // way every messenger draws one, and the waveform below expands to
          // whatever the bubble has — bars that stopped mid-bubble read as a
          // rendering bug, and were reported as one.
          children: [
            // A real control, not an icon-shaped decoration: this is the
            // play/pause button the whole bubble is drawn around. Its own
            // semantics node, 48dp — the merged description beside it is a
            // label, and a label is not a button.
            Semantics(
              container: true,
              button: true,
              excludeSemantics: true,
              label: loading
                  ? 'Loading voice message'
                  : playing
                  ? 'Pause voice message'
                  : 'Play voice message',
              child: SizedBox(
                width: 48,
                height: 48,
                child: loading
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: onBubble,
                        ),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: playing ? 'Pause' : 'Play',
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 26,
                          color: onBubble,
                        ),
                        onPressed: () => _toggle(context, ref),
                      ),
              ),
            ),
            const SizedBox(width: WeftSpace.xs),
            // One node for the recording itself: a reader was told the duration
            // and never that this was a voice message at all, because "0:42"
            // beside a row of coloured bars is the entire visual signal.
            // Whether there is a transcript belongs here too — it is the
            // difference between a message this reader can read and one they
            // cannot.
            Expanded(
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label: semanticsSentence([
                  'Voice message',
                  formatMediaDuration(message.durationMs),
                  if (playing) 'playing',
                  if (transcribing)
                    'transcribing'
                  else if (message.transcript != null)
                    'transcript below'
                  else if (onTranscribe != null)
                    'no transcript yet',
                ]),
                child: Row(
                  children: [
                    // Waveform takes the space the bubble actually has rather than a
                    // fixed 22 bars: previously the bubble stretched to full width
                    // while the bars and timestamp stopped around the middle.
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final barCount = (constraints.maxWidth / 5.5)
                              .floor()
                              .clamp(8, 160);
                          final playedBars = (progress * barCount).round();
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Deterministic pseudo-waveform: real amplitude data arrives with
                              // the recorder in M9. During playback the bars fill left
                              // to right — the progress indicator and the waveform are
                              // one drawing.
                              for (var i = 0; i < barCount; i++)
                                Container(
                                  width: 2.5,
                                  height:
                                      6 +
                                      ((message.eventId.hashCode >> (i % 28)) &
                                              0x0F)
                                          .toDouble(),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    // A waveform bar is a graphic, not text, so 3:1
                                    // rather than 4.5:1 — it can stay fainter than the
                                    // duration beside it and still be seen.
                                    color: i < playedBars
                                        ? onBubble
                                        : WeftContrast.dim(
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
                      shownDuration ?? '',
                      style: context.text.labelSmall?.copyWith(
                        color: palette.muted(onBubble, bubble, alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.onPickNetwork,
    this.composing,
    this.onCancelContext,
    this.onRecordVoice,
    this.onSendLater,
  });

  /// Switches the row into voice recording. Null hides the microphone —
  /// editing a message into a voice note is not a thing.
  final VoidCallback? onRecordVoice;

  /// Long-press on Send: schedule this text instead of sending it now.
  final VoidCallback? onSendLater;

  final Chat chat;
  final TextEditingController controller;

  /// Owned by the chat, so `FocusComposerIntent` can reach it from the inbox.
  final FocusNode focusNode;

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
      padding: const EdgeInsetsDirectional.fromSTEB(
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
                  child: WeftLabelledField(
                    label: _fieldLabel(sendNetwork),
                    // Around the field, so the key is resolved from the focused
                    // node outward and marked handled before the platform's
                    // text input ever sees it. That is what makes Shift+Enter
                    // able to mean something other than Enter: with
                    // `TextInputAction.send` alone the embedder called
                    // `performAction` for both, so a five-line composer had no
                    // reachable line two.
                    child: Shortcuts(
                      shortcuts: composerShortcuts,
                      child: Actions(
                        actions: <Type, Action<Intent>>{
                          SendComposerIntent:
                              CallbackAction<SendComposerIntent>(
                                onInvoke: (_) {
                                  onSend();
                                  return null;
                                },
                              ),
                          InsertComposerNewlineIntent:
                              CallbackAction<InsertComposerNewlineIntent>(
                                onInvoke: (_) {
                                  insertComposerNewline(controller);
                                  return null;
                                },
                              ),
                        },
                        // Rebuilt per keystroke for one reason: the field's
                        // base direction follows what is being typed, the same
                        // way a sent message's follows what was typed. Someone
                        // answering a Hebrew message in an English UI gets a
                        // caret that starts on the right and punctuation that
                        // lands where they meant it, without having to change
                        // the app's language to write one sentence. The SMS bar
                        // above listens to the same controller for the same
                        // reason.
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: controller,
                          builder: (context, value, _) => TextField(
                            controller: controller,
                            focusNode: focusNode,
                            minLines: 1,
                            maxLines: 5,
                            textDirection: textDirectionOf(value.text),
                            // Kept for a soft keyboard, which sends no key
                            // events at all: on a phone this is still what puts
                            // a send glyph on the return key and what fires
                            // `onSend`.
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => onSend(),
                            decoration: InputDecoration(
                              hintText: _fieldLabel(sendNetwork),
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                // WhatsApp's swap: an empty field sends nothing, so its button
                // is the microphone; the first typed character turns it into
                // send. Listening to the controller keeps the swap in step
                // with typing without rebuilding the whole composer.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final showMic =
                        !editing &&
                        onRecordVoice != null &&
                        value.text.trim().isEmpty;
                    if (showMic) {
                      return IconButton.filled(
                        onPressed: onRecordVoice,
                        icon: const Icon(Icons.mic_rounded, size: 18),
                        tooltip: 'Record voice message',
                      );
                    }
                    return GestureDetector(
                      // Long-press for "send later" — the same spot WhatsApp
                      // and Telegram hide it, and harmless to discover: a
                      // long-press that does nothing was doing nothing anyway.
                      onLongPress: editing ? null : onSendLater,
                      child: IconButton.filled(
                        onPressed: onSend,
                        icon: Icon(
                          editing ? Icons.check_rounded : Icons.send_rounded,
                          size: 18,
                        ),
                        tooltip: editing
                            ? 'Save edit'
                            : 'Send — hold to schedule',
                      ),
                    );
                  },
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

/// The thin strip above the composer when this chat has messages waiting to
/// send. Tapping an entry's cross cancels it; nothing draws when the outbox
/// has nothing for this conversation.
class _ScheduledSendsBar extends ConsumerWidget {
  const _ScheduledSendsBar({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = [
      for (final m in ref.watch(messageSchedulerProvider))
        if (m.chatId == chatId) m,
    ];
    if (pending.isEmpty) return const SizedBox.shrink();

    return Container(
      color: context.colors.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.lg,
        vertical: WeftSpace.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final message in pending)
            Row(
              children: [
                Icon(
                  Icons.schedule_send_rounded,
                  size: 16,
                  color: context.colors.onSurfaceVariant,
                ),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    '${DateFormat.MMMEd().add_Hm().format(message.dueAt)} — '
                    '${message.body}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                ),
                NamedButton(
                  label: 'Cancel the scheduled message',
                  onPressed: () => ref
                      .read(messageSchedulerProvider.notifier)
                      .cancel(message.id),
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    tooltip: 'Cancel',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(messageSchedulerProvider.notifier)
                        .cancel(message.id),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A shared position: a pin, the coordinates, and a tap into the maps app.
///
/// No embedded map tile on purpose — fetching one would send the sender's
/// position to a tile server the user never chose. The maps app the tap opens
/// is the user's own.
class _LocationContent extends StatelessWidget {
  const _LocationContent({required this.message, required this.own});

  final WeftMessage message;
  final bool own;

  /// `geo:52.5,13.4;u=10` → (52.5, 13.4), or null when unparseable.
  (double, double)? get _coordinates {
    final raw = message.geoUri;
    if (raw == null) return null;
    final match = RegExp(
      r'^geo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)',
    ).firstMatch(raw.trim());
    if (match == null) return null;
    return (double.parse(match.group(1)!), double.parse(match.group(2)!));
  }

  Future<void> _open(BuildContext context) async {
    final coordinates = _coordinates;
    if (coordinates == null) return;
    final (lat, lng) = coordinates;
    // The geo: scheme reaches whatever maps app the platform has; the https
    // fallback covers a desktop with none registered.
    final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final web = Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng');
    final opened = await launchUrl(
      geo,
      mode: LaunchMode.externalApplication,
    ).onError((_, _) => false);
    if (!opened) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final coordinates = _coordinates;
    final label = coordinates == null
        ? 'Location'
        : '${coordinates.$1.toStringAsFixed(5)}, '
              '${coordinates.$2.toStringAsFixed(5)}';

    return WeftFocusable(
      button: coordinates != null,
      onTap: coordinates == null ? null : () => _open(context),
      label: semanticsSentence(['Shared location', label, 'opens in maps']),
      borderRadius: WeftRadius.allSm,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_on_rounded, size: 28, color: onBubble),
          const SizedBox(width: WeftSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Location',
                style: context.text.bodyMedium?.copyWith(
                  color: onBubble,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                coordinates == null ? message.body : '$label · open in maps',
                style: context.text.labelSmall?.copyWith(
                  color: palette.mutedOnBubble(own),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A poll: the question, one tappable row per option, and the running tally.
///
/// Disclosed results, which is what bridges send: every row shows its count
/// and the bar behind it is the share of votes. Tapping votes (or re-votes —
/// MSC3381 counts each voter's latest response); a closed poll ignores taps.
class _PollContent extends StatelessWidget {
  const _PollContent({
    required this.message,
    required this.own,
    required this.onVote,
  });

  final WeftMessage message;
  final bool own;
  final ValueChanged<String> onVote;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final poll = message.poll!;
    final total = poll.totalVotes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.poll_rounded, size: 18, color: onBubble),
            const SizedBox(width: WeftSpace.sm),
            Flexible(
              child: Text(
                poll.question,
                style: context.text.bodyMedium?.copyWith(
                  color: onBubble,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: WeftSpace.sm),
        for (final option in poll.options) ...[
          _PollOptionRow(
            option: option,
            votes: poll.votes[option.id] ?? 0,
            total: total,
            chosen: poll.ownVotes.contains(option.id),
            ended: poll.ended,
            own: own,
            onTap: poll.ended ? null : () => onVote(option.id),
          ),
          const SizedBox(height: WeftSpace.xs),
        ],
        Text(
          poll.ended
              ? 'Final result · $total vote${total == 1 ? '' : 's'}'
              : '$total vote${total == 1 ? '' : 's'}',
          style: context.text.labelSmall?.copyWith(
            color: palette.mutedOnBubble(own),
          ),
        ),
      ],
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  const _PollOptionRow({
    required this.option,
    required this.votes,
    required this.total,
    required this.chosen,
    required this.ended,
    required this.own,
    this.onTap,
  });

  final PollOption option;
  final int votes;
  final int total;
  final bool chosen;
  final bool ended;
  final bool own;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final share = total == 0 ? 0.0 : votes / total;

    return WeftFocusable(
      button: onTap != null,
      onTap: onTap,
      label: semanticsSentence([
        option.text,
        '$votes vote${votes == 1 ? '' : 's'}',
        if (chosen) 'your vote',
        if (ended) 'poll closed' else if (onTap != null) 'tap to vote',
      ]),
      borderRadius: WeftRadius.allSm,
      child: Stack(
        children: [
          // The share bar, behind the words.
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: share.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: onBubble.withValues(alpha: 0.15),
                  borderRadius: WeftRadius.allSm,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.sm,
              vertical: WeftSpace.sm,
            ),
            child: Row(
              children: [
                Icon(
                  chosen ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 16,
                  color: onBubble,
                ),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    option.text,
                    style: context.text.bodySmall?.copyWith(color: onBubble),
                  ),
                ),
                Text(
                  '$votes',
                  style: context.text.labelSmall?.copyWith(
                    color: palette.mutedOnBubble(own),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Question plus two-to-eight options; pops `(question, options)` or null.
class _PollComposerDialog extends StatefulWidget {
  const _PollComposerDialog();

  @override
  State<_PollComposerDialog> createState() => _PollComposerDialogState();
}

class _PollComposerDialogState extends State<_PollComposerDialog> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];

  @override
  void dispose() {
    _question.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final question = _question.text.trim();
    final options = [
      for (final option in _options)
        if (option.text.trim().isNotEmpty) option.text.trim(),
    ];
    if (question.isEmpty || options.length < 2) return;
    Navigator.of(context).pop((question, options));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New poll'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _question,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Question'),
              ),
              const SizedBox(height: WeftSpace.sm),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.sm),
                  child: TextField(
                    controller: _options[i],
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: 'Option ${i + 1}'),
                  ),
                ),
              if (_options.length < 8)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add option'),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create poll')),
      ],
    );
  }
}

/// A proposed calendar entry, with the negotiation the sender asked for.
///
/// The receiving side can accept — which also opens their device calendar,
/// because that is what accepting *means* — decline, or propose another time.
/// The sender watches the answers arrive, and a proposed new time comes with
/// a one-tap "invite again at that time".
class _CalendarInviteContent extends StatelessWidget {
  const _CalendarInviteContent({
    required this.message,
    required this.own,
    this.onRespond,
    this.onAddToCalendar,
    this.onEditTime,
  });

  final WeftMessage message;
  final bool own;
  final void Function(CalendarReply reply, DateTime? proposedStart)? onRespond;

  /// Puts the proposal into the device calendar. On every card: the sender
  /// wants their own proposal in their calendar too.
  final VoidCallback? onAddToCalendar;

  /// Sender only: moves the proposal, sent as an edit.
  final VoidCallback? onEditTime;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final invite = message.calendarInvite!;
    final when = DateFormat.yMMMEd().add_Hm().format(invite.start);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          excludeSemantics: true,
          label: semanticsSentence(['Calendar invitation', invite.title, when]),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_rounded, size: 26, color: onBubble),
              const SizedBox(width: WeftSpace.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      invite.title,
                      style: context.text.bodyMedium?.copyWith(
                        color: onBubble,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      when,
                      style: context.text.labelSmall?.copyWith(
                        color: palette.mutedOnBubble(own),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // The answers, one line each — who, what, and any new time proposed.
        for (final response in invite.responses)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Text(switch (response.reply) {
              CalendarReply.accepted => '✓ ${response.senderName} accepted',
              CalendarReply.declined => '✕ ${response.senderName} declined',
              CalendarReply.reschedule =>
                '↻ ${response.senderName} suggests '
                    '${response.proposedStart == null ? 'another time' : DateFormat.MMMEd().add_Hm().format(response.proposedStart!)}',
            }, style: context.text.labelSmall?.copyWith(color: onBubble)),
          ),
        if (onRespond != null && !own) ...[
          const SizedBox(height: WeftSpace.sm),
          Wrap(
            spacing: WeftSpace.sm,
            children: [
              FilledButton.tonal(
                onPressed: () => onRespond!(CalendarReply.accepted, null),
                child: const Text('Accept'),
              ),
              OutlinedButton(
                onPressed: () => onRespond!(CalendarReply.declined, null),
                child: const Text('Decline'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final when = await _ChatViewState._pickDateTime(
                    context,
                    from: DateTime.now(),
                  );
                  if (when != null) {
                    onRespond!(CalendarReply.reschedule, when);
                  }
                },
                child: const Text('New time'),
              ),
            ],
          ),
        ],
        // The sender's own card used to be inert — nothing happened on tap,
        // which read as broken. Its verbs: into my calendar, or move it.
        if (own && (onAddToCalendar != null || onEditTime != null)) ...[
          const SizedBox(height: WeftSpace.sm),
          Wrap(
            spacing: WeftSpace.sm,
            children: [
              if (onAddToCalendar != null)
                FilledButton.tonalIcon(
                  onPressed: onAddToCalendar,
                  icon: const Icon(Icons.event_available_rounded, size: 16),
                  label: const Text('Add to calendar'),
                ),
              if (onEditTime != null)
                OutlinedButton.icon(
                  onPressed: onEditTime,
                  // Explicit ink: the theme's outlined-button colours are
                  // picked for the surface, and on the sender's filled bubble
                  // they vanished into it — a pill with no visible label.
                  style: OutlinedButton.styleFrom(
                    foregroundColor: onBubble,
                    side: BorderSide(color: onBubble.withValues(alpha: 0.55)),
                  ),
                  icon: const Icon(Icons.edit_calendar_rounded, size: 16),
                  label: const Text('Change time'),
                ),
            ],
          ),
        ],
        // The sender's shortcut: someone proposed a time, make it the plan.
        if (onRespond != null && own)
          for (final response in invite.responses)
            if (response.reply == CalendarReply.reschedule &&
                response.proposedStart != null)
              Padding(
                padding: const EdgeInsets.only(top: WeftSpace.sm),
                child: OutlinedButton.icon(
                  onPressed: () => onRespond!(
                    CalendarReply.accepted,
                    response.proposedStart,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: onBubble,
                    side: BorderSide(color: onBubble.withValues(alpha: 0.55)),
                  ),
                  icon: const Icon(Icons.update_rounded, size: 16),
                  label: Text(
                    'Use ${DateFormat.MMMEd().add_Hm().format(response.proposedStart!)}',
                  ),
                ),
              ),
      ],
    );
  }
}
