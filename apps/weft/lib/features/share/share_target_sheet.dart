import 'dart:async';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_share/weft_share.dart';

import '../../app/a11y.dart';
import '../../app/intents.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/share_providers.dart';
import '../../services/attachments/send_attachments.dart';
import '../chat/attachment_preview_sheet.dart';
import '../chat/send_network_chip.dart';

/// "Share to Braid": pick the conversation the shared content goes to.
///
/// Text and files take the same route out — `send` and
/// `sendAttachment`, exactly as the composer calls them — so a share is the
/// composer's send path with the picker replaced by an intent. What is different
/// is that the files arrive as `content://` URIs the app cannot open, which is
/// why the sheet resolves them the moment it opens rather than at the tap: a
/// 200 MB video has to be turned away *before* the user has chosen who to send
/// it to, not after.
///
/// Two steps, not one. Choosing the conversation and confirming the send are
/// separate because three things have to happen between them and none of them
/// fits on a list row: the caption can be edited, a merged chat's outgoing
/// network can be picked per target, and several conversations can be chosen at
/// once. The Direct Share path has worked this way since Phase 04 task 4 — a
/// pre-selected target lands on the confirmation rather than sending — and this
/// is that same step, reached from the list as well as from a launcher face.
Future<void> showShareTargetSheet(BuildContext context, SharedPayload payload) {
  return showWeftPanel<void>(
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

  /// The share as the ranker and the capability table need to see it.
  ///
  /// Held rather than derived per build because [ShareItem.fromSource] sniffs
  /// every file, and the list is re-ranked on each keystroke in the search
  /// field. The caption being editable does not change it: capability reads
  /// only the files, and every network carries text.
  ShareContent _content = const ShareContent();

  /// A send in flight. The list stops taking taps: two conversations chosen in
  /// quick succession would send the batch twice, and the second tap is always
  /// a mis-tap on a sheet that is about to close.
  bool _sending = false;

  /// Conversations ticked in the list. One is the ordinary case; several is a
  /// forward.
  final Set<String> _chosen = {};

  /// The confirmation step was reached from the list. Distinct from [_chosen]
  /// being non-empty, which is also true while the user is still ticking rows.
  bool _composing = false;

  /// The user asked for the list back after arriving with a target already
  /// chosen. A Direct Share row is four small faces and a mis-tap on it is
  /// ordinary; without this the only way out is to cancel the share and start
  /// again in the other app.
  bool _pickingAnother = false;

  /// What was typed in the search field, lower-cased and trimmed.
  String _query = '';

  /// Per-target outgoing network, for the merged chats where the answer is not
  /// forced. Absent means "whatever [_defaultNetworkFor] says", which is the
  /// chat's own stored send network whenever that network can carry the share.
  final Map<String, ChatNetwork> _networks = {};

  late final TextEditingController _caption = TextEditingController(
    text: widget.payload.text ?? '',
  );
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.payload.uris.isEmpty) {
      _resolved = const ResolvedShare();
      _content = ShareContent(text: widget.payload.text);
    } else {
      _resolve();
    }
  }

  @override
  void dispose() {
    _caption.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final resolved = await ref
        .read(sharedFileResolverProvider)
        .resolveSharedFiles(widget.payload);
    if (!mounted) return;
    setState(() {
      _resolved = resolved;
      _content = ShareContent(
        text: widget.payload.text,
        items: [
          for (final source in resolved.sources) ShareItem.fromSource(source),
        ],
      );
    });
  }

  Future<void> _send(List<Chat> targets) async {
    final resolved = _resolved;
    if (_sending || resolved == null || targets.isEmpty) return;
    setState(() => _sending = true);

    // Read before the awaits below: this method outlives the sheet — it pops
    // itself at the end — so `context` is not safe to look anything up on once
    // the first send has started.
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repository = ref.read(chatRepositoryProvider);
    final text = _caption.text.trim();
    final problems = <String>[];
    var delivered = 0;

    for (final chat in targets) {
      // Not persisted through `setSendNetwork`: the composer's chip is a
      // standing preference for a conversation the user is *in*, and a share is
      // one gesture aimed at a conversation they may not have opened in weeks.
      // Quietly moving where their next typed message goes is not part of what
      // they asked for.
      final via = _networkFor(chat);
      final failures = <String>[];

      // Text first: a photo shared with a caption reads the wrong way round when
      // the sentence lands after the picture.
      if (text.isNotEmpty) {
        try {
          await repository.send(chat.id, text, via: via);
        } on Object catch (error) {
          debugPrint('weft: shared text failed to send: $error');
          failures.add(l10n.shareTextFailed);
        }
      }

      failures.addAll(
        await sendAttachments(
          l10n,
          repository,
          chat.id,
          resolved.sources,
          via: via,
        ),
      );

      final attempted = (text.isNotEmpty ? 1 : 0) + resolved.sources.length;
      // A share is the strongest signal the ranker gets: the user picked this
      // conversation out of every conversation, for this content, on purpose.
      // Only when something actually went — a share that failed entirely should
      // not promote the chat it failed to reach.
      if (attempted > failures.length) {
        delivered++;
        unawaited(ref.read(shareShortcutServiceProvider).noteSend(chat.id));
      }
      // The name is only worth carrying when there is more than one target; on
      // a single share it is already the headline of the sentence above.
      problems.addAll(
        targets.length == 1
            ? failures
            : failures.map(
                (problem) => l10n.shareProblemInChat(chat.title, problem),
              ),
      );
    }

    final headline = switch (targets.length) {
      1 => l10n.shareSentToOne(targets.single.title),
      _ when delivered == targets.length => l10n.shareSentToAll(targets.length),
      _ => l10n.shareSentToSome(delivered, targets.length),
    };
    final report = problems.isEmpty
        ? headline
        : [
            if (delivered > 0) l10n.shareReportHeadline(headline),
            ...problems,
          ].join('\n');
    messenger.showSnackBar(SnackBar(content: Text(report)));
    // Announced from here rather than through `showWeftMessage`, because the
    // sheet is about to pop and take its `ScaffoldMessenger` with it — the
    // messenger was captured above for exactly that reason. This is the only
    // report that a share went anywhere, and a share is a fire-and-forget
    // gesture: there is no screen left afterwards to check.
    if (mounted) announce(context, report);
    navigator.pop();
  }

  /// The chat the share was already aimed at, or null to ask.
  ///
  /// Resolved against the chats on this device rather than trusted: the id comes
  /// from a shortcut the launcher may have been holding for weeks, and the chat
  /// behind it can have been archived, left or unmerged since. A stale target
  /// falls back to the picker, which is what a plain share does — the one thing
  /// that must not happen is sending to an id nothing on screen accounts for.
  Chat? _preselected(List<Chat> chats) {
    final id = widget.payload.targetChatId;
    if (id == null || _pickingAnother) return null;
    return chats.firstWhereOrNull((chat) => chat.id == id);
  }

  /// The networks of [chat] that can carry this share, in [Chat.networks] order.
  ///
  /// Empty only when every leg of a merged chat has refused the file, which the
  /// ranker treats as a reason to drop the target entirely — so this is empty
  /// here only for a chat the user reached past the list, through a launcher
  /// shortcut published before the file existed.
  List<ChatNetwork> _capableNetworks(Chat chat) => ref
      .read(shareTargetRankerProvider)
      .capabilities
      .capableNetworks(chat, _content);

  /// Which network this target's share rides.
  ///
  /// The user's pick if they made one and it is still a leg of the chat, else
  /// the default. Null hands the decision back to `sendSourceFor`, which is the
  /// right answer for a chat whose networks all refused the file: the send then
  /// fails with a sentence rather than being routed somewhere arbitrary.
  ChatNetwork? _networkFor(Chat chat) {
    final chosen = _networks[chat.id];
    if (chosen != null && chat.sources.any((s) => s.network == chosen)) {
      return chosen;
    }
    return _defaultNetworkFor(chat);
  }

  /// The chat's stored send network when it can carry the share, else the first
  /// leg that can.
  ///
  /// The stored network is a standing answer to "which app does this person
  /// actually read", so it wins whenever it is usable — but a 200 MB video
  /// aimed at the Signal leg of a merged chat is a send that will fail, and the
  /// WhatsApp leg beside it is the same conversation.
  ChatNetwork? _defaultNetworkFor(Chat chat) {
    final capable = _capableNetworks(chat);
    if (capable.isEmpty) return null;
    final stored = chat.sendNetwork;
    if (stored != null && capable.contains(stored)) return stored;
    return capable.first;
  }

  void _toggle(String chatId) {
    setState(() {
      if (!_chosen.remove(chatId)) _chosen.add(chatId);
    });
  }

  /// One row tapped with nothing ticked: the ordinary share, straight to the
  /// confirmation.
  void _chooseOnly(Chat chat) {
    setState(() {
      _chosen
        ..clear()
        ..add(chat.id);
      _composing = true;
    });
  }

  bool _matches(Chat chat) =>
      _query.isEmpty || chat.title.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    // The whole inbox, not `visibleChatsProvider`: the rail's network filter and
    // its archived toggle describe what the user is *browsing*, and a share
    // arriving from another app has nothing to do with either. The ranker drops
    // archived and source-less chats itself, so the eligible set is the same
    // one Direct Share publishes from.
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final resolved = _resolved;
    final text = widget.payload.text?.trim() ?? '';
    // Nothing left to send — every shared file failed to resolve and there was
    // no text alongside them, or the files are still being read. Either way the
    // list would be a row of taps that do nothing.
    final hasContent =
        resolved != null && (text.isNotEmpty || resolved.sources.isNotEmpty);

    // The same ranker the launcher shortcuts are published from, including this
    // run's send counts, so the four faces in Android's share sheet and the top
    // of this list are the same list twice rather than two orderings of it. No
    // cap: the shortcut surfaces have a handful of slots, this one has a scroll
    // bar and a search field.
    final ranked = ref
        .read(shareTargetRankerProvider)
        .rank(
          chats,
          now: clock.now(),
          content: _content,
          activity: ref.read(shareShortcutServiceProvider).activity,
          maxSlots: chats.length,
        );
    final byId = {for (final chat in chats) chat.id: chat};
    final targets = [for (final slot in ranked) ?byId[slot.chatId]];
    final rankedIds = {for (final chat in targets) chat.id};
    // Dropped by the capability filter — every network in the chat refused the
    // file. Shown, disabled, rather than omitted: a conversation missing from a
    // share sheet with no explanation is the failure mode the capability table
    // is written to avoid, and the user searching for it deserves the reason.
    final blocked = [
      for (final chat in chats)
        if (!chat.archived &&
            chat.sources.isNotEmpty &&
            !rankedIds.contains(chat.id))
          chat,
    ];

    final chosen = _chosenTargets(targets, byId);
    final preselected = chosen.isEmpty ? _preselected(targets + blocked) : null;
    final confirming = chosen.isNotEmpty ? _composing : preselected != null;
    final confirmTargets = chosen.isNotEmpty ? chosen : [?preselected];

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
                  _title(confirming, confirmTargets),
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.xs),
                // Live: this line says "Reading 3 files…" and then, some
                // seconds later, what those files turned out to be. Both the
                // wait and its end were silent, on the one screen where what is
                // about to be sent is the only thing worth knowing.
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _summary(text, resolved),
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
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
          if (confirming)
            Expanded(
              child: _ConfirmStep(
                targets: confirmTargets,
                caption: _caption,
                textOnly: _content.isTextOnly,
                enabled: hasContent && !_sending,
                networkFor: _networkFor,
                capableNetworks: _capableNetworks,
                onPickNetwork: (chat, network) =>
                    setState(() => _networks[chat.id] = network),
                onSend: () => _send(confirmTargets),
                onChooseAnother: _sending
                    ? null
                    : () => setState(() {
                        _composing = false;
                        _pickingAnother = true;
                        // "Another" replaces when one chat was chosen and adds
                        // when several were, which is why the button says two
                        // different things. A single tap picked the wrong name
                        // and the list has to come back clean — returning to it
                        // with that name still ticked means the next tap adds a
                        // second target instead of choosing the right one. A
                        // forward built out of five ticks must not lose four of
                        // them to a sixth.
                        if (_chosen.length == 1) _chosen.clear();
                      }),
                controller: controller,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                WeftSpace.xl,
                0,
                WeftSpace.xl,
                WeftSpace.sm,
              ),
              child: WeftLabelledField(
                label: context.l10n.shareSearchChats,
                child: TextField(
                  controller: _search,
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: context.l10n.shareSearchChats,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: context.l10n.shareClearSearch,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                    border: const OutlineInputBorder(
                      borderRadius: WeftRadius.pill,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _TargetList(
                controller: controller,
                targets: [
                  for (final chat in targets)
                    if (_matches(chat)) chat,
                ],
                blocked: [
                  for (final chat in blocked)
                    if (_matches(chat)) chat,
                ],
                chosen: _chosen,
                enabled: hasContent && !_sending,
                query: _query,
                onTap: (chat) =>
                    _chosen.isEmpty ? _chooseOnly(chat) : _toggle(chat.id),
                onToggle: (chat) => _toggle(chat.id),
              ),
            ),
            if (_chosen.isNotEmpty)
              _MultiSelectBar(
                count: _chosen.length,
                enabled: hasContent && !_sending,
                onClear: () => setState(_chosen.clear),
                onContinue: () => setState(() => _composing = true),
              ),
          ],
        ],
      ),
    );
  }

  /// The ticked chats, in ranked order.
  ///
  /// Anything ticked that has since fallen out of the ranking — a chat archived
  /// while the sheet was open — keeps its place at the end rather than
  /// disappearing from a confirmation the user is looking at.
  List<Chat> _chosenTargets(List<Chat> ranked, Map<String, Chat> byId) {
    if (_chosen.isEmpty) return const [];
    final order = {for (var i = 0; i < ranked.length; i++) ranked[i].id: i};
    return [for (final id in _chosen) byId[id]].nonNulls.toList()..sort(
      (a, b) => (order[a.id] ?? ranked.length).compareTo(
        order[b.id] ?? ranked.length,
      ),
    );
  }

  String _title(bool confirming, List<Chat> targets) {
    if (!confirming) return 'Share to…';
    return targets.length == 1
        ? 'Send to ${targets.single.title}'
        : 'Send to ${targets.length} chats';
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

/// The conversations, ranked, with the ones that cannot take this share below.
class _TargetList extends ConsumerWidget {
  const _TargetList({
    required this.controller,
    required this.targets,
    required this.blocked,
    required this.chosen,
    required this.enabled,
    required this.query,
    required this.onTap,
    required this.onToggle,
  });

  final ScrollController controller;

  /// Ranked and capable, in the order [ShareTargetRanker] put them.
  final List<Chat> targets;

  /// Filtered out by the capability table — drawn, disabled, with the reason.
  final List<Chat> blocked;

  final Set<String> chosen;
  final bool enabled;
  final String query;
  final ValueChanged<Chat> onTap;
  final ValueChanged<Chat> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (targets.isEmpty && blocked.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(WeftSpace.xl),
          child: Text(
            query.isEmpty
                ? context.l10n.shareNoChats
                : context.l10n.shareNoMatches,
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final headers = blocked.isEmpty ? 0 : 1;
    return ListView.builder(
      controller: controller,
      itemCount: targets.length + headers + blocked.length,
      itemBuilder: (context, i) {
        if (i < targets.length) {
          final chat = targets[i];
          return _TargetTile(
            chat: chat,
            enabled: enabled,
            selected: chosen.contains(chat.id),
            selecting: chosen.isNotEmpty,
            onTap: () => onTap(chat),
            onToggle: () => onToggle(chat),
          );
        }
        if (i == targets.length) {
          return Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              WeftSpace.xl,
              WeftSpace.md,
              WeftSpace.xl,
              WeftSpace.xs,
            ),
            child: Semantics(
              header: true,
              child: Text(
                context.l10n.shareCannotCarry,
                style: context.text.labelMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        return _TargetTile(
          chat: blocked[i - targets.length - headers],
          enabled: false,
          selected: false,
          selecting: false,
          reason: 'No network here takes this file',
          onTap: () {},
          onToggle: () {},
        );
      },
    );
  }
}

/// One conversation as a share target.
///
/// The avatar is the inbox's own [WeftAvatar], picture and all: a share sheet
/// that draws initials where the app draws faces reads as a different app's
/// list of the same people.
class _TargetTile extends ConsumerWidget {
  const _TargetTile({
    required this.chat,
    required this.enabled,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onToggle,
    this.reason,
  });

  final Chat chat;
  final bool enabled;
  final bool selected;

  /// At least one row is ticked, so a tap toggles rather than confirms.
  final bool selecting;

  /// Why this row cannot be chosen, when it cannot.
  final String? reason;

  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = reason ?? _lastActivity(chat);
    // One node for the row. A tile with an `onTap` *and* a `Checkbox` presents
    // a reader with two adjacent targets doing different things — open, and
    // add to the selection — neither of which said which chat it belonged to.
    // The blocked rows matter more: `enabled: false` lets a reader skip the
    // tile outright, so the reason it cannot take this share, which is the only
    // useful thing on it, never arrives.
    return Semantics(
      container: true,
      enabled: enabled,
      checked: reason != null ? null : selected,
      label: semanticsSentence([
        chat.title,
        chat.networks.map((n) => n.label).join(' and '),
        reason == null ? null : 'cannot take this share: $reason',
        reason != null ? null : subtitle,
      ]),
      excludeSemantics: true,
      // Restated: excluding the subtree excludes the tile's own actions with
      // it, and the long-press is how multi-select is entered at all.
      onTap: enabled ? onTap : null,
      onLongPress: enabled && !selecting ? onToggle : null,
      child: _tile(context, ref, subtitle),
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, String? subtitle) {
    return ListTile(
      enabled: enabled,
      selected: selected,
      leading: WeftAvatar(
        label: chat.title,
        imageUrl: chat.avatarUrl,
        imageHeaders: ref.watch(mediaHeadersProvider),
        networks: chat.networks,
        size: 40,
      ),
      title: Text(chat.title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: reason == null
                  ? null
                  : context.text.bodySmall?.copyWith(
                      color: context.colors.error,
                    ),
            ),
      // A checkbox rather than a long-press alone: forwarding to several people
      // is the reason the multi-select exists, and a gesture nothing on screen
      // mentions is a feature only its author finds.
      trailing: reason != null
          ? null
          // Kept reachable as its own node under the row's group label: adding
          // a target and opening one are different acts, and a reader needs
          // both. It is the *unlabelled* pair of them that was the bug.
          : NamedButton(
              label: selected
                  ? context.l10n.shareRemoveTarget(chat.title)
                  : context.l10n.shareAddTarget(chat.title),
              onPressed: enabled ? onToggle : null,
              child: Checkbox(
                value: selected,
                onChanged: enabled ? (_) => onToggle() : null,
              ),
            ),
      onTap: enabled ? onTap : null,
      onLongPress: enabled && !selecting ? onToggle : null,
    );
  }

  static String? _lastActivity(Chat chat) {
    final at = chat.lastMessage?.timestamp;
    return at == null ? null : DateFormat.yMMMd().format(at);
  }
}

/// "3 selected", and the way on.
class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.count,
    required this.enabled,
    required this.onClear,
    required this.onContinue,
  });

  final int count;
  final bool enabled;
  final VoidCallback onClear;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        WeftSpace.sm,
        WeftSpace.lg,
        WeftSpace.md,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.palette.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.shareChatsSelected(count),
                style: context.text.labelLarge,
              ),
            ),
            TextButton(
              onPressed: onClear,
              child: Text(context.l10n.commonClear),
            ),
            const SizedBox(width: WeftSpace.sm),
            FilledButton(
              onPressed: enabled ? onContinue : null,
              child: Text(context.l10n.commonContinue),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last step: what is going, where it is going, and on which network.
///
/// Reached two ways and identical in both — from the list, and straight away
/// when the intent already carried a `targetChatId` (an Android Direct Share
/// face, or the iOS extension's own picker). The user has already answered
/// "who" in that case, so asking again is the sheet arguing with the choice they
/// just made in another app.
///
/// It is still a confirmation and not an immediate send. The strip above shows
/// *what* is about to go, which is the half a share sheet's four small faces
/// cannot show, and a share is unrecallable in a way that earns one tap.
class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.targets,
    required this.caption,
    required this.textOnly,
    required this.enabled,
    required this.networkFor,
    required this.capableNetworks,
    required this.onPickNetwork,
    required this.onSend,
    required this.onChooseAnother,
    required this.controller,
  });

  final List<Chat> targets;
  final TextEditingController caption;

  /// Nothing but text is being shared, so the field below is the message rather
  /// than a caption on a picture.
  final bool textOnly;

  /// False while the files are still being read, and after the send has begun.
  final bool enabled;

  final ChatNetwork? Function(Chat chat) networkFor;
  final List<ChatNetwork> Function(Chat chat) capableNetworks;
  final void Function(Chat chat, ChatNetwork network) onPickNetwork;

  final VoidCallback onSend;

  /// Null once a send is in flight — there is no longer another chat to choose.
  final VoidCallback? onChooseAnother;

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.xl),
            children: [
              TextField(
                controller: caption,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: textOnly
                      ? context.l10n.chatComposerMessage
                      : context.l10n.shareCaptionField,
                  hintText: textOnly
                      ? context.l10n.chatComposerMessage
                      : context.l10n.shareCaptionHint,
                ),
              ),
              const SizedBox(height: WeftSpace.sm),
              for (final chat in targets)
                _ConfirmTargetTile(
                  chat: chat,
                  network: networkFor(chat),
                  capable: capableNetworks(chat),
                  onPickNetwork: (network) => onPickNetwork(chat, network),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            WeftSpace.sm,
            WeftSpace.lg,
            WeftSpace.md,
          ),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.palette.border)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: enabled ? onSend : null,
                    icon: const Icon(Icons.send),
                    label: Text(
                      targets.length == 1
                          ? context.l10n.shareSendToOne(targets.single.title)
                          : context.l10n.shareSendToMany(targets.length),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onChooseAnother,
                  child: Text(
                    targets.length == 1
                        ? context.l10n.shareChooseAnother
                        : context.l10n.shareChangeSelection,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One chosen conversation, and the network its copy of the share rides.
class _ConfirmTargetTile extends ConsumerWidget {
  const _ConfirmTargetTile({
    required this.chat,
    required this.network,
    required this.capable,
    required this.onPickNetwork,
  });

  final Chat chat;

  /// Resolved answer for this target, or null when nothing here can carry it.
  final ChatNetwork? network;

  /// The legs of [chat] that can take this share. One is not a choice; none is
  /// a problem worth saying out loud.
  final List<ChatNetwork> capable;

  final ValueChanged<ChatNetwork> onPickNetwork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: WeftAvatar(
        label: chat.title,
        imageUrl: chat.avatarUrl,
        imageHeaders: ref.watch(mediaHeadersProvider),
        networks: chat.networks,
        size: 40,
      ),
      title: Text(chat.title),
      subtitle: Text(
        switch (network) {
          null => 'No network here takes this file',
          final n => 'via ${n.label}',
        },
        style: network == null
            ? context.text.bodySmall?.copyWith(color: context.colors.error)
            : null,
      ),
      // The composer's own chip, narrowed to the legs that can carry this
      // share: offering Signal for a 200 MB video is offering a send that
      // fails, and the WhatsApp leg beside it is the same conversation.
      trailing: capable.length > 1 && network != null
          ? SendNetworkChip(
              chat: chat,
              current: network!,
              networks: capable,
              onPick: onPickNetwork,
            )
          : null,
    );
  }
}

