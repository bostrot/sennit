import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';
import 'package:weft_search/weft_search.dart';

import '../../app/localisation.dart';

/// The words a reader typed into a conversation's search, as the needles the
/// matches are checked against.
///
/// Punctuation at a word's edges is dropped and inner punctuation kept: "6pm,"
/// is a person finishing a thought, while "e-mail" and "1.5" are the words.
List<String> chatSearchTerms(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .map(
      (t) => t.replaceAll(
        RegExp(r'''^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$''', unicode: true),
        '',
      ),
    )
    .where((t) => t.isNotEmpty)
    .toList(growable: false);

/// Every message in one conversation that says what was searched for, newest
/// first — the order the up arrow walks back through.
///
/// Two sources, because neither is the whole answer. The [indexed] hits are
/// the shared search index, which remembers history this session has not
/// paginated to; the [loaded] messages are the open timeline, which holds what
/// arrived a moment ago and has not been filed yet (the index is written after
/// the frame) and is the only source at all where there is no index.
///
/// Both are held to the same test — every term appears in the message's text,
/// or in its sender's name where [matchSenders] — and that test is not a
/// formality on the indexed side. The index also files each row under its
/// conversation's title, so a search for "Anna" in Anna's chat matches every
/// row in it through the title alone, and a reader stepping through "37 of
/// 412" for a word nobody wrote would rightly call the search broken.
List<String> chatSearchMatches({
  required String query,
  Iterable<SearchResult> indexed = const [],
  Iterable<WeftMessage> loaded = const [],
  bool matchSenders = false,
}) {
  final terms = chatSearchTerms(query);
  if (terms.isEmpty) return const [];

  bool says(String text, String sender) {
    final haystack = matchSenders
        ? '${text.toLowerCase()}\n${sender.toLowerCase()}'
        : text.toLowerCase();
    return terms.every(haystack.contains);
  }

  final at = <String, DateTime>{};
  for (final hit in indexed) {
    if (says(hit.body, hit.senderName)) at[hit.eventId] = hit.timestamp;
  }
  // The loaded copy wins: an edit lands in the timeline before the index is
  // rewritten, and a message deleted since it was filed must not be a match.
  for (final message in loaded) {
    if (message.redacted || !says(plainTextOf(message), message.senderName)) {
      at.remove(message.eventId);
      continue;
    }
    at[message.eventId] = message.timestamp;
  }

  final ids = at.keys.toList()..sort((a, b) => at[b]!.compareTo(at[a]!));
  return ids;
}

/// What a conversation's bar becomes while it is being searched.
///
/// The bar rather than a sheet or a field over the messages, because that is
/// where every messenger people already use puts it, and because the messages
/// are what the reader is looking at: the matches are found *in* them, one at
/// a time, and anything drawn over the timeline would cover the very bubble
/// the arrows just brought into view.
class ChatSearchBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatSearchBar({
    super.key,
    required this.mac,
    required this.controller,
    required this.focusNode,
    required this.matchSenders,
    required this.matches,
    required this.position,
    required this.searching,
    required this.onChanged,
    required this.onOlder,
    required this.onNewer,
    required this.onClose,
  });

  /// Whether to draw the desktop's toolbar. Passed in for the reason the
  /// conversation's own bar takes it: [preferredSize] has no context to ask.
  final bool mac;

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Whether names are searched too, which only a group says out loud — in a
  /// one-to-one chat every message is from one of two people already known.
  final bool matchSenders;

  /// Event ids, newest first, or null before anything has been searched.
  final List<String>? matches;

  /// Which of [matches] is on screen; 0 is the newest.
  final int position;

  /// A search is in flight. The count is withheld meanwhile rather than left
  /// showing the previous query's answer under the new query's words.
  final bool searching;

  final ValueChanged<String> onChanged;
  final VoidCallback onOlder;
  final VoidCallback onNewer;
  final VoidCallback onClose;

  @override
  Size get preferredSize =>
      Size.fromHeight(mac ? MacMetrics.toolbarHeight : 64);

  bool get _canOlder => !searching && position + 1 < (matches?.length ?? 0);
  bool get _canNewer => !searching && position > 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Escape here as well as over the timeline: the bar is not inside the
    // conversation's body, and the field is where the focus is.
    final field = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: WeftLabelledField(
        label: l10n.chatSearch,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          // Enter is "the next one back", as in a browser's find bar. The focus
          // is taken back because submitting would otherwise drop it, and the
          // second press is the one a reader stepping through results makes.
          onSubmitted: (_) {
            if (_canOlder) onOlder();
            focusNode.requestFocus();
          },
          decoration: InputDecoration(
            hintText: matchSenders
                ? l10n.chatSearchHintGroup
                : l10n.chatSearchHint,
            // Bare, as the inbox's search is in a toolbar: the theme's ring is
            // drawn outside the field and a bar clips it along the top.
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: mac,
            contentPadding: mac ? EdgeInsets.zero : null,
          ),
        ),
      ),
    );
    final status = _Status(
      matches: matches,
      position: position,
      searching: searching,
    );

    if (mac) {
      return MacGlass(
        kind: MacGlassKind.toolbar,
        border: Border(
          bottom: BorderSide(color: context.palette.divider, width: 0.5),
        ),
        child: MacToolbar(
          // The conversation's own bar keeps clear of the traffic lights on a
          // pushed route; the search that replaces it has to as well.
          leadingInset: macToolbarInsetFor(context),
          titleWidget: DecoratedBox(
            decoration: BoxDecoration(
              color: context.colors.onSurface.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(MacMetrics.controlRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.sm,
                vertical: WeftSpace.xs,
              ),
              child: field,
            ),
          ),
          actions: [
            status,
            const SizedBox(width: WeftSpace.sm),
            MacToolbarGroup(
              children: [
                MacToolbarButton(
                  icon: Icons.keyboard_arrow_up_rounded,
                  tooltip: l10n.chatSearchOlder,
                  onPressed: _canOlder ? onOlder : null,
                ),
                MacToolbarButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: l10n.chatSearchNewer,
                  onPressed: _canNewer ? onNewer : null,
                ),
                MacToolbarButton(
                  icon: Icons.close_rounded,
                  tooltip: l10n.chatSearchClose,
                  onPressed: onClose,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return AppBar(
      toolbarHeight: 64,
      backgroundColor: context.colors.surfaceContainerLowest,
      // Back closes the search, not the conversation — the arrow is where the
      // bar's own back arrow was a moment ago, and the reader is still here.
      leading: IconButton(
        tooltip: l10n.chatSearchClose,
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: onClose,
      ),
      titleSpacing: 0,
      title: field,
      actions: [
        status,
        IconButton(
          tooltip: l10n.chatSearchOlder,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: _canOlder ? onOlder : null,
        ),
        IconButton(
          tooltip: l10n.chatSearchNewer,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: _canNewer ? onNewer : null,
        ),
      ],
    );
  }
}

/// "3 of 12", "No matches", or nothing while there is nothing to count.
///
/// Live, so a screen reader hears the count change as the query is typed —
/// the arrows beside it being enabled is otherwise the only sign anything was
/// found.
class _Status extends StatelessWidget {
  const _Status({
    required this.matches,
    required this.position,
    required this.searching,
  });

  final List<String>? matches;
  final int position;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final matches = this.matches;
    if (searching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
        child: SizedBox(
          width: 16,
          height: 16,
          child: Semantics(
            label: context.l10n.searchSearching,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (matches == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.sm),
        child: Text(
          matches.isEmpty
              ? context.l10n.chatSearchNoResults
              : context.l10n.chatSearchPosition(position + 1, matches.length),
          style: context.text.labelMedium?.copyWith(
            color: matches.isEmpty
                ? context.colors.error
                : context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
