import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
// `SelectionArea` reports what it holds as a `SelectedContent`, which lives in
// the rendering layer and is not re-exported by `material.dart`.
import 'package:flutter/rendering.dart' show SelectedContent;
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
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/notification_providers.dart';
import '../../app/providers.dart';
import '../../app/retention_providers.dart';
import '../../app/share_providers.dart';
import '../../app/shortcuts.dart';
import '../../app/transcription_service.dart';
import '../../data/chat_repository.dart';
import '../../services/attachments/attachment_picker.dart';
import '../../services/attachments/send_attachments.dart';
import '../../services/audio/voice_player.dart';
import '../../services/audio/voice_recorder.dart';
import '../../services/attachments/clipboard_images.dart';
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
import 'thread_indicator.dart';
import 'voice_recording_bar.dart';
import 'sms_composer_bar.dart';
import 'unverified_devices_banner.dart';

/// One conversation — merged across networks or not.
///
/// The timeline is driven by [MergedTimeline], so a merged chat and a plain one
/// take exactly the same code path; a plain chat is simply a merge of one.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({
    super.key,
    required this.chatId,
    this.initialEventId,
    this.preview = false,
    this.threadRootId,
  });

  final String chatId;

  /// Renders one thread of this conversation rather than the whole room.
  ///
  /// The same widget rather than a screen of its own, and that is the point:
  /// everything a thread needs — the bubbles, the actions, the reactions, the
  /// composer, the attachment path, the jump-to-reply — is the machinery below,
  /// and a second implementation would be three thousand lines that drift. What
  /// changes is which messages are shown, where a sent message lands, and what
  /// the bar says.
  ///
  /// The root is included in the view. A thread opened without the message it
  /// hangs off is a set of answers to a missing question.
  final String? threadRootId;

  /// A look at the conversation that does not count as having read it.
  ///
  /// Opening a chat marks it read and clears its notification, which is right
  /// — and is exactly what someone checking "who was that?" does not want,
  /// because the unread marker is the only record of what they still owe an
  /// answer to. A preview reads the same timeline through the same widget and
  /// changes nothing: no read receipt, no notification dismissed, no composer,
  /// and no action on any message.

  final bool preview;

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

  /// What is selected across the thread, on a machine that can select.
  ///
  /// Held rather than read on demand because `SelectableRegion` has no public
  /// way to ask; the callback is the API. Deliberately not `setState` — this
  /// changes on every pointer move during a drag, and rebuilding the whole
  /// conversation at that rate would be a dropped frame per message. Nothing
  /// on screen depends on it; only ⌘C reads it, and it reads it late.
  SelectedContent? _selection;

  bool get _hasSelection => (_selection?.plainText.trim().isNotEmpty ?? false);

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
    // A conversation left before it arrived.
    _stopWaitingForChat();
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
    final chatId = _chatId;
    _timelineChatId = chatId;
    try {
      // Before the timeline is built, not after: a self-deleting chat that
      // came due while the app was closed would otherwise draw the messages
      // first and blink them away a frame later. The sweeper returns
      // immediately for a chat with no policy, which is nearly every chat.
      await ref.read(retentionSweeperProvider)?.sweepChat(chatId);
      if (!mounted) return;
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
      // The one thing a preview must not do. Everything else about this
      // screen is the same in both modes, which is the point of the flag.
      if (!widget.preview) _readConversation(chatId);
      await _loadOlder();
      if (widget.initialEventId != null) await _jumpTo(widget.initialEventId!);
      await _reachThreadRoot();
    } on ArgumentError {
      if (!mounted) return;
      // Not gone — not *yet*. This is the cold-start case, and a notification
      // tap is how it is reached: the link routes straight here while the
      // inbox is still being folded together, so the conversation the link
      // names turns up a moment *after* the screen has asked for it. Giving
      // the verdict on the first look is what put "not in your inbox" over a
      // chat that was about to be there, on every tap of a notification that
      // had cold-started Braid.
      //
      // Waiting draws as the same spinner an unsynced chat already shows, and
      // the wait is bounded: a link that is genuinely stale still says so, a
      // couple of seconds later.
      final arrived = await _awaitChatArrival(chatId);
      // A conversation opened *over* this one while the wait ran — a merge
      // re-pointing the view, the desktop's second pane moving on — owns the
      // screen now, and this attempt has nothing left to say about it.
      if (!mounted || _timelineChatId != chatId) return;
      if (arrived) {
        await _open();
        return;
      }
      setState(() => _unavailable = context.l10n.chatUnavailableNotInInbox);
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _unavailable = e.message);
    }
  }

  /// How long a conversation has to appear before the screen calls it missing.
  ///
  /// Long enough to cover a cold start — the inbox rebuild is debounced to
  /// 1.5s while the first sync storm lands — and short enough that a link to a
  /// room the account really has left is answered rather than spun on.
  static const _chatArrivalGrace = Duration(seconds: 8);

  /// The conversation [_awaitChatArrival] has already waited for.
  ///
  /// One wait per id: once the inbox has produced it, a later failure to open
  /// it is a real absence and not a slow start, and a second wait would only
  /// put the spinner back over an answer the user already has.
  String? _awaitedChatId;

  StreamSubscription<List<Chat>>? _arrivalSub;
  Timer? _arrivalTimer;
  Completer<bool>? _arrival;

  /// Ends a wait in progress, answering "not there" to whoever is holding it.
  ///
  /// Called on dispose as well as on every outcome: a wait that outlived its
  /// screen would keep a chat-list subscription open for an answer nothing is
  /// going to read, and leave [_open] suspended forever on a completer no one
  /// completes.
  void _stopWaitingForChat({bool arrived = false}) {
    _arrivalTimer?.cancel();
    _arrivalTimer = null;
    unawaited(_arrivalSub?.cancel());
    _arrivalSub = null;
    final arrival = _arrival;
    _arrival = null;
    if (arrival != null && !arrival.isCompleted) arrival.complete(arrived);
  }

  /// Whether [chatId] turned up in the inbox within [_chatArrivalGrace].
  ///
  /// Matched on the room ids too, not only on [Chat.id]: a deep link carries
  /// the id the chat had when the link was made, and a merge since then —
  /// or one that lands as part of the very sync being waited for — folds that
  /// room into a `merged:` conversation under a different id. [_chatId]
  /// re-resolves it on the retry; this only has to notice it is there.
  Future<bool> _awaitChatArrival(String chatId) {
    // Two opens of the same conversation can race — the chat-list heartbeat
    // reopens, and so does a rebuilt route — and they wait on one answer
    // rather than one of them being told "not there" while the other is still
    // looking.
    final pending = _arrival;
    if (_awaitedChatId == chatId) {
      return pending?.future ?? Future.value(false);
    }
    // The inbox already holds it, so its absence is not what the open
    // stumbled on and waiting would wait for something that is here. Answer
    // rather than retry.
    final known = ref.read(chatsProvider).value ?? const <Chat>[];
    if (known.any((c) => c.id == chatId || c.roomIds.contains(chatId))) {
      return Future.value(false);
    }
    _stopWaitingForChat();
    _awaitedChatId = chatId;

    final arrival = _arrival = Completer<bool>();
    _arrivalSub = ref
        .read(chatRepositoryProvider)
        .watchChats()
        .listen(
          (chats) {
            final held = chats.any(
              (c) => c.id == chatId || c.roomIds.contains(chatId),
            );
            if (held) _stopWaitingForChat(arrived: true);
          },
          // A chat list that ends or fails is never going to produce it, and
          // sitting out the grace period for a stream that has stopped
          // talking only delays the same answer.
          onDone: _stopWaitingForChat,
          onError: (Object _) => _stopWaitingForChat(),
        );
    _arrivalTimer = Timer(_chatArrivalGrace, _stopWaitingForChat);
    return arrival.future;
  }

  /// Pages back until the open thread's root is loaded, or gives up and says so.
  ///
  /// A thread is opened from an indicator, so the root was on screen a moment
  /// ago — but the thread view is a *fresh* timeline, paginated from the newest
  /// end, and a topic whose first message was posted a thousand messages ago is
  /// a long way back from there. Without this the screen opens on the replies
  /// alone, which reads as a set of answers to a missing question.
  ///
  /// Bounded, and the bound has a rendered outcome rather than a silent one: a
  /// root that has been redacted, or that is older than the history the server
  /// still holds, is never going to arrive, and a view that paged for it
  /// forever would spin on a thread the user cannot open.
  Future<void> _reachThreadRoot({int maxRounds = 40}) async {
    final rootId = widget.threadRootId;
    final timeline = _timeline;
    if (rootId == null || timeline == null) return;

    var rounds = 0;
    while (!_view.messages.any((m) => m.eventId == rootId) &&
        timeline.hasMoreHistory &&
        rounds++ < maxRounds) {
      final next = await timeline.loadMoreUntilVisibleGrowth();
      if (!mounted) return;
      setState(() => _view = next);
    }

    if (!mounted || _view.messages.any((m) => m.eventId == rootId)) return;
    setState(() => _unavailable = context.l10n.threadUnavailable);
  }

  /// Marks the open conversation read and takes it down everywhere else.
  ///
  /// Here rather than on the inbox tile that used to own it, because the tile
  /// is only one of the doors: a notification tap routes through the deep-link
  /// handler straight to this screen, a deeplink does the same, and a
  /// conversation the user is reading kept both its badge and its row in the
  /// shade. The badge outliving the visit is also why a reply looked like it
  /// had marked the chat unread — the count was the old one, still standing.
  ///
  /// The clear goes through [ConversationClearer] rather than straight to the
  /// dismisser, because the shade is only one of three surfaces showing this
  /// conversation: the watch and the home screen widget read the snapshot, and
  /// they clear by it being republished rather than by anything being
  /// cancelled. A phone that looks caught up while the wrist keeps buzzing is
  /// worse than one that clears nothing.
  ///
  /// Both calls are fire-and-forget: a receipt that fails to reach the
  /// homeserver must not stop the messages from being drawn. The clear is
  /// sequenced *after* the read so the republished snapshot is built from a
  /// chat list that already has the count at zero.
  void _readConversation(String chatId) {
    final clearer = ref.read(conversationClearerProvider);
    unawaited(
      ref
          .read(chatRepositoryProvider)
          .markRead(chatId)
          .catchError(
            (Object error) =>
                debugPrint('weft: could not mark $chatId read: $error'),
          )
          .whenComplete(() => clearer.clear(chatId)),
    );
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
        : context.l10n.messageKind(newest.kind);
    announce(
      context,
      semanticsSentence([
        context.l10n.chatNewMessageFrom(newest.senderName),
        if (merged) context.l10n.chatOnNetwork(newest.network.label),
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

    // Auto-transcription rides the same "something new is on screen" moment.
    // The service applies its own gates — the setting, a configured or local
    // model, a per-call cap, and in-flight/failed bookkeeping — so this call
    // is cheap when there is nothing to do. It had never been wired: the
    // setting, the cap and the plumbing all existed, and nothing ever called
    // it, which read as "automatic transcription stopped working".
    unawaited(
      ref
          .read(transcriptionServiceProvider)
          .autoTranscribe(
            messages.take(12).toList(growable: false),
            onEach: () {
              if (mounted) setState(() {});
            },
          )
          .catchError((Object error) {
            debugPrint('weft: auto-transcribe pass failed: $error');
          }),
    );

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
    final failed = context.l10n.chatActionFailed;
    try {
      await action();
    } on Object catch (error) {
      debugPrint('weft: message action failed: $error');
      _showMessage(failed);
      return;
    }
    _refresh();
  }

  /// The loaded timeline split into room-level messages and the threads under
  /// them.
  ///
  /// Derived on every build rather than cached beside [_view], because it is a
  /// pure function of the view and the read markers and those move
  /// independently: a receipt arriving from another device changes what is
  /// unread without changing a single message, and a cache keyed on the view
  /// would go on claiming three new replies in a topic the user has read
  /// elsewhere.
  ///
  /// Flattened outright for a conversation on a network with no thread concept.
  /// A Signal chat can still carry `m.thread` relations — a Matrix user in the
  /// room threaded a reply, and the bridge relayed the text without the
  /// relation ever meaning anything on Signal's side — and hiding those replies
  /// behind an indicator would put messages somewhere no participant on that
  /// network can reach.
  ThreadGrouping _threadGrouping(Chat chat) {
    if (!chat.networks.any(networkSupportsThreads)) {
      return ThreadGrouping.flatten(_view.messages);
    }
    return groupThreads(messages: _view.messages, readUpTo: _ownReadAt());
  }

  /// The newest point this account has read to, across every leg.
  ///
  /// One timestamp for a merged chat rather than one per room: a thread lives
  /// in exactly one room, so the marker for its own room is the one that
  /// matters, and taking the newest of them is wrong only in the case where the
  /// user has read one leg and not another — which understates the unread
  /// count rather than inventing one. Overstating it is the failure that
  /// matters: a topic badged as new that the user has already read is a badge
  /// they learn to ignore.
  DateTime? _ownReadAt() {
    DateTime? newest;
    for (final marker
        in ref.read(chatRepositoryProvider).ownReadUpTo(_chatId)) {
      if (newest == null || marker.at.isAfter(newest)) newest = marker.at;
    }
    return newest;
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

  Future<void> _openActions(WeftMessage message, {Offset? at}) async {
    final choice = context.hasPointer && at != null
        ? await showDesktopMessageMenu(
            context,
            position: at,
            message: message,
            canTranscribe: message.canTranscribe,
            hasTranscript: message.transcript != null,
            homeAssistant: ref.read(homeAssistantProvider) != null,
          )
        : await showMessageActionsSheet(
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
        // The selection first, when there is one. Right-clicking a phrase you
        // have just dragged across and choosing Copy means that phrase; the
        // whole message is what Copy means when nothing is selected, which on
        // a phone is always.
        await _copySelectionOr(message);
      case MessageAction.selectText:
        await _selectText(message);
      case MessageAction.retrySend:
        await _run(
          () => ref
              .read(chatRepositoryProvider)
              .retryFailedSend(message.roomId, message.eventId),
        );
      case MessageAction.discardSend:
        await _run(
          () => ref
              .read(chatRepositoryProvider)
              .discardFailedSend(message.roomId, message.eventId),
        );
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
    final l10n = context.l10n;
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
      _showMessage(l10n.chatSentToHomeAssistant);
    } on Object catch (error) {
      _showMessage(l10n.chatHomeAssistantRefused('$error'));
    }
  }

  /// "Remind me": a handful of natural offsets, then the OS carries it.
  Future<void> _remindLater(WeftMessage message) async {
    final now = DateTime.now();
    final tonight = DateTime(now.year, now.month, now.day, 19);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
    final l10n = context.l10n;
    final choice = await showWeftPanel<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: Text(context.l10n.chatRemindInOneHour),
              onTap: () =>
                  Navigator.of(context).pop(now.add(const Duration(hours: 1))),
            ),
            if (tonight.isAfter(now))
              ListTile(
                leading: const Icon(Icons.nights_stay_outlined),
                title: Text(context.l10n.chatRemindThisEvening),
                onTap: () => Navigator.of(context).pop(tonight),
              ),
            ListTile(
              leading: const Icon(Icons.wb_sunny_outlined),
              title: Text(context.l10n.chatRemindTomorrowMorning),
              onTap: () => Navigator.of(context).pop(tomorrow),
            ),
            ListTile(
              leading: const Icon(Icons.edit_calendar_rounded),
              title: Text(context.l10n.chatRemindPickTime),
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
          title: l10n.chatReminderTitle(
            message.isOwn ? l10n.chatReminderSelf : message.senderName,
          ),
          body: preview.length > 120
              ? '${preview.substring(0, 117)}…'
              : preview,
          at: choice,
        );
    if (mounted) {
      _showMessage(
        l10n.chatWillRemindAt(DateFormat.MMMEd().add_Hm().format(choice)),
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
    final copied = context.l10n.chatCopiedToClipboard;
    final text = messageDocument(message).plainText;
    await Clipboard.setData(ClipboardData(text: text));
    _showMessage(copied);
  }

  /// ⌘C, which is one key meaning two things.
  ///
  /// A selection wins wherever the focus happens to be: someone who has just
  /// dragged across three messages and pressed Copy means those three, not the
  /// one bubble the focus ring is on. With nothing selected it falls back to
  /// [_copy] — the same whole-message copy the actions sheet has always
  /// offered, and the only thing ⌘C can sensibly mean when [message] is the
  /// only thing the reader has pointed at.
  ///
  /// The selection's own text, not a re-projection of it: `SelectedContent`
  /// carries what the renderer laid out, so a mention pill copies as "Anna" —
  /// its `Text` holds the display name and never the mxid — and a code block
  /// copies with its indentation intact.
  Future<void> _copySelectionOr(WeftMessage? message) async {
    final selected = _selection?.plainText.trim() ?? '';
    if (selected.isEmpty) {
      if (message != null) await _copy(message);
      return;
    }
    final copied = context.l10n.chatCopiedToClipboard;
    await Clipboard.setData(ClipboardData(text: selected));
    _showMessage(copied);
  }

  /// The message list, made selectable on a machine that has a pointer.
  ///
  /// A [SelectionArea] around the *list* rather than a `SelectableText` per
  /// bubble, because the thing desktop users actually do is drag across an
  /// exchange and copy both halves of it — a per-bubble selectable cannot span
  /// two messages, and would also break the moment a message held a link, a
  /// mention pill or a code block, none of which are plain text.
  ///
  /// The keyboard wrapper goes outside the area, not inside: `SelectableRegion`
  /// takes focus when a selection starts, so its node has to be *under* the
  /// [Shortcuts] for ⌘C to be seen at all. It is scoped to the list and not to
  /// the screen so the composer keeps the framework's own copy for its caret.
  Widget _selectableMessages(Widget list) {
    if (!context.hasPointer) return list;
    return Shortcuts(
      shortcuts: messageCopyShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          // Disabled with nothing selected, so the key carries on to the
          // focused bubble's own handler — or, failing that, out of the chat
          // entirely — rather than being swallowed here.
          CopyMessageIntent: WeftGuardedAction<CopyMessageIntent>(
            onInvoke: () => unawaited(_copySelectionOr(null)),
            enabled: () => _hasSelection,
          ),
        },
        child: SelectionArea(
          onSelectionChanged: (content) => _selection = content,
          child: list,
        ),
      ),
    );
  }

  /// When the other side read [message] — set only on the newest own message,
  /// which is the one place a "Seen" line carries information rather than
  /// noise down the whole column.
  /// What the ticks under [message] should say.
  ///
  /// Matrix has no delivery receipts, only read ones, so the mapper can never
  /// produce [DeliveryState.read] — it stops at `delivered` the moment the
  /// server echoes the event. The receipts are right here though, and without
  /// folding them in the two ticks meant "not failed" and nothing else, which
  /// is not what anyone looks at them for.
  DeliveryState? _effectiveDelivery(WeftMessage message, Chat chat) {
    if (!message.isOwn) return message.deliveryState;
    return resolveDeliveryState(
      reported: message.deliveryState,
      // The *message's* network, not the chat's. A merged conversation sends
      // over whichever leg last spoke, and an SMS message in a chat that also
      // has WhatsApp must not borrow WhatsApp's blue ticks.
      network: message.network,
      readerCount: _readersOf(message),
      peerCount: chat.peerCount,
      receiptsEnabled: ref.watch(sendReadReceiptsProvider),
    );
  }

  /// How many distinct peers' read receipts cover [message].
  ///
  /// Counted rather than answered as a boolean, because in a group the number
  /// is the whole question: blue ticks mean *everyone* has read it, and "at
  /// least one person did" is the thing that made the mark useless in the
  /// conversations it is most looked at.
  ///
  /// Scoped to the message's own room. A merged chat's other legs hold receipts
  /// from the same person under a different ghost id, and counting those would
  /// let one reader on three networks satisfy a group of three.
  int _readersOf(WeftMessage message) {
    final readers = <String>{};
    for (final marker
        in ref.read(chatRepositoryProvider).peerReadUpTo(_chatId)) {
      if (marker.roomId != message.roomId) continue;
      if (marker.eventId == message.eventId) {
        readers.add(marker.userId);
        continue;
      }
      // The receipt names some other event; if that event sits at or after
      // ours in the same room, ours has been read on the way past.
      final receipted = _view.messages
          .where(
            (m) => m.eventId == marker.eventId && m.roomId == marker.roomId,
          )
          .firstOrNull;
      if (receipted != null &&
          !receipted.timestamp.isBefore(message.timestamp)) {
        readers.add(marker.userId);
      }
    }
    return readers.length;
  }

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

  static String _seenLabel(AppL10n l10n, DateTime at) {
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? l10n.chatSeenAtTime(DateFormat.Hm().format(at))
        : l10n.chatSeenOnDate(DateFormat.MMMEd().add_Hm().format(at));
  }

  /// The message in a view where a *part* of it can be selected and copied —
  /// long-press on the bubble acts on the whole message, so partial copy
  /// lives here.
  Future<void> _selectText(WeftMessage message) async {
    final text = messageDocument(message).plainText;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.messageActionSelectText),
        content: SingleChildScrollView(
          child: SelectableText(text, style: context.text.bodyMedium),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonDone),
          ),
        ],
      ),
    );
  }

  Future<void> _addInviteToCalendar(WeftMessage message) async {
    final invite = message.calendarInvite;
    if (invite == null) return;
    final failed = context.l10n.chatCalendarOpenFailed;
    try {
      await addToDeviceCalendar(
        title: invite.title,
        start: invite.start,
        end: invite.end,
      );
    } on Object catch (error) {
      debugPrint('weft: add to calendar failed: $error');
      _showMessage(failed);
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

  Future<void> _pickReaction(
    WeftMessage message, {
    BuildContext? anchor,
  }) async {
    final key = await showEmojiPickerSheet(context, anchorContext: anchor);
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
    final l10n = context.l10n;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    if (linkLabelMisleads(label, uri) && !await _confirmLink(url)) return;

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showMessage(l10n.chatLinkNoHandler);
    } on Object catch (error) {
      // Deliberately Object: a platform with no handler registered throws out
      // of the method channel rather than answering false.
      debugPrint('weft: could not open $url: $error');
      _showMessage(l10n.chatLinkNoHandler);
    }
  }

  Future<bool> _confirmLink(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.chatConfirmLinkTitle),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.chatConfirmLinkBody),
            const SizedBox(height: WeftSpace.sm),
            SelectableText(url, style: context.text.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.commonOpen),
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
      //
      // With a bar, because this is where a deep link waits: a conversation
      // that has not arrived holds this screen for as long as
      // [_chatArrivalGrace], and a full-screen spinner with no way off it is
      // not somewhere to leave someone who tapped the wrong notification.
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Read once for the whole list rather than per bubble: it is a settings
    // lookup, and the ticks under a hundred messages ask the same question.
    final receiptsEnabled = ref.watch(sendReadReceiptsProvider);
    final grouping = _threadGrouping(chat);
    // What the list actually draws. In the room it is the flat timeline with
    // thread replies folded away behind their roots' indicators; in a thread it
    // is that one thread, newest first — reversed here rather than in
    // `threadMessages`, which returns reading order, because the list widget
    // below is itself reversed.
    final rootId = widget.threadRootId;
    final visible = rootId == null
        ? grouping.messages
        : threadMessages(
            messages: _view.messages,
            rootEventId: rootId,
          ).reversed.toList(growable: false);

    // After the frame rather than during it: an announcement is a platform call
    // and a build is not the place to make one, and the message being announced
    // has to be on screen by the time a reader goes looking for it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _announceIncoming(_view.messages, merged: chat.isMerged);
    });

    return Scaffold(
      backgroundColor: context.colors.surfaceContainerLowest,
      // A thread gets a bar of its own rather than the room's. The room's
      // carries a call button, a search and the contact's face, and every one
      // of those is about the conversation rather than about the topic the
      // reader has opened — a call started from inside "Bugs" is a call to the
      // whole group, which is not what the button appears to offer there.
      appBar: rootId == null
          ? _ChatAppBar(
              chat: chat,
              mac: context.isMac,
              typing: _typing,
              online: _peerOnline,
              preview: widget.preview,
            )
          : _ThreadAppBar(chat: chat, title: _threadTitleFor(rootId, grouping)),
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
                    // A window is not a phone, and a bubble run to the full
                    // width of one is unreadable: the eye has to travel back
                    // across a 27" display for every line. Every desktop
                    // messenger caps this, and the cap is what stops a wide
                    // window from looking like a stretched phone screen.
                    child: _ReadingColumn(
                      enabled: context.isMac,
                      child: _selectableMessages(
                        ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: WeftSpace.lg,
                            vertical: WeftSpace.md,
                          ),
                          itemCount:
                              (_typing.isEmpty ? 0 : 1) +
                              uploads.length +
                              visible.length +
                              1,
                          itemBuilder: (context, index) {
                            // The list is reversed, so index 0 is the bottom of
                            // the screen — which is where someone typing belongs,
                            // under the last thing they said.
                            if (_typing.isNotEmpty) {
                              if (index == 0) {
                                return _TypingBubble(
                                  names: _typing,
                                  isGroup: chat.isGroup,
                                );
                              }
                              index -= 1;
                            }
                            if (index < uploads.length) {
                              // Reversed: index 0 is the newest, and the newest upload is
                              // the last one enqueued.
                              return _uploadBubble(
                                chat,
                                uploads[uploads.length - 1 - index],
                              );
                            }
                            final i = index - uploads.length;
                            if (i == visible.length) {
                              return _historyFooter();
                            }
                            var message = visible[i];
                            // Transcripts arrive after the event was mapped; overlay the
                            // session cache so a finished transcription shows in place.
                            final cachedTranscript = ref
                                .watch(transcriptionServiceProvider)
                                .cached(
                                  message.eventId,
                                  roomId: message.roomId,
                                );
                            if (cachedTranscript != null &&
                                message.transcript == null) {
                              message = message.copyWith(
                                transcript: cachedTranscript.text,
                              );
                            }
                            final older = i + 1 < visible.length
                                ? visible[i + 1]
                                : null;
                            // One message, one line in anything copied out of
                            // a drag across several of them — the alternative
                            // is `Hello thereSee you at six`, which is what a
                            // `SelectionArea` does with two children left to
                            // itself.
                            return WeftSelectionLine(
                              child: Column(
                                key: _messageKeys.putIfAbsent(
                                  message.eventId,
                                  GlobalKey.new,
                                ),
                                children: [
                                  if (_needsDayDivider(message, older))
                                    _DayDivider(date: message.timestamp),
                                  _SwipeToReply(
                                    enabled:
                                        !widget.preview && !message.redacted,
                                    onReply: () => _enterComposerContext(
                                      ComposerContext.reply(message),
                                    ),
                                    child: _MessageBubble(
                                      message: message,
                                      delivery: _effectiveDelivery(
                                        message,
                                        chat,
                                      ),
                                      deliveryIsComplete:
                                          deliveryStateIsComplete(
                                            state: _effectiveDelivery(
                                              message,
                                              chat,
                                            ),
                                            network: message.network,
                                            receiptsEnabled: receiptsEnabled,
                                          ),
                                      replyPreview: _replyPreviewFor(message),
                                      highlighted:
                                          message.eventId == _highlightEventId,
                                      transcribing: _transcribing.contains(
                                        message.eventId,
                                      ),
                                      onOpen:
                                          !widget.preview &&
                                              rendersAsAttachment(message)
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
                                      onActions: widget.preview
                                          ? null
                                          : () => _openActions(message),
                                      onActionsAt: widget.preview
                                          ? null
                                          : (position) => unawaited(
                                              _openActions(
                                                message,
                                                at: position,
                                              ),
                                            ),
                                      onCopy: widget.preview
                                          ? null
                                          : () => unawaited(
                                              _copySelectionOr(message),
                                            ),
                                      onQuickReply: widget.preview
                                          ? null
                                          : () => _enterComposerContext(
                                              ComposerContext.reply(message),
                                            ),
                                      onQuickReact: widget.preview
                                          ? null
                                          : (anchor) => unawaited(
                                              _pickReaction(
                                                message,
                                                anchor: anchor,
                                              ),
                                            ),
                                      onJumpToReply: (eventId) =>
                                          _jumpTo(eventId),
                                      onToggleReaction: widget.preview
                                          ? null
                                          : (tally) =>
                                                _toggleReaction(message, tally),
                                      onAddReaction: widget.preview
                                          ? null
                                          : (anchor) => _pickReaction(
                                              message,
                                              anchor: anchor,
                                            ),
                                      onShowReactionSenders: (tally) =>
                                          showReactionSendersSheet(
                                            context,
                                            tally: tally,
                                            nameFor: _nameFor,
                                          ),
                                      onTapLink: _openLink,
                                      onTapMention: _openMention,
                                      // Null inside a thread: the root is the
                                      // thing being read, and an indicator on it
                                      // would be a way back to where the reader
                                      // already is.
                                      thread: rootId == null
                                          ? grouping.threadFor(message)
                                          : null,
                                      onOpenThread: widget.preview
                                          ? null
                                          : () => _openThread(message.eventId),
                                      onRespondInvite:
                                          message.calendarInvite == null
                                          ? null
                                          : (reply, proposedStart) =>
                                                _respondInvite(
                                                  message,
                                                  reply,
                                                  proposedStart,
                                                ),
                                      onAddInviteToCalendar:
                                          message.calendarInvite == null
                                          ? null
                                          : () => _addInviteToCalendar(message),
                                      onEditInvite:
                                          message.calendarInvite == null
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
                                      // Same *person*, not merely the same side
                                      // of the thread. Without the sender check a
                                      // group ran two people's messages together
                                      // whenever they landed within five minutes,
                                      // and the second one lost its name — so a
                                      // reply from someone else read as a second
                                      // line from whoever spoke first, which is
                                      // the one thing a group chat must never get
                                      // wrong.
                                      groupedWithPrevious:
                                          older != null &&
                                          older.senderId == message.senderId &&
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
                                        alignment:
                                            AlignmentDirectional.centerEnd,
                                        child: Text(
                                          _seenLabel(context.l10n, seen),
                                          style: context.text.labelSmall
                                              ?.copyWith(
                                                color: context
                                                    .colors
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // A preview is a look, not a place to answer from: no composer,
              // and none of the state that hangs off one.
              if (!widget.preview) _ScheduledSendsBar(chatId: _chatId),
              if (!widget.preview)
                FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _recording
                      ? VoiceRecordingBar(
                          onCancel: () => setState(() => _recording = false),
                          onSend: (recording) =>
                              _sendVoiceNote(chat, recording),
                        )
                      : _Composer(
                          chat: chat,
                          controller: _composer,
                          focusNode: _composerFocus,
                          composing: _composerContext,
                          onCancelContext: _cancelComposerContext,
                          onSend: _send,
                          onAttach: () => _attach(chat),
                          onPaste: () => unawaited(_paste(chat)),
                          sendOnEnter: ref.watch(sendOnEnterProvider),
                          onPickNetwork: _pickNetwork,
                          onRecordVoice: () =>
                              setState(() => _recording = true),
                          onSendLater: () => _sendLater(chat),
                          inThread: rootId != null,
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
            label: context.l10n.chatLoadingOlder,
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
            label: Text(context.l10n.chatLoadOlder),
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
            context.l10n.chatBeginningOfConversation,
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
                context.l10n.chatUnavailableHint,
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
    final language = await showWeftPanel<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.xl),
            child: Text(context.l10n.messageActionRetranscribe),
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
    announce(context, context.l10n.attachmentTranscribing);

    final service = ref.read(transcriptionServiceProvider);
    try {
      final transcript = await service.transcribe(
        message,
        languageOverride: language,
      );
      if (!mounted) return;
      setState(() {});
      announce(
        context,
        context.l10n.attachmentTranscriptLabel(transcript.text),
      );
    } on Object catch (e) {
      // Deliberately Object, not Exception: a native transcription backend can
      // fail with an Error, and swallowing that made the button look inert.
      debugPrint('weft: transcription failed for ${message.eventId}: $e');
      if (!mounted) return;
      _showMessage(context.l10n.chatTranscriptionFailed('$e'));
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
      context.l10n,
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
      _showMessage(context.l10n.chatWriteBeforeSchedule);
      return;
    }
    final when = await _pickDateTime(context, from: DateTime.now());
    if (when == null || !mounted) return;
    if (!when.isAfter(DateTime.now())) {
      _showMessage(context.l10n.chatTimeAlreadyPast);
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
      context.l10n.chatScheduledFor(DateFormat.MMMEd().add_Hm().format(when)),
    );
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final composing = _composerContext;
    _composer.clear();
    setState(() => _composerContext = null);

    final repository = ref.read(chatRepositoryProvider);
    final rootId = widget.threadRootId;
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
      // A thread is a *place*, so it wins over the reply. A reply typed inside
      // a thread is still a message in that thread — sent as a plain reply it
      // lands in the room instead, visible to everyone and out of the thread
      // the user was looking at, which is not recoverable except by deleting
      // it. The reply target rides along as the quote it was.
      case ComposerMode.reply when rootId != null:
        await _run(
          () => repository.sendThreadReply(
            _chatId,
            text,
            threadRootId: rootId,
            replyToEventId: composing!.message.eventId,
            threadLatestEventId: _newestInThread(rootId),
          ),
        );
      case ComposerMode.reply:
        await _run(
          () => repository.sendReply(
            _chatId,
            text,
            replyToEventId: composing!.message.eventId,
          ),
        );
      case null when rootId != null:
        await _run(
          () => repository.sendThreadReply(
            _chatId,
            text,
            threadRootId: rootId,
            threadLatestEventId: _newestInThread(rootId),
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

  /// What to call the open thread in the bar.
  ///
  /// The grouping's answer when it has one — which it does not, inside the
  /// thread view: the replies have been *taken out* of the flat list to build
  /// it, so the root has no thread hanging off it here. So this asks the
  /// messages directly, the same way `groupThreads` would, and falls back to
  /// the generic word when the root has not been paginated in yet.
  String? _threadTitleFor(String rootEventId, ThreadGrouping grouping) {
    final known = grouping.threads[rootEventId]?.title;
    if (known != null) return known;

    final belonging = threadMessages(
      messages: _view.messages,
      rootEventId: rootEventId,
    );
    final root = belonging.where((m) => m.eventId == rootEventId).firstOrNull;
    if (root == null) return null;
    return threadTitle(
      root,
      belonging.where((m) => m.eventId != rootEventId).toList(growable: false),
    );
  }

  /// The newest loaded event in [rootEventId]'s thread, for the spec's reply
  /// fallback.
  ///
  /// The root itself when nothing has been said yet, which is the honest answer
  /// for an empty thread and what the first reply into one has to point at.
  String _newestInThread(String rootEventId) {
    final belonging = threadMessages(
      messages: _view.messages,
      rootEventId: rootEventId,
    );
    return belonging.isEmpty ? rootEventId : belonging.last.eventId;
  }

  /// Opens the thread hanging off [rootEventId] as a screen of its own.
  ///
  /// A push rather than a pane, on every surface. A thread is a place the reader
  /// goes *into* and comes back out of, and the back gesture is the whole of
  /// what makes that reversible — a thread swapped into the same pane leaves
  /// them in a conversation that looks like the one they were in and is not.
  ///
  /// The same widget with a root set: see [ChatView.threadRootId].
  Future<void> _openThread(String rootEventId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatView(chatId: widget.chatId, threadRootId: rootEventId),
      ),
    );
    // The thread was almost certainly read while it was open, and the room's
    // own receipt may well have moved with it. Rebuilding is what takes the
    // unread badge off the indicator the reader is about to be looking at
    // again.
    if (mounted) _refresh();
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
  /// ⌘V, which on a desktop is as often a screenshot as a sentence.
  ///
  /// Images win when there are any: someone who has just copied a picture and
  /// pressed paste in a chat wants the picture. Anything else falls straight
  /// through to the framework's own paste — the key was intercepted to ask the
  /// question, and text has to end up in the field exactly as it did before.
  Future<void> _paste(Chat chat) async {
    final images = await const ClipboardImages().read();
    if (!mounted) return;

    if (images.isEmpty) {
      // Resolved from the caret rather than from here: the actions that
      // implement a text paste are registered by `EditableText`, below this
      // widget, and only a context inside it can reach them.
      final caret = primaryFocus?.context;
      if (caret != null && caret.mounted) {
        Actions.maybeInvoke(
          caret,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
      }
      return;
    }

    final confirmed = await showAttachmentPreviewSheet(
      context,
      chat: chat,
      sources: images,
      onPickNetwork: _pickNetwork,
    );
    if (confirmed == null || confirmed.sources.isEmpty || !mounted) return;
    await _sendAttachments(confirmed);
  }

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
      if (confirmed == null || confirmed.sources.isEmpty || !mounted) return;
      await _sendAttachments(confirmed);
      return;
    }

    final pickerFailed = context.l10n.chatPickerFailed;
    final List<AttachmentSource> picked;
    try {
      picked = await picker.pick(source);
    } on Object catch (error) {
      // Deliberately Object: a picker is a method channel, and a platform that
      // denies the photo permission throws rather than returning nothing.
      debugPrint('weft: attachment picker failed: $error');
      _showMessage(pickerFailed);
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final confirmed = await showAttachmentPreviewSheet(
      context,
      chat: chat,
      sources: picked,
      onPickNetwork: _pickNetwork,
    );
    if (confirmed == null || confirmed.sources.isEmpty || !mounted) return;

    await _sendAttachments(confirmed);
  }

  /// Sends each confirmed file, reporting the ones that will never be sent.
  ///
  /// The loop itself is [sendAttachments], shared with the share sheet — the
  /// two paths differ only in where the files came from.
  /// One-shot position → `m.location`. The permission dialog is the OS's,
  /// shown at the moment of sharing.
  Future<void> _shareLocation(Chat chat) async {
    final l10n = context.l10n;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showMessage(l10n.chatNoLocationPermission);
        return;
      }
      _showMessage(l10n.chatGettingPosition);
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
      if (mounted) _showMessage(l10n.chatPositionFailed);
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
        title: Text(context.l10n.chatProposeCalendarTitle),
        content: TextField(
          controller: title,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: context.l10n.chatProposeCalendarLabel,
            hintText: context.l10n.chatProposeCalendarHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.chatPickATime),
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

  Future<void> _sendAttachments(ConfirmedAttachments confirmed) async {
    final sources = confirmed.sources;
    final problems = await sendAttachments(
      context.l10n,
      ref.read(chatRepositoryProvider),
      _chatId,
      sources,
      caption: confirmed.caption,
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

/// The bar over one open thread.
///
/// Deliberately plain next to [_ChatAppBar]. The room's bar carries a call
/// button, a search and the contact's face, and each of those is about the
/// conversation rather than about the topic being read — a call started from
/// inside "Bugs" reaches the whole group, which is not what the button appears
/// to offer from there. What a thread needs is its name, where it lives, and a
/// way back out.
class _ThreadAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ThreadAppBar({required this.chat, this.title});

  final Chat chat;

  /// The bridge's name for the topic, or the root's own words. Null while the
  /// root is still paginating in, where the generic word is the honest answer —
  /// a bar that said nothing at all would look like a screen that failed.
  final String? title;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: context.colors.surfaceContainerLowest,
      // One node, marked as the heading. "Bugs" and "in Design Team" read as
      // two unrelated fragments when a reader lands on them separately.
      title: MergeSemantics(
        child: Semantics(
          header: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title ?? context.l10n.threadTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                context.l10n.threadInChat(chat.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
}

class _ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ChatAppBar({
    required this.chat,
    required this.mac,
    this.typing = const [],
    this.online = false,
    this.preview = false,
  });

  /// A preview's bar names the conversation and offers nothing: a peek that
  /// can start a call is not a peek.
  final bool preview;

  final Chat chat;

  /// Whether to draw the desktop's toolbar instead of a Material app bar.
  ///
  /// Passed in rather than read from the context because [preferredSize] is
  /// consulted without one, and a bar that reports 64 and draws 52 leaves a
  /// gap the conversation scrolls into.
  final bool mac;

  /// Names currently typing. Non-empty replaces the subtitle — "typing…" is
  /// the most current thing that can be said about a conversation.
  final List<String> typing;

  /// Whether the DM partner is online, where presence reaches this side.
  final bool online;

  @override
  Size get preferredSize =>
      Size.fromHeight(mac ? MacMetrics.toolbarHeight : 64);

  /// One toolbar verb, in whichever button this surface uses.
  Widget _action({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) => mac
      ? MacToolbarButton(icon: icon, tooltip: tooltip, onPressed: onPressed)
      : IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: onPressed);

  @override
  Widget build(BuildContext context) {
    if (mac) return _macBar(context);
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
            label: context.l10n.chatContactDetails,
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
                        // The dot, not only the word. "· online" in 11pt under
                        // a name is true and unreadable; the mark on the face
                        // is the one every messenger uses and the one anyone
                        // actually notices.
                        online: online,
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
                            ? context.l10n.chatTypingNames(
                                typing.join(', '),
                                typing.length,
                              )
                            : context.l10n.chatTypingShort,
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else if (chat.isMerged)
                      Text(
                        _withOnline(
                          context,
                          context.l10n.chatMergedNetworks(
                            chat.networks.map((n) => n.label).join(', '),
                          ),
                          online: online,
                        ),
                        style: context.text.labelSmall?.copyWith(
                          color: context.palette.mergedAccent,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(
                        _withOnline(
                          context,
                          chat.networks.firstOrNull?.label ?? '',
                          online: online,
                        ),
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
      actions: _actions(context),
    );
  }

  /// The conversation's verbs. Shared by both bars — a call is a call, and the
  /// only thing the surface changes is which button shape draws it.
  List<Widget> _actions(BuildContext context) => preview
      ? const []
      : [
          // Disabled rather than hidden, with the reason in its tooltip: a
          // conversation with no Matrix-native leg cannot carry a call, and a
          // button that quietly disappeared for bridged chats would read as Braid
          // having lost the feature.
          Consumer(
            builder: (context, ref, _) {
              final availability = ref.watch(callAvailabilityProvider(chat.id));
              final target = availability.target;
              if (target != null) {
                return _action(
                  tooltip: context.l10n.callAvailability(availability),
                  icon: Icons.call_rounded,
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
                return _action(
                  tooltip: context.l10n.callAvailability(availability),
                  icon: Icons.call_rounded,
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
              final external = externalCallRouteFor(
                context.l10n,
                chat,
                contact,
              );
              if (external == null) {
                return _action(
                  tooltip: context.l10n.callAvailability(availability),
                  icon: Icons.call_rounded,
                  onPressed: null,
                );
              }
              return _action(
                tooltip: external.label,
                icon: Icons.phone_forwarded_rounded,
                onPressed: () async {
                  final opened = await launchUrl(
                    external.uri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened && context.mounted) {
                    showWeftMessage(context, context.l10n.chatCallNoHandler);
                  }
                },
              );
            },
          ),
          _action(
            tooltip: chat.isMerged
                ? context.l10n.chatManageMerge
                : context.l10n.chatMergeWith,
            icon: Icons.merge_rounded,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MergeScreen()),
            ),
          ),
          // Disabled rather than inert. `onPressed: () {}` is a button that
          // announces itself as enabled, takes a tap and does nothing — which a
          // reader has no way to distinguish from a tap that failed. There is no
          // in-conversation search yet; the tooltip says so and the button says
          // so by being unavailable. Search across every chat is on the inbox.
          _action(
            tooltip: context.l10n.chatSearchUnavailable,
            icon: Icons.search_rounded,
            onPressed: null,
          ),
        ];

  /// Adds " · online" to whatever the subtitle line already said.
  ///
  /// Its own function rather than an interpolation at each site because the
  /// separator is part of the sentence: a language that joins clauses differently
  /// changes it once, here, for both the phone's bar and the Mac's toolbar.
  String _withOnline(
    BuildContext context,
    String subtitle, {
    required bool online,
  }) => online ? context.l10n.chatSubtitleOnline(subtitle) : subtitle;

  /// The thread's slice of the window's toolbar.
  ///
  /// The same three facts the phone's bar carries — who, on what, and what can
  /// be done about it — at a quarter of the height. A 48pt avatar and a 22pt
  /// name over a window is a phone screen's proportions; the system puts the
  /// conversation's name at 13pt and gets on with showing the conversation.
  Widget _macBar(BuildContext context) {
    final subtitle = switch ((typing.isNotEmpty, chat.isMerged)) {
      (true, _) =>
        chat.isGroup
            ? context.l10n.chatTypingNames(typing.join(', '), typing.length)
            : context.l10n.chatTypingShort,
      (_, true) => _withOnline(
        context,
        context.l10n.chatMergedNetworks(
          chat.networks.map((n) => n.label).join(', '),
        ),
        online: online,
      ),
      _ => _withOnline(
        context,
        chat.networks.firstOrNull?.label ?? '',
        online: online,
      ),
    };
    final subtitleColor = switch ((typing.isNotEmpty, chat.isMerged, online)) {
      (true, _, _) => context.colors.primary,
      (_, true, _) => context.palette.mergedAccent,
      (_, _, true) => context.palette.online,
      _ => context.colors.onSurfaceVariant,
    };

    return MacGlass(
      kind: MacGlassKind.toolbar,
      border: Border(
        bottom: BorderSide(color: context.palette.divider, width: 0.5),
      ),
      child: MacToolbar(
        leading: Consumer(
          builder: (context, ref, _) => Semantics(
            button: true,
            label: context.l10n.chatContactDetails,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: GestureDetector(
                onTap: preview
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ContactProfileScreen(chatId: chat.id),
                        ),
                      ),
                child: ExcludeSemantics(
                  child: WeftAvatar(
                    label: chat.title,
                    imageUrl: chat.avatarUrl,
                    imageHeaders: ref.watch(mediaHeadersProvider),
                    networks: chat.networks,
                    online: online,
                    size: 26,
                    semanticsLabel: '',
                  ),
                ),
              ),
            ),
          ),
        ),
        titleWidget: MergeSemantics(
          child: Semantics(
            header: true,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.titleSmall,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelSmall?.copyWith(
                      color: subtitleColor,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [MacToolbarGroup(children: _actions(context))],
      ),
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
      label: context.l10n.chatMessagesFromDate(DateFormat.MMMd().format(date)),
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
    if (!widget.enabled || context.hasPointer) return widget.child;
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

/// Hover and right-click, for platforms that have a pointer.
///
/// The Slack shape: resting, the bubble is clean; hovering slides in a small
/// cluster — reply, react, more — at the bubble's shoulder, and a secondary
/// click anywhere on the bubble opens the full context menu at the cursor.
/// On touch platforms this is a pass-through and costs one widget.
class _BubbleHoverShell extends StatefulWidget {
  const _BubbleHoverShell({
    required this.own,
    required this.child,
    this.onQuickReply,
    this.onQuickReact,
    this.onActionsAt,
  });

  final bool own;
  final Widget child;
  final VoidCallback? onQuickReply;
  final ValueChanged<BuildContext>? onQuickReact;
  final void Function(Offset globalPosition)? onActionsAt;

  @override
  State<_BubbleHoverShell> createState() => _BubbleHoverShellState();
}

class _BubbleHoverShellState extends State<_BubbleHoverShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (!context.hasPointer) return widget.child;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Silent to a screen reader. A `GestureDetector` that declares any tap
        // recogniser exports a tappable node, and a right-click-only one
        // exports it with nothing to say — an unnamed control the width of the
        // row, sitting over the named one. The route walk found ten of them on
        // the Mac inbox and nine more in a conversation. The menu itself loses
        // nothing: every verb in it is reachable from the row's own actions,
        // and a pointer is the only thing that can raise it.
        excludeFromSemantics: true,
        onSecondaryTapUp: widget.onActionsAt == null
            ? null
            : (details) => widget.onActionsAt!(details.globalPosition),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            PositionedDirectional(
              top: -10,
              // At the bubble's shoulder: the side away from the screen edge,
              // so the cluster never hangs outside the window.
              start: widget.own ? 0 : null,
              end: widget.own ? null : 0,
              child: IgnorePointer(
                ignoring: !_hovered,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: WeftMotion.fast,
                  child: Material(
                    elevation: 3,
                    borderRadius: WeftRadius.pill,
                    color: context.colors.surfaceContainerHigh,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onQuickReply != null)
                          IconButton(
                            tooltip: context.l10n.messageActionReply,
                            visualDensity: VisualDensity.compact,
                            iconSize: 17,
                            icon: const Icon(Icons.reply_rounded),
                            onPressed: widget.onQuickReply,
                          ),
                        if (widget.onQuickReact != null)
                          Builder(
                            builder: (anchor) => IconButton(
                              tooltip: context.l10n.chatQuickReact,
                              visualDensity: VisualDensity.compact,
                              iconSize: 17,
                              icon: const Icon(Icons.add_reaction_outlined),
                              onPressed: () => widget.onQuickReact!(anchor),
                            ),
                          ),
                        if (widget.onActionsAt != null)
                          Builder(
                            builder: (buttonContext) => IconButton(
                              tooltip: context.l10n.commonMore,
                              visualDensity: VisualDensity.compact,
                              iconSize: 17,
                              icon: const Icon(Icons.more_horiz_rounded),
                              onPressed: () {
                                final box =
                                    buttonContext.findRenderObject()!
                                        as RenderBox;
                                widget.onActionsAt!(
                                  box.localToGlobal(
                                    box.size.bottomCenter(Offset.zero),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
    this.delivery,
    this.deliveryIsComplete = true,
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
    this.onActionsAt,
    this.onCopy,
    this.onQuickReply,
    this.onQuickReact,
    this.onJumpToReply,
    this.onToggleReaction,
    this.onAddReaction,
    this.onShowReactionSenders,
    this.onTapLink,
    this.onTapMention,
    this.thread,
    this.onOpenThread,
  });

  /// The thread hanging off this message, when one does. Null for the
  /// overwhelming majority of bubbles, and null inside a thread view — where
  /// the root is already the thing being read and an indicator pointing at it
  /// would be a way back to where the reader already is.
  final ThreadSummary? thread;

  /// Opens [thread]. Null in a preview, where nothing on a message acts.
  final VoidCallback? onOpenThread;

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

  /// Right-click and the hover cluster's "more": the context menu, at the
  /// pointer.
  final void Function(Offset globalPosition)? onActionsAt;

  /// ⌘C while this bubble holds focus.
  ///
  /// Registered on the bubble rather than on the list so that the *focused*
  /// message is the one copied — `Actions` resolves from the focus outwards, so
  /// the innermost handler is by definition the bubble the reader is on. The
  /// chat's own handler sits above it and is what answers when the focus is
  /// anywhere else in the thread, which is where a live selection puts it.
  final VoidCallback? onCopy;

  /// The hover cluster's one-click verbs.
  final VoidCallback? onQuickReply;
  final ValueChanged<BuildContext>? onQuickReact;

  /// Reply-chip tap. Takes the target's event id rather than closing over it,
  /// so the bubble does not need to know how the list scrolls.
  final ValueChanged<String>? onJumpToReply;

  final ValueChanged<ReactionTally>? onToggleReaction;
  final ValueChanged<BuildContext>? onAddReaction;
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

  /// The ticks to draw, which is not always what the message carries: a read
  /// receipt is the only thing that can turn `delivered` into `read`, and it
  /// arrives separately from the event that is being ticked.
  final DeliveryState? delivery;

  /// Whether [delivery] is the whole truth, or as far as anything can see.
  ///
  /// False when the user has read receipts switched off. Bridges relay the
  /// public receipt to the remote network as its own read marker and nearly all
  /// of them stop relaying the other direction in return, so the user who
  /// turned it off is also the user whose blue ticks will never arrive — and two
  /// grey ticks then say "they have not looked at it" about a message that may
  /// well have been read an hour ago. Saying so is the honest version; leaving
  /// the mark to be misread is not.
  final bool deliveryIsComplete;

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
  String _senderLabel(AppL10n l10n) => semanticsSentence([
    message.isOwn ? l10n.commonYou : message.senderName,
    if (showNetwork) l10n.chatOnNetwork(message.network.label),
  ]);

  /// The metadata row as one clause: when it was sent, and — for the user's own
  /// messages — how far it got. Currently three nodes, one of which is an
  /// unlabelled 13dp tick.
  String _metaLabel(AppL10n l10n) => semanticsSentence([
    l10n.chatSentAt(DateFormat.Hm().format(message.timestamp)),
    // The effective state, so a reader is told "Read" exactly when the ticks
    // are blue. Two answers to the same question is worse than either.
    if (message.isOwn) l10n.deliveryState(delivery ?? message.deliveryState),
    // And, when the ticks cannot say more, *why*. Two grey ticks with receipts
    // switched off do not mean "they have not looked at it" — they mean nobody
    // is telling us, and the difference is the whole reason the tick is looked
    // at. A screen reader gets it in the same clause the sighted reader gets
    // from the tooltip.
    if (message.isOwn && !deliveryIsComplete) l10n.deliveryUnknownReason,
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
              // Who said it, as a face. A group named its senders in text and
              // showed no picture at all, which leaves a wall of identical
              // bubbles to be told apart by reading — and the name only
              // appears on the first message of a run, so most of them said
              // nothing. The gutter is held even on grouped messages, so a run
              // stays aligned under its own avatar.
              if (showSender && !own) ...[
                SizedBox(
                  width: 26,
                  child: groupedWithPrevious
                      ? null
                      : Consumer(
                          builder: (context, ref, _) => WeftAvatar(
                            label: message.senderName,
                            imageUrl: ref
                                .read(chatRepositoryProvider)
                                .avatarUrlFor(
                                  message.senderId,
                                  roomId: message.roomId,
                                ),
                            imageHeaders: ref.watch(mediaHeadersProvider),
                            size: 24,
                            // The bubble's own node already opens with the
                            // sender's name; a second one would say it twice.
                            semanticsLabel: '',
                          ),
                        ),
                ),
                const SizedBox(width: WeftSpace.xs),
              ],
              Flexible(
                child: _BubbleHoverShell(
                  own: own,
                  onQuickReply: onQuickReply,
                  onQuickReact: onQuickReact,
                  onActionsAt: onActionsAt,
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      CopyMessageIntent: WeftGuardedAction<CopyMessageIntent>(
                        onInvoke: () => onCopy?.call(),
                        enabled: () => onCopy != null,
                      ),
                    },
                    child: WeftFocusable(
                      // The bubble is a group, not a control: it holds a body whose
                      // links and mention pills must stay individually reachable,
                      // so its children keep speaking and keep their own focus
                      // nodes. What the group adds is the header a sighted user
                      // reads off the bubble's position and colour — who, and on
                      // what leg.
                      button: false,
                      excludeSemantics: false,
                      label: _senderLabel(context.l10n),
                      // Long-press rather than a visible affordance: a button per
                      // bubble is six controls per screen the reader has to look
                      // past to read the conversation. On a keyboard the same
                      // sheet is Enter, since there is no long-press to make — and
                      // deliberately not a tap, which would put a menu in front of
                      // anyone who touched a message.
                      //
                      // Not on a pointer, though. A mouse's long-press is a click
                      // held still for half a second, which is how a careful
                      // drag-select *starts* — and a menu opening under the
                      // cursor mid-selection is the worst possible answer to it.
                      // Desktop has two better affordances for the same sheet
                      // already: right-click and the hover cluster.
                      onActivate: onActions,
                      onLongPress: context.hasPointer ? null : onActions,
                      onLongPressHint: context.l10n.chatShowActionsHint,
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
                              //
                              // And out of the selection, for the reason the
                              // clock under the bubble is: it is a badge about
                              // the message, not a word anybody wrote, and an
                              // excerpt dragged out of a merged thread should
                              // not paste as `Signal Got it, thanks`.
                              SelectionContainer.disabled(
                                child: ExcludeSemantics(
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
                              ),
                              const SizedBox(height: WeftSpace.xxs),
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
                                    color: _senderColor(
                                      context,
                                      message.senderId,
                                    ),
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
                                    : () =>
                                          onJumpToReply!(replyPreview!.eventId),
                              ),
                            if (content != null)
                              content!
                            // Before the attachment and voice branches, not after:
                            // a redacted event keeps whatever `attachmentUrl` it
                            // was mapped with, and a deleted photo that still drew
                            // its own bubble would be a deletion that did nothing.
                            else if (message.redacted)
                              Text(
                                context.l10n.chatMessageDeleted,
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
                                // A caption is message text under a picture, so
                                // it takes the same accent and the same handlers
                                // the text branch below does — a link the reader
                                // taps must open the same way whichever bubble it
                                // is in.
                                accent: accent,
                                onTapLink: onTapLink,
                                onTapMention: onTapMention,
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
                                // Before the edited marker and before the
                                // clock, because it is the one fact about this
                                // bubble a reader could not work out for
                                // themselves: nobody typed it. Six months
                                // later, "did I say that or did the model" is
                                // not a question a transcript should leave
                                // open.
                                if (message.isAutoReply &&
                                    !message.redacted) ...[
                                  _AutoReplyMarker(own: own),
                                  const SizedBox(width: WeftSpace.xs),
                                ],
                                if (message.isEdited && !message.redacted) ...[
                                  _EditedMarker(message: message, own: own),
                                  const SizedBox(width: WeftSpace.xs),
                                ],
                                // The time and the tick are one clause — "Sent
                                // 14:32, Read" — rather than a bare number followed
                                // by an unlabelled 13dp glyph whose only difference
                                // between delivered and read is its colour.
                                //
                                // And out of the selection: dragging across an
                                // exchange to paste it into a mail should give
                                // what was said, not `Hello there 13:56 See you
                                // at six 13:57`. The clock is chrome about the
                                // message, the same as the tick beside it, and
                                // the reader who wants it can see it on screen.
                                SelectionContainer.disabled(
                                  child: Semantics(
                                    container: true,
                                    excludeSemantics: true,
                                    label: _metaLabel(context.l10n),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          DateFormat.Hm().format(
                                            message.timestamp,
                                          ),
                                          style: context.text.labelSmall
                                              ?.copyWith(
                                                fontSize: 10,
                                                color: palette.mutedOnBubble(
                                                  own,
                                                ),
                                              ),
                                        ),
                                        if (own) ...[
                                          const SizedBox(width: WeftSpace.xxs),
                                          Tooltip(
                                            // The reason rides on the tooltip, not
                                            // on a second glyph. There is no mark
                                            // for "we are not being told" that a
                                            // reader would not have to be taught,
                                            // and a third tick shape would be one
                                            // more thing to learn in a vocabulary
                                            // whose whole value is that it is
                                            // already known.
                                            message: semanticsSentence([
                                              context.l10n.deliveryState(
                                                delivery,
                                              ),
                                              if (!deliveryIsComplete)
                                                context
                                                    .l10n
                                                    .deliveryUnknownReason,
                                            ]),
                                            excludeFromSemantics: true,
                                            child: Icon(
                                              // The vocabulary everyone already
                                              // knows: one tick sent, two ticks
                                              // arrived, two blue ticks read. Every
                                              // state past sending used to draw the
                                              // same double tick in the same
                                              // colour, so the mark said only "not
                                              // failed" — and the one thing it is
                                              // looked at for is whether the other
                                              // side has seen it.
                                              switch (delivery) {
                                                DeliveryState.sending =>
                                                  Icons.schedule_rounded,
                                                DeliveryState.failed =>
                                                  Icons.error_outline_rounded,
                                                DeliveryState.sent =>
                                                  Icons.done_rounded,
                                                _ => Icons.done_all_rounded,
                                              },
                                              size: 13,
                                              color: switch (delivery) {
                                                // Corrected against the bubble it
                                                // sits on, not taken raw. In high
                                                // contrast `colorScheme.error` is
                                                // a near-white pink meant for a
                                                // dark surface, and the own bubble
                                                // there is near-white too — so the
                                                // one tick that says a message
                                                // never left was invisible at
                                                // 1.05:1. Found by the golden, not
                                                // by reading this line.
                                                DeliveryState.failed =>
                                                  WeftContrast.ensure(
                                                    context.colors.error,
                                                    palette.ownBubble,
                                                    minRatio: WeftContrast
                                                        .uiComponent,
                                                  ),
                                                // Against the bubble, not the
                                                // page: the token is corrected for
                                                // the inbox row's background, and
                                                // in a dark theme that blue lands
                                                // on the own bubble's pale fill at
                                                // 1.3:1 — the most important of the
                                                // five marks, and the hardest to
                                                // see.
                                                DeliveryState.read =>
                                                  palette.readReceiptOn(
                                                    palette.ownBubble,
                                                  ),
                                                _ => palette.mutedOnBubble(
                                                  true,
                                                  alpha: 0.7,
                                                ),
                                              },
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
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
          //
          // Two points above it and no more. Outside the bubble is not the same
          // as *away* from it: a bar a thumb's width below reads as belonging to
          // the gap rather than to the message, which is what it looked like
          // while the chips' tap padding was centred. The chips now grow
          // downwards, so this is the whole of the gap and it is deliberate.
          // Directional insets throughout, so a mirrored thread keeps the bar
          // under the edge the bubble is anchored to.
          // Under the bubble, above the reactions. A thread is *where the rest
          // of this conversation went*, so it belongs closer to the message
          // than a tally of emoji does — and outside the bubble for the same
          // reason the bar is: it is about the message rather than part of what
          // was said.
          if (thread != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: WeftSpace.xs,
                end: WeftSpace.xs,
                top: WeftSpace.xxs,
              ),
              child: ThreadIndicator(
                thread: thread!,
                own: own,
                onOpen: onOpenThread,
              ),
            ),
          if (message.reactions.isNotEmpty && onToggleReaction != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: WeftSpace.xs,
                end: WeftSpace.xs,
                top: WeftSpace.xxs,
              ),
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

/// The "sent automatically" marker.
///
/// A glyph and a tooltip rather than the word, because it sits in the busiest
/// eight pixels of the bubble beside the clock, the tick and possibly "edited"
/// — and because unlike those it appears on a handful of messages in a
/// conversation rather than on every one. The screen reader gets the sentence;
/// the eye gets a small mark it can learn once.
///
/// Drawn for a peer's auto-reply as well as the user's own, which is the honest
/// reading of the flag: another Braid saying "this was written by a machine" is
/// exactly as worth showing as our own having said it.
class _AutoReplyMarker extends StatelessWidget {
  const _AutoReplyMarker({required this.own});

  final bool own;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.chatAutoReplyTooltip,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: context.l10n.chatAutoReplyLabel,
        child: Icon(
          Icons.smart_toy_outlined,
          size: 12,
          color: context.palette.mutedOnBubble(own),
        ),
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
          ? context.l10n.chatEditedTooltipWithHistory
          : context.l10n.chatEditedTooltip,
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
              ? context.l10n.chatEditedLabel
              : context.l10n.chatEditedAtLabel(
                  DateFormat.Hm().format(editedAt),
                ),
          if (hasHistory) context.l10n.chatEditedVersionsHint,
        ]),
        child: Text(
          editedAt == null
              ? context.l10n.chatEditedShort
              : context.l10n.chatEditedAtShort(
                  DateFormat.Hm().format(editedAt),
                ),
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
                  ? context.l10n.chatVoiceLoading
                  : playing
                  ? context.l10n.chatVoicePause
                  : context.l10n.chatVoicePlay,
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
                        tooltip: playing
                            ? context.l10n.commonPause
                            : context.l10n.commonPlay,
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
                  context.l10n.messageKindVoice,
                  formatMediaDuration(message.durationMs),
                  if (playing) context.l10n.attachmentPlaying,
                  if (transcribing)
                    context.l10n.chatVoiceTranscribing
                  else if (message.transcript != null)
                    context.l10n.chatVoiceTranscriptBelow
                  else if (onTranscribe != null)
                    context.l10n.chatVoiceNoTranscript,
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
    required this.onPaste,
    required this.onPickNetwork,
    required this.sendOnEnter,
    this.composing,
    this.onCancelContext,
    this.onRecordVoice,
    this.onSendLater,
    this.inThread = false,
  });

  /// Whether the message being written goes into an open thread rather than
  /// into the room. Only changes the field's words, and that is the whole of
  /// what it needs to change: everything else about sending a message into a
  /// thread is the same, and the one thing the user cannot see from the
  /// composer alone is *where it will land*.
  final bool inThread;

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

  /// ⌘V / Ctrl+V, which may be an image rather than text.
  final VoidCallback onPaste;

  /// Whether Return sends. Off, it breaks the line and ⌘/Ctrl+Return sends.
  final bool sendOnEnter;

  final ValueChanged<ChatNetwork> onPickNetwork;

  /// What the next send will do, in one phrase.
  ///
  /// Used as both the hint and the accessible name, so the two cannot drift and
  /// the mode survives the first keystroke.
  String _fieldLabel(AppL10n l10n, ChatNetwork? sendNetwork) =>
      switch (composing?.mode) {
        ComposerMode.edit => l10n.chatComposerEdit,
        ComposerMode.reply => l10n.messageActionReply,
        // The thread wins over the network. Inside a thread the network is not
        // in question — a thread lives in exactly one room — and *which
        // conversation this lands in* is.
        null when inThread => l10n.threadComposerMessage,
        null =>
          sendNetwork == null
              ? l10n.chatComposerMessage
              : l10n.chatComposerMessageVia(sendNetwork.label),
      };

  @override
  Widget build(BuildContext context) {
    final sendNetwork = chat.sendNetwork;
    final editing = composing?.mode == ComposerMode.edit;
    final mac = context.isMac;

    return Container(
      padding: mac
          ? const EdgeInsetsDirectional.fromSTEB(
              WeftSpace.sm,
              WeftSpace.sm,
              WeftSpace.md,
              WeftSpace.sm,
            )
          : const EdgeInsetsDirectional.fromSTEB(
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
        child: _ReadingColumn(
          // Lined up with the thread rather than spanning the pane: a composer
          // that starts where the bubbles stop looks like a bar bolted on.
          enabled: mac,
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
                // Centred on a desktop, where the field is one line tall and
                // every control beside it is 24 points: aligning to the bottom
                // there leaves each of them sitting on a different line. A phone's
                // field grows to five lines, and the buttons belong at its foot.
                crossAxisAlignment: mac
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.end,
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
                    iconSize: mac ? 17 : null,
                    visualDensity: mac ? VisualDensity.compact : null,
                    // Wider than the round send button on purpose. Squeezed to
                    // 24 with no padding it stopped reading as a control at all
                    // — a stray plus sign between the network chip and the
                    // field, with nothing to hover.
                    constraints: mac
                        ? const BoxConstraints.tightFor(width: 28, height: 28)
                        : null,
                    padding: mac ? EdgeInsets.zero : null,
                    tooltip: context.l10n.attachSheetTitle,
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
                      label: _fieldLabel(context.l10n, sendNetwork),
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
                            PasteIntoComposerIntent:
                                CallbackAction<PasteIntoComposerIntent>(
                                  onInvoke: (_) {
                                    onPaste();
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
                                hintText: _fieldLabel(
                                  context.l10n,
                                  sendNetwork,
                                ),
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
                          iconSize: mac ? 13 : 18,
                          visualDensity: mac ? VisualDensity.compact : null,
                          constraints: mac ? _macButton : null,
                          padding: mac ? EdgeInsets.zero : null,
                          icon: const Icon(Icons.mic_rounded),
                          tooltip: context.l10n.chatRecordVoice,
                        );
                      }
                      return GestureDetector(
                        // Long-press for "send later" — the same spot WhatsApp
                        // and Telegram hide it, and harmless to discover: a
                        // long-press that does nothing was doing nothing anyway.
                        onLongPress: editing ? null : onSendLater,
                        child: Tooltip(
                          message: editing
                              ? context.l10n.chatSaveEdit
                              : context.l10n.chatSendHoldToSchedule,
                          // Hover still shows it; touch no longer does. A
                          // `Tooltip` claims long presses by default, and as the
                          // deeper widget it won the gesture arena against the
                          // handler above — holding Send showed the tip that
                          // says to hold Send, and scheduled nothing.
                          triggerMode: TooltipTriggerMode.manual,
                          child: IconButton.filled(
                            onPressed: onSend,
                            iconSize: mac ? 13 : 18,
                            visualDensity: mac ? VisualDensity.compact : null,
                            constraints: mac ? _macButton : null,
                            padding: mac ? EdgeInsets.zero : null,
                            icon: Icon(
                              editing
                                  ? Icons.check_rounded
                                  : Icons.send_rounded,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
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
      senderName: editing
          ? context.l10n.chatEditingYourMessage
          : message.senderName,
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
          ? context.l10n.chatEditingYourMessage
          : context.l10n.chatReplyingTo(message.senderName),
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
              tooltip: editing
                  ? context.l10n.chatCancelEdit
                  : context.l10n.chatCancelReply,
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
                    context.l10n.chatScheduledPreview(
                      DateFormat.MMMEd().add_Hm().format(message.dueAt),
                      message.body,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySmall,
                  ),
                ),
                NamedButton(
                  label: context.l10n.chatCancelScheduled,
                  onPressed: () => ref
                      .read(messageSchedulerProvider.notifier)
                      .cancel(message.id),
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    tooltip: context.l10n.commonCancel,
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
        ? context.l10n.messageKindLocation
        : '${coordinates.$1.toStringAsFixed(5)}, '
              '${coordinates.$2.toStringAsFixed(5)}';

    return WeftFocusable(
      button: coordinates != null,
      onTap: coordinates == null ? null : () => _open(context),
      label: semanticsSentence([
        context.l10n.chatSharedLocation,
        label,
        context.l10n.chatOpensInMaps,
      ]),
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
                context.l10n.messageKindLocation,
                style: context.text.bodyMedium?.copyWith(
                  color: onBubble,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                coordinates == null
                    ? message.body
                    : context.l10n.chatLocationOpenInMaps(label),
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
              ? context.l10n.chatPollFinalResult(total)
              : context.l10n.chatPollVotes(total),
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
        context.l10n.chatPollVotes(votes),
        if (chosen) context.l10n.chatPollYourVote,
        if (ended)
          context.l10n.chatPollClosed
        else if (onTap != null)
          context.l10n.chatPollTapToVote,
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
                  context.l10n.chatPollOptionVotes(votes),
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
      title: Text(context.l10n.chatNewPollTitle),
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
                decoration: InputDecoration(
                  labelText: context.l10n.chatPollQuestion,
                ),
              ),
              const SizedBox(height: WeftSpace.sm),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.sm),
                  child: TextField(
                    controller: _options[i],
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: context.l10n.chatPollOptionN(i + 1),
                    ),
                  ),
                ),
              if (_options.length < 8)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(context.l10n.chatPollAddOption),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10n.chatPollCreate),
        ),
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
          label: semanticsSentence([
            context.l10n.chatCalendarInvitation,
            invite.title,
            when,
          ]),
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
              CalendarReply.accepted => context.l10n.chatInviteAccepted(
                response.senderName,
              ),
              CalendarReply.declined => context.l10n.chatInviteDeclined(
                response.senderName,
              ),
              CalendarReply.reschedule => context.l10n.chatInviteReschedule(
                response.senderName,
                response.proposedStart == null
                    ? context.l10n.chatInviteAnotherTime
                    : DateFormat.MMMEd().add_Hm().format(
                        response.proposedStart!,
                      ),
              ),
            }, style: context.text.labelSmall?.copyWith(color: onBubble)),
          ),
        if (onRespond != null && !own) ...[
          const SizedBox(height: WeftSpace.sm),
          Wrap(
            spacing: WeftSpace.sm,
            children: [
              FilledButton.tonal(
                onPressed: () => onRespond!(CalendarReply.accepted, null),
                child: Text(context.l10n.commonAccept),
              ),
              OutlinedButton(
                onPressed: () => onRespond!(CalendarReply.declined, null),
                child: Text(context.l10n.commonDecline),
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
                child: Text(context.l10n.chatInviteNewTime),
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
                  label: Text(context.l10n.chatInviteAddToCalendar),
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
                  label: Text(context.l10n.chatInviteChangeTime),
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
                    context.l10n.chatInviteUseTime(
                      DateFormat.MMMEd().add_Hm().format(
                        response.proposedStart!,
                      ),
                    ),
                  ),
                ),
              ),
      ],
    );
  }
}

/// The composer's round buttons at the system's size.
///
/// `IconButton` sizes itself from a 48dp tap target, which is a thumb. Nothing
/// on this surface is pressed with a thumb, and a 34pt circle beside a 24pt
/// field is the composer's loudest remaining phone tell.
const BoxConstraints _macButton = BoxConstraints.tightFor(
  width: 24,
  height: 24,
);

/// Caps how wide the thread is allowed to run, and centres what is left.
///
/// A pass-through when [enabled] is false, so the phone's full-bleed timeline
/// is untouched and there is no second layout to keep in step with this one.
class _ReadingColumn extends StatelessWidget {
  const _ReadingColumn({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: MacMetrics.readingColumn),
        child: child,
      ),
    );
  }
}

/// Someone on the other side is writing.
///
/// In the thread rather than only in the header, which is where the app used to
/// put it: a line of small print above a conversation is not where anyone is
/// looking while they wait for a reply, and it is the one piece of state whose
/// whole value is being noticed. A bubble in the place the reply itself will
/// appear is what every messenger does, and it is the same shape the reply will
/// take, so nothing jumps when the words arrive.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble({required this.names, required this.isGroup});

  final List<String> names;
  final bool isGroup;

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not merely drawn static under reduced motion — not *running*. A
    // repeating controller schedules a frame forever, which costs a phone
    // battery and costs a widget test its `pumpAndSettle`.
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _controller.isAnimating) {
      _controller.stop();
    } else if (!still && !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Who, in a group. A one-to-one chat needs no name — there is only one
  /// person it can be, and saying it is noise on every message.
  String? _who(AppL10n l10n) {
    if (!widget.isGroup || widget.names.isEmpty) return null;
    return switch (widget.names.length) {
      1 => widget.names.single,
      2 => l10n.chatTypingTwoPeople(widget.names[0], widget.names[1]),
      _ => l10n.chatTypingAndOthers(widget.names[0], widget.names.length - 1),
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final who = _who(context.l10n);

    // One live node: a screen reader is told someone is writing, and told once
    // — the dots themselves are decoration and would otherwise announce three
    // times a second.
    return Semantics(
      liveRegion: true,
      label: who == null
          ? context.l10n.chatTyping
          : context.l10n.chatWhoIsTyping(who),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: WeftSpace.sm),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.md,
                vertical: WeftSpace.sm + 2,
              ),
              decoration: BoxDecoration(
                color: palette.peerBubble,
                borderRadius: WeftRadius.allLg,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (who != null) ...[
                    Text(
                      who,
                      style: context.text.labelSmall?.copyWith(
                        color: palette.mutedOnBubble(false),
                      ),
                    ),
                    const SizedBox(width: WeftSpace.sm),
                  ],
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    _TypingDot(controller: _controller, index: i),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One dot of the three, lifting and fading a third of a cycle after the last.
class _TypingDot extends StatelessWidget {
  const _TypingDot({required this.controller, required this.index});

  final AnimationController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colour = context.palette.mutedOnBubble(false, alpha: 0.75);
    // Reduced motion means no motion: three dots pulsing forever is exactly
    // the kind of small perpetual movement the setting exists to stop.
    if (MediaQuery.disableAnimationsOf(context)) {
      return _dot(colour, 1);
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final phase = (controller.value + index / 3) % 1;
        // A short rise and a long rest, so the row reads as a wave rather than
        // as three lights blinking.
        final lift = phase < 0.5 ? Curves.easeInOut.transform(phase * 2) : 0.0;
        return Transform.translate(
          offset: Offset(0, -2 * lift),
          child: _dot(colour, 0.45 + 0.55 * lift),
        );
      },
    );
  }

  Widget _dot(Color colour, double opacity) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      color: colour.withValues(alpha: colour.a * opacity),
      shape: BoxShape.circle,
    ),
  );
}
