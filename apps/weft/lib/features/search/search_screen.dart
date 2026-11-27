import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';
import '../../app/l10n_labels.dart';

import '../../app/localisation.dart';

import '../../app/providers.dart';
import '../../app/search_providers.dart';
import '../chat/chat_view.dart';
import '../chat/saved_messages_screen.dart';
import '../settings/endpoints_screen.dart';

/// Search across every conversation.
///
/// Results state which method found them — a semantic hit can contain none of
/// the typed words, and without the label that reads as a bug rather than the
/// feature it is.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  /// Pre-filled by `weft://search?q=…` deep links.
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller = TextEditingController(
    text: widget.initialQuery ?? '',
  );

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery?.trim().isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
    // Opening search is a good moment to catch up — someone is about to ask
    // the index something. A backfill waiting out a failure keeps waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(embeddingBackfillProvider)?.schedule(Duration.zero);
    });
  }

  Timer? _debounce;
  List<SearchResult> _results = const [];
  Set<ChatNetwork> _networkFilter = const {};
  bool _searching = false;
  bool _searchedOnce = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    // Debounced so every keystroke doesn't hit FTS5 and (worse) the embedding
    // endpoint, which may be remote and metered. Name matching is an in-memory
    // scan of the inbox, so it follows every keystroke undebounced.
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 250), _run);
  }

  Future<void> _run() async {
    final text = _controller.text;
    if (text.trim().isEmpty && _networkFilter.isEmpty) {
      setState(() {
        _results = const [];
        _searchedOnce = false;
      });
      return;
    }

    setState(() => _searching = true);
    final results = await ref
        .read(searchEngineProvider)
        .search(SearchQuery(text: text, networks: _networkFilter));
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searchedOnce = true;
    });
  }

  /// Chats whose *name* matches the query — a person, a group, a merged
  /// contact. Message search cannot answer this: a chat with no indexed
  /// history exists only in the inbox, and a name is not a message.
  List<Chat> _chatMatches() {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    return chats
        .where((chat) {
          if (chat.archived) return false;
          if (_networkFilter.isNotEmpty &&
              !chat.sources.any((s) => _networkFilter.contains(s.network))) {
            return false;
          }
          return chat.title.toLowerCase().contains(query);
        })
        .take(8)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(chatRepositoryProvider);
    final semanticAvailable = ref.watch(searchEngineProvider).semanticAvailable;
    final backfill = ref.watch(embeddingBackfillProvider);

    return Scaffold(
      appBar: WeftAppBar(
        // The hint is the field's only name, and a hint disappears at the first
        // keystroke — so a reader who typed had nothing left telling them what
        // this field was. The label says it either way.
        title: ConstrainedBox(
          // Not the whole window. A search field that runs 1280 points across
          // is a field with a caret at one end and nothing at the other.
          constraints: BoxConstraints(
            maxWidth: context.isDesktop ? 520 : double.infinity,
          ),
          child: DecoratedBox(
            // A field needs to look like one. Stripping the theme's ring left
            // a caret and a hint sitting on the window with nothing round
            // them, flush against its edge — the fix for the clipping should
            // not cost the control its own shape.
            decoration: BoxDecoration(
              color: context.isDesktop
                  ? context.colors.onSurface.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(MacMetrics.controlRadius),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.isDesktop ? WeftSpace.sm : 0,
                vertical: context.isDesktop ? WeftSpace.xs : 0,
              ),
              child: WeftLabelledField(
                label: context.l10n.inboxSearchAll,
                // Escape closes search, as it does every search field on a
                // desktop. On the field rather than app-wide: a bare key
                // bound at the top would be one no other text field could
                // type past.
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        unawaited(Navigator.of(context).maybePop()),
                  },
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    onChanged: _onChanged,
                    decoration: InputDecoration(
                      hintText: context.l10n.searchHint,
                      // All three borders, not just `border` — and only on a
                      // desktop. The theme gives every field a two-point focus
                      // ring, and this one is autofocused inside a 52-point
                      // toolbar, so the ring drew and was clipped along its top
                      // edge: a field apparently hanging off the top of the
                      // window. On a phone the bar is 56 points, the ring fits,
                      // and it is the only thing marking where the caret is.
                      border: context.isDesktop ? InputBorder.none : null,
                      enabledBorder: context.isDesktop
                          ? InputBorder.none
                          : null,
                      focusedBorder: context.isDesktop
                          ? InputBorder.none
                          : null,
                      filled: false,
                      // Dense on a desktop only. Unconditionally it took the
                      // field to 24 points tall on a phone as well, which is
                      // half the target a thumb is owed.
                      isDense: context.isDesktop,
                      contentPadding: context.isDesktop
                          ? EdgeInsets.zero
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: context.l10n.savedMessagesTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SavedMessagesScreen(),
              ),
            ),
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.all(WeftSpace.lg),
              child: SizedBox(
                width: 16,
                height: 16,
                child: Semantics(
                  label: context.l10n.searchSearching,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: WeftReadingPane(
        // Wider than a settings page: this one holds result rows with a chat
        // name, a snippet and a network mark, and squeezing those to 720
        // truncates the snippet, which is the part being searched for.
        maxWidth: 900,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.lg,
                vertical: WeftSpace.sm,
              ),
              child: Wrap(
                spacing: WeftSpace.sm,
                children: [
                  for (final network in repository.availableNetworks)
                    FilterChip(
                      // The chip's own label is the network's name; a glyph that
                      // says it again turns every filter into "WhatsApp,
                      // WhatsApp, not selected".
                      avatar: NetworkGlyph(
                        network: network,
                        size: 16,
                        semanticsLabel: '',
                      ),
                      label: Text(network.label),
                      selected: _networkFilter.contains(network),
                      onSelected: (_) {
                        setState(() {
                          final next = {..._networkFilter};
                          if (!next.remove(network)) next.add(network);
                          _networkFilter = next;
                        });
                        _run();
                      },
                    ),
                ],
              ),
            ),
            if (!semanticAvailable)
              _Notice(
                icon: Icons.psychology_outlined,
                text: context.l10n.searchKeywordOnlyNotice,
                action: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EndpointsScreen(),
                    ),
                  ),
                  child: Text(context.l10n.searchKeywordOnlySetUp),
                ),
              )
            else if (backfill != null)
              _BackfillNotice(backfill: backfill),
            if (_searchedOnce)
              _ResultSummary(count: _results.length + _chatMatches().length),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final chatMatches = _chatMatches();

    if (_results.isEmpty && chatMatches.isEmpty) {
      // Nothing centred for a search that came back empty: the summary line
      // above already says "Nothing matched", and saying it twice is one
      // sentence for a sighted user and two announcements for a reader.
      if (_searchedOnce) return const SizedBox.shrink();
      return Center(
        child: Text(
          context.l10n.searchNotIndexedYet,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    // Chats first: someone typing a name wants the conversation, and making
    // them scroll past message hits to reach it reads as "search can't find
    // people".
    final chatRows = <Widget>[
      if (chatMatches.isNotEmpty) ...[
        _SectionLabel(
          text: context.l10n.searchSectionChats,
          semantics: context.l10n.searchSectionChatsSemantics(
            chatMatches.length,
          ),
        ),
        for (final chat in chatMatches) _ChatResultTile(chat: chat),
        if (_results.isNotEmpty)
          _SectionLabel(text: context.l10n.searchSectionMessages),
      ],
    ];

    return ListView.separated(
      itemCount: chatRows.length + _results.length,
      separatorBuilder: (_, i) => i < chatRows.length
          ? const SizedBox.shrink()
          : Divider(height: 1, color: context.palette.divider),
      itemBuilder: (context, index) {
        if (index < chatRows.length) return chatRows[index];
        final result = _results[index - chatRows.length];
        final when = DateFormat.yMMMd().add_Hm().format(result.timestamp);
        final attribution = result.senderName.trim().isEmpty
            ? when
            : '${result.senderName} · $when';
        void open() {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatView(
                chatId: result.chatId,
                initialEventId: result.eventId,
              ),
            ),
          );
        }

        // One node per result rather than five. The row's own parts — a
        // lettermark, a body, a date and a 10dp tag — were announced in visual
        // order and, between them, never said which conversation this came from
        // or who said it.
        return Semantics(
          container: true,
          button: true,
          excludeSemantics: true,
          onTap: open,
          label: _resultLabel(context.l10n, result, when),
          child: ListTile(
            leading: NetworkGlyph(
              network: result.network,
              size: 28,
              // Named in the sentence above; a second reading of "Telegram"
              // here is noise.
              semanticsLabel: '',
            ),
            // A result is message content, so it resolves its own direction the
            // way a bubble and a chat tile do — not the locale's. An English
            // snippet listed in an Arabic UI otherwise reads
            // "?did the roof people ever send the quote", which is the bidi
            // algorithm correctly laying out an English sentence in a
            // right-to-left paragraph and is not what the sender wrote.
            title: Text(
              result.body,
              textDirection: textDirectionOf(result.body),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Row(
              children: [
                // The sender was on the index row all along and shown nowhere.
                // A result whose author is a guess is a result you have to open
                // to understand.
                Flexible(
                  child: Text(
                    attribution,
                    textDirection: textDirectionOf(attribution),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                if (result.matchedSemantic && !result.matchedKeyword)
                  _MethodTag(
                    label: context.l10n.searchTagMeaning,
                    color: context.palette.mergedAccent,
                  ),
                if (result.matchedKeyword && result.matchedSemantic)
                  _MethodTag(
                    label: context.l10n.searchTagBoth,
                    color: context.colors.primary,
                  ),
              ],
            ),
            onTap: open,
          ),
        );
      },
    );
  }
}

/// A small heading between result groups.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, this.semantics});

  final String text;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: semantics ?? text,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.lg,
          WeftSpace.md,
          WeftSpace.lg,
          WeftSpace.xs,
        ),
        child: Text(
          text,
          style: context.text.labelMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// A conversation found by its name. Opens the chat, no particular message.
class _ChatResultTile extends ConsumerWidget {
  const _ChatResultTile({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final headers = ref.watch(mediaHeadersProvider);
    void open() {
      unawaited(pushChat(Navigator.of(context), chat.id));
    }

    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      onTap: open,
      label: semanticsSentence([
        chat.title,
        chat.isGroup ? context.l10n.searchResultGroup : null,
        chat.networks.map((n) => n.label).join(', '),
      ]),
      child: ListTile(
        // Tall enough for the face. A desktop's list tiles are compact — 30
        // points, a menu row — and a tile does not grow for its leading
        // widget, so three 40-point avatars were drawn over one another down
        // a list of people with the same name.
        minTileHeight: 40 + 2 * WeftSpace.sm,
        leading: WeftAvatar(
          label: chat.title,
          imageUrl: chat.avatarUrl,
          imageHeaders: headers,
          size: 40,
          networks: chat.networks,
        ),
        title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: open,
      ),
    );
  }
}

/// What a result says out loud: where, who, what, when, and how it was found.
///
/// The chat is dropped when it is the same word as the sender, which for a
/// direct message it usually is — "Anna Maven, Anna Maven, see you at six" is
/// the kind of label that makes a reader turn the feature off.
String _resultLabel(AppL10n l10n, SearchResult result, String when) {
  final sender = result.senderName.trim();
  final chat = result.chatTitle.trim();
  return semanticsSentence([
    chat.isEmpty || chat == sender ? null : l10n.searchResultInChat(chat),
    sender.isEmpty ? null : sender,
    result.network.label,
    result.kind == MessageKind.text ? null : l10n.messageKind(result.kind),
    result.body,
    when,
    if (result.matchedSemantic && !result.matchedKeyword)
      l10n.searchResultMatchedMeaning
    else if (result.matchedKeyword && result.matchedSemantic)
      l10n.searchResultMatchedBoth,
  ]);
}

/// How many results there are, said once, where a reader will hear it.
///
/// A live region rather than an announcement because there is something on
/// screen to point at: the count is visible, it changes on every query, and a
/// user who missed it can navigate back to it. It is also the app's answer for
/// the empty case, which is why the list below it draws nothing then.
class _ResultSummary extends StatelessWidget {
  const _ResultSummary({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final text = count == 0
        ? context.l10n.searchNothingMatched
        : context.l10n.searchResultCount(count);
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.lg,
          WeftSpace.xs,
          WeftSpace.lg,
          WeftSpace.sm,
        ),
        child: Text(
          text,
          style: context.text.labelSmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The 10dp word saying how this result was found.
///
/// "meaning" on its own is a word with no sentence around it — it qualifies the
/// *match*, and nothing on the row said so. The tooltip is where that sentence
/// went for a sighted user; a reader gets it from the result's own label.
class _MethodTag extends StatelessWidget {
  const _MethodTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label == context.l10n.searchTagMeaning
          ? context.l10n.searchTagMeaningTooltip
          : context.l10n.searchTagBothTooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.dense,
          vertical: WeftSpace.xxs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: WeftRadius.pill,
        ),
        child: Text(
          label,
          style: context.text.labelSmall?.copyWith(color: color, fontSize: 10),
        ),
      ),
    );
  }
}

/// What the embedding backfill is doing, while it has anything left to do.
///
/// Progress, not a request: the backfill runs on its own, so the only button
/// is for the one state where waiting is the app's choice rather than the
/// work's — a pause after the endpoint or model failed.
class _BackfillNotice extends StatelessWidget {
  const _BackfillNotice({required this.backfill});

  final EmbeddingBackfill backfill;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: backfill,
      builder: (context, _) {
        final pending = backfill.pending;
        if (pending == 0) return const SizedBox.shrink();
        final reason = backfill.pausedReason;
        if (reason != null) {
          return _Notice(
            icon: Icons.sync_problem_rounded,
            // l10n-ignore: the second line is the endpoint's own error.
            text: '${context.l10n.searchIndexingPaused(pending)}\n$reason',
            action: TextButton(
              onPressed: () => unawaited(backfill.retryNow()),
              child: Text(context.l10n.searchIndexingRetry),
            ),
          );
        }
        return _Notice(
          icon: Icons.sync_rounded,
          text: context.l10n.searchIndexingProgress(pending),
          // Indeterminate until the first batch lands — the bar has nothing
          // to measure before the drain has a total.
          progress: backfill.progress,
          showProgress: true,
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.action,
    this.progress,
    this.showProgress = false,
  });

  final IconData icon;
  final String text;
  final Widget? action;
  final double? progress;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: WeftSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(text, style: context.text.bodySmall),
                if (showProgress) ...[
                  const SizedBox(height: WeftSpace.xs),
                  LinearProgressIndicator(value: progress, minHeight: 2),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
