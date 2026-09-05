import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

import '../bidi.dart';
import '../focus.dart';
import '../semantics.dart';
import '../strings.dart';
import '../surface.dart';
import '../theme.dart';
import '../tokens.dart';
import 'network_glyph.dart';
import 'unread_badge.dart';
import 'weft_avatar.dart';

/// One conversation in the inbox.
///
/// A merged chat is signalled three ways so it never depends on colour alone:
/// the avatar's gradient ring, a row of network glyphs, and the "Merged" label
/// in its accessibility description.
///
/// The row has two builds, chosen by [WeftSurface] and differing only in
/// metrics and in how selection is drawn. A phone gets a 46pt avatar, a tinted
/// selection and room for the merged strip on its own line; a Mac gets the
/// system's list row — 32pt avatar, 13pt title, 11pt preview, and selection as
/// a filled accent capsule with its ink flipped, which is the one thing that
/// makes a list look like it belongs on the platform. Everything else — the
/// semantics sentence, the preview vocabulary, the delivery glyphs — is shared,
/// because none of it is a question about the machine.
class ChatTile extends StatefulWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.onTap,
    this.selected = false,
    this.timeLabel,
    this.onLongPress,
    this.avatarHeaders,
    this.leading,
    this.checked,
    this.typing = false,
    this.online = false,
  });

  /// Someone in this conversation is writing.
  ///
  /// Replaces the preview while it lasts, which is what makes it worth having:
  /// the preview is what the reader's eye is already on, and a note tucked
  /// anywhere else is one nobody sees in the second it is true for.
  final bool typing;

  /// The other person is online. Only meaningful for a one-to-one chat, and
  /// only where the homeserver serves presence at all.
  final bool online;

  /// The tick state while the inbox is in selection mode, or null when it is
  /// not selecting.
  ///
  /// The [leading] checkbox is inside this tile's merged semantics node and is
  /// therefore not announced on its own — which is the point, since on its own
  /// it announced "checkbox" and never said which conversation. The state has
  /// to arrive as a value so the one node can carry it.
  final bool? checked;

  /// Replaces the avatar while the inbox is in selection mode.
  final Widget? leading;

  /// Headers for the avatar fetch — Matrix media is authenticated.
  final Map<String, String>? avatarHeaders;

  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// Preformatted, locale-aware time string. Formatting lives in the app layer
  /// so this package stays free of `intl`.
  final String? timeLabel;

  @override
  State<ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<ChatTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final colors = context.colors;
    final mac = context.isMac;

    // On a Mac a selected row is filled with the accent colour, so every piece
    // of ink inside it has to move to `onPrimary` or become unreadable. Held
    // as one flag rather than tested at each of the seven text sites.
    final inverted = mac && widget.selected;
    final ink = inverted ? colors.onPrimary : colors.onSurface;
    final quiet = inverted
        ? colors.onPrimary.withValues(alpha: 0.78)
        : colors.onSurfaceVariant;

    final words = WeftDesignStringsScope.of(context);
    final radius = mac
        ? BorderRadius.circular(MacMetrics.listRowRadius)
        : WeftRadius.allLg;

    // Exclusive, and that is the whole fix for what a reader hears. The label
    // was right and the node was not a container, so the title, the pin, the
    // mute glyph, the delivery tick, the preview, the time and the unread badge
    // were *also* announced underneath it — the "five separate nodes read in
    // isolation" failure, with the correct sentence sitting on top of them.
    // `WeftFocusable` carries that recipe and adds the half the row was still
    // missing: a `GestureDetector` is not focusable, so Tab skipped every
    // conversation in the inbox.
    //
    // It has to be the outermost widget. `tester.getSemantics` and every
    // screen reader alike resolve a node by walking *up* from the widget, so a
    // `Padding` on top of it would hand back the list's node instead of the
    // row's, and the row's label would read as absent.
    return WeftFocusable(
      selected: widget.selected,
      checked: widget.checked,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onLongPressHint: words.selectHint,
      label: _semanticsLabel(words),
      borderRadius: radius,
      // Flush with the row's own box rather than 2dp outside it: the inbox
      // list clips its viewport, and a ring that overhangs is a ring with its
      // left and right edges shaved off.
      ringInset: 0,
      onHoverChanged: (value) => setState(() => _hovered = value),
      child: Padding(
        // The gap between one row's selection capsule and the next. Half a
        // step on the Mac, where the list is denser and the capsules are
        // meant to read as a stack rather than as cards.
        padding: const EdgeInsets.symmetric(
          horizontal: WeftSpace.sm,
          vertical: WeftSpace.xxs,
        ),
        child: AnimatedContainer(
          duration: mac ? context.motion.instant : context.motion.fast,
          curve: context.motion.standard,
          padding: mac
              ? const EdgeInsets.symmetric(
                  horizontal: WeftSpace.sm,
                  vertical: WeftSpace.dense,
                )
              : const EdgeInsets.symmetric(
                  horizontal: WeftSpace.md,
                  vertical: WeftSpace.md,
                ),
          decoration: BoxDecoration(
            color: switch ((widget.selected, _hovered, mac)) {
              (true, _, true) => colors.primary,
              (true, _, false) => colors.primaryContainer,
              (_, true, true) => colors.onSurface.withValues(alpha: 0.06),
              (_, true, false) => colors.surfaceContainerHigh,
              _ => Colors.transparent,
            },
            borderRadius: radius,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.leading ??
                  WeftAvatar(
                    label: chat.title,
                    imageUrl: chat.avatarUrl,
                    imageHeaders: widget.avatarHeaders,
                    networks: chat.networks,
                    online: widget.online,
                    size: mac ? 32 : 46,
                  ),
              SizedBox(width: mac ? WeftSpace.sm : WeftSpace.md),
              Expanded(
                child: _body(
                  context,
                  words: words,
                  ink: ink,
                  quiet: quiet,
                  mac: mac,
                ),
              ),
              const SizedBox(width: WeftSpace.sm),
              _trailing(context, quiet: quiet, mac: mac, inverted: inverted),
            ],
          ),
        ),
      ),
    );
  }

  /// The whole row as one sentence, in reading order.
  ///
  /// Everything a sighted user gets from the row is in here, in the order they
  /// scan it: who, on what, in what state, what they said, when, and how much
  /// is unread. The three things the old label omitted are the ones that decide
  /// whether the row is worth opening at all — the preview, the time and the
  /// delivery state — and the network *names*, since "merged across 3 networks"
  /// never said which three.
  String _semanticsLabel(WeftDesignStrings words) {
    final chat = widget.chat;
    final last = chat.lastMessage;
    return semanticsSentence([
      chat.title,
      if (chat.isMerged)
        words.mergedAcross(
          chat.networks.length,
          chat.networks.map((n) => n.label).join(', '),
        )
      else
        chat.networks.firstOrNull?.label,
      if (chat.pinned) words.pinned,
      if (chat.muted) words.muted,
      if (last != null && last.isOwn) words.deliveryState(last.deliveryState),
      // The glyph's meaning, as a clause. A screen reader gets "…, reply, see
      // you at six, …" where a sighted reader gets an arrow in front of the
      // same words — and neither gets the mxid that used to be there instead.
      if (!widget.typing && _isReply(last)) words.reply,
      if (widget.typing) words.typing else _preview(words, last),
      if (widget.online) words.online,
      widget.timeLabel,
      if (chat.unreadCount > 0) words.unreadCount(chat.unreadCount),
    ]);
  }

  Widget _body(
    BuildContext context, {
    required WeftDesignStrings words,
    required Color ink,
    required Color quiet,
    required bool mac,
  }) {
    final chat = widget.chat;
    final unread = chat.unreadCount > 0;
    final last = chat.lastMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                chat.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Content, not chrome: a Hebrew name in an English inbox reads
                // right-to-left and truncates from the correct end, and so does
                // an English one in an Arabic inbox. Null for a title with no
                // strong character in it — "🎉" — which then inherits the row's.
                textDirection: textDirectionOf(chat.title),
                style: (mac ? context.text.bodyMedium : context.text.titleSmall)
                    ?.copyWith(
                      color: ink,
                      fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                    ),
              ),
            ),
            // Tooltips on the state glyphs, not labels: the row's own merged
            // node already says "pinned, muted" to a reader, and what these
            // add is the answer for a *sighted* user who does not recognise a
            // 13dp pictogram.
            if (chat.pinned) ...[
              const SizedBox(width: WeftSpace.xs),
              Tooltip(
                message: words.pinned,
                child: Icon(Icons.push_pin_rounded, size: 13, color: quiet),
              ),
            ],
            if (chat.muted) ...[
              const SizedBox(width: WeftSpace.xs),
              Tooltip(
                message: words.muted,
                child: Icon(
                  Icons.notifications_off_rounded,
                  size: 13,
                  color: quiet,
                ),
              ),
            ],
            // On a Mac the time belongs on the title's line, right-aligned —
            // the trailing column is the unread count's alone, so a row with
            // no unread does not leave a hole where a badge would have been.
            if (mac && widget.timeLabel != null) ...[
              const SizedBox(width: WeftSpace.sm),
              Text(
                widget.timeLabel!,
                style: context.text.labelSmall?.copyWith(color: quiet),
              ),
            ],
          ],
        ),
        // The gap between a row's title line and its preview line. One step on
        // both surfaces — the Mac's density comes from the row's own insets,
        // not from crushing two lines of type together.
        const SizedBox(height: WeftSpace.xxs),
        Row(
          children: [
            // `read` and `delivered` are the same double tick and differ only
            // in colour — the one distinction a colour-blind reader cannot
            // make. The tooltip is what names it for them; the row's merged
            // node is what names it for a screen reader. A shape that told the
            // two apart on sight would be a change to the mark itself, and
            // that belongs to whoever owns the design, not to a semantics pass.
            if (last != null && last.isOwn && !widget.typing) ...[
              Tooltip(
                message: words.deliveryState(last.deliveryState),
                child: Icon(
                  _deliveryIcon(last.deliveryState),
                  size: 14,
                  color: switch (last.deliveryState) {
                    // Inside a selected, accent-filled row the blue would sit
                    // on a purple fill; the row's own ink is what stays
                    // readable there.
                    DeliveryState.read when ink == context.colors.onPrimary =>
                      ink,
                    DeliveryState.read => context.palette.readReceiptOn(
                      context.colors.surface,
                    ),
                    _ => quiet,
                  },
                ),
              ),
              const SizedBox(width: WeftSpace.xs),
            ],
            // The reply marker. A glyph rather than a quoted line, because the
            // preview has one line and spending it on what somebody else said
            // is what the fallback was already doing wrong — the reader wants
            // the answer, and that it is an answer.
            //
            // Excluded from semantics here and named in the row's own sentence
            // instead: the row is one merged node, so a `Semantics` label on
            // this icon would be swallowed by it, and the tooltip is what
            // explains the pictogram to a sighted reader who does not know it.
            if (_isReply(last) && !widget.typing) ...[
              Tooltip(
                message: words.reply,
                child: ExcludeSemantics(
                  child: Icon(Icons.reply_rounded, size: 13, color: quiet),
                ),
              ),
              const SizedBox(width: WeftSpace.xs),
            ],
            Expanded(
              child: widget.typing
                  ? Text(
                      '${words.typing}…',
                      maxLines: 1,
                      style:
                          (mac
                                  ? context.text.labelSmall
                                  : context.text.bodySmall)
                              ?.copyWith(
                                // Inside a selected, accent-filled row the
                                // accent is the background; the row's ink is
                                // what stays legible.
                                color: ink == context.colors.onPrimary
                                    ? ink
                                    : context.colors.primary,
                                fontWeight: FontWeight.w600,
                              ),
                    )
                  : Text(
                      _preview(words, last),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // Same rule as the title: the preview is somebody's
                      // words, and its direction is theirs rather than the
                      // reader's locale.
                      textDirection: textDirectionOf(_preview(words, last)),
                      style:
                          (mac
                                  ? context.text.labelSmall
                                  : context.text.bodySmall)
                              ?.copyWith(
                                color: unread ? ink : quiet,
                                fontWeight: unread
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                    ),
            ),
            // The merged marks ride the preview's line on a Mac. A third line
            // would put the row at 60pt, which is a phone's row height in a
            // window that has to show twenty of them.
            if (mac && chat.isMerged) ...[
              const SizedBox(width: WeftSpace.xs),
              for (final n in chat.networks) ...[
                NetworkGlyph(network: n, size: 11),
                const SizedBox(width: 2),
              ],
            ],
          ],
        ),
        if (!mac && chat.isMerged) ...[
          const SizedBox(height: WeftSpace.sm),
          _MergedStrip(networks: chat.networks),
        ],
      ],
    );
  }

  Widget _trailing(
    BuildContext context, {
    required Color quiet,
    required bool mac,
    required bool inverted,
  }) {
    final chat = widget.chat;
    final palette = context.palette;

    if (mac) {
      if (chat.unreadCount == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: WeftUnreadBadge(
          count: chat.unreadCount,
          // Inside a selected, accent-filled row the badge cannot also be the
          // accent — it would vanish. It becomes the row's ink instead, with
          // the fill's colour as its own text.
          color: inverted ? context.colors.onPrimary : palette.unreadDot,
          ink: inverted ? context.colors.primary : context.colors.onPrimary,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.timeLabel != null)
          Text(
            widget.timeLabel!,
            style: context.text.labelSmall?.copyWith(
              color: chat.unreadCount > 0 ? context.colors.primary : quiet,
              fontWeight: chat.unreadCount > 0
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
        const SizedBox(height: WeftSpace.sm),
        if (chat.unreadCount > 0)
          WeftUnreadBadge(
            count: chat.unreadCount,
            color: palette.unreadDot,
            ink: context.colors.onPrimary,
          ),
      ],
    );
  }

  /// The emoji stay here and the words come from [words]: a picture of a
  /// camera means the same in every language, and putting it in the ARB would
  /// give a translator a chance to drop it.
  ///
  /// The text cases go through [stripReplyFallback] because [WeftMessage.body]
  /// is the event as sent, and a Matrix rich reply's body *opens with the
  /// message it answers* — `> <@signal_1234:beeper.local> see you at six`,
  /// then a blank line, then the actual reply. The bubble has always stripped
  /// it, through `parseMessageBody`; this line did not, so the inbox showed the
  /// quoted mxid where the answer belonged, and never showed the answer at all
  /// because the fallback is what fits in one line.
  ///
  /// An edit needs no special handling and gets none: `applyEdits` has already
  /// replaced [WeftMessage.body] with the replacement's, and a replacement
  /// carries its own fallback in the same shape.
  static String _preview(WeftDesignStrings words, WeftMessage? last) {
    if (last == null) return words.noMessagesYet;
    if (last.redacted) return words.messageDeleted;
    String kind(String emoji) => '$emoji ${words.messageKind(last.kind)}';
    return switch (last.kind) {
      MessageKind.image => kind('📷'),
      MessageKind.video => kind('🎥'),
      MessageKind.voice =>
        last.transcript != null ? '🎙 ${last.transcript}' : kind('🎙'),
      MessageKind.audio => kind('🎵'),
      MessageKind.file => kind('📎'),
      MessageKind.location => kind('📍'),
      MessageKind.sticker => words.messageKind(last.kind),
      MessageKind.poll => kind('📊'),
      MessageKind.event => _ownWords(words, last),
      MessageKind.text => _ownWords(words, last),
    };
  }

  /// [last]'s own text, with any quoted context removed.
  ///
  /// Falls back to the word for a reply when there is nothing left. That is a
  /// real case and not a defensive branch: a reply whose entire body is the
  /// fallback arrives from bridges that quote and say nothing — and an empty
  /// preview line reads as a conversation with no messages in it, which is the
  /// one thing it is not.
  static String _ownWords(WeftDesignStrings words, WeftMessage last) {
    final own = stripReplyFallback(last.body).trim();
    if (own.isNotEmpty) return own;
    return last.replyToEventId != null ? words.reply : '';
  }

  /// Whether the row should carry the small reply glyph.
  ///
  /// The relation decides, not the body: a reply to a photo has no text to
  /// strip and is still a reply, and a message that merely opens with a
  /// quotation is not one. `m.in_reply_to` is the only thing that knows.
  static bool _isReply(WeftMessage? last) =>
      last != null && !last.redacted && last.replyToEventId != null;

  /// One tick sent, two ticks arrived, two blue ticks read.
  static IconData _deliveryIcon(DeliveryState? state) => switch (state) {
    DeliveryState.sending => Icons.schedule_rounded,
    DeliveryState.failed => Icons.error_outline_rounded,
    DeliveryState.read || DeliveryState.delivered => Icons.done_all_rounded,
    _ => Icons.done_rounded,
  };
}

/// The row of network marks under a merged chat's preview.
class _MergedStrip extends StatelessWidget {
  const _MergedStrip({required this.networks});

  final List<ChatNetwork> networks;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: palette.mergedAccent.withValues(alpha: 0.16),
            borderRadius: WeftRadius.pill,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.merge_rounded, size: 11, color: palette.mergedAccent),
              const SizedBox(width: WeftSpace.xxs),
              Text(
                WeftDesignStringsScope.of(context).merged,
                style: context.text.labelSmall?.copyWith(
                  color: palette.mergedAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: WeftSpace.sm),
        // Wrapped and flexible, because the row above it is not fixed: the
        // trailing column holds a timestamp, and a conversation last spoken in
        // last month is "8/15/2026" where one from this morning is "09:05".
        // The wider label squeezes this strip, and a plain `Row` answers that
        // by overflowing — three and a half pixels of yellow-and-black stripe
        // on a real inbox, which the demo fixtures' short labels never
        // provoked.
        Expanded(
          child: Wrap(
            spacing: 3,
            runSpacing: 3,
            children: [
              for (final n in networks) NetworkGlyph(network: n, size: 14),
            ],
          ),
        ),
      ],
    );
  }
}