/// The shared files, as pictures rather than as a count.
///
/// A share sheet is opened from another app, so the user has already lost sight
/// of what they picked; "3 files" is not enough to catch having shared the wrong
/// screenshot. The tiles are the composer's own — [AttachmentSourceThumbnail] —
/// so a photo looks the same on the way in as it does on the way out, and the
/// name under each is what a tooltip cannot be on a touchscreen.
///
/// Deliberately *not* `AttachmentBubble`, despite the phase asking for it: that
/// widget dispatches on `WeftMessage.kind` and fetches its pixels through
/// `ChatRepository.attachmentBytes(roomId, eventId)`. A staged share has no
/// event, no room and no bytes on the homeserver, so every photo would draw the
/// broken-attachment placeholder — and reaching it at all would mean inventing
/// a `WeftMessage` with a fabricated event id. The rule behind the instruction
/// is "no second preview implementation", and this is the first one: the same
/// tile the attachment preview sheet shows before a send from the composer.
class _SharedFileStrip extends StatelessWidget {
  const _SharedFileStrip({required this.sources});

  final List<AttachmentSource> sources;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.sm),
      child: SizedBox(
        // Scaled with the caption under each thumbnail. At 2.0x the label alone
        // is around 24dp, and a fixed 88 put the name through the bottom of the
        // strip.
        height: 64 + WeftSpace.xxs + MediaQuery.textScalerOf(context).scale(16),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: sources.length,
          separatorBuilder: (_, _) => const SizedBox(width: WeftSpace.xs),
          itemBuilder: (context, i) {
            final source = sources[i];
            return SizedBox(
              width: 64,
              // One node per file: a thumbnail with no label and a name beneath
              // it were two nodes, and only one of them said anything.
              child: MergeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AttachmentSourceThumbnail(
                      source: source,
                      // The same sniff the plan will run, so the icon here and the
                      // bubble that follows cannot disagree about what this is.
                      kind: messageKindFor(sniffMimeType(source)),
                      size: 64,
                    ),
                    const SizedBox(height: WeftSpace.xxs),
                    Text(
                      source.basename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
