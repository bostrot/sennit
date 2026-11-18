import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

/// The quoted context above a reply, as one tappable line.
///
/// Two states, and the second is the reason this is a widget rather than a
/// `Text`. A [ReplyPreview.stub] is a reply whose target has not been paginated
/// in yet: the chip still renders, still says it is answering something, and is
/// still tappable — because tapping it is how the timeline is told to go and
/// fetch the thing. An answer with no visible question is a worse lie than an
/// answer above a greyed-out "message not loaded".
class ReplyChip extends StatelessWidget {
  const ReplyChip({
    super.key,
    required this.preview,
    required this.own,
    this.onTap,
    this.compact = false,
  });

  final ReplyPreview preview;

  /// Whether the chip sits inside the user's own bubble, which decides which
  /// text colour it has to stay readable against.
  final bool own;

  final VoidCallback? onTap;

  /// The composer's context bar, which sits on the app surface rather than
  /// inside a bubble and has room for two full lines.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = _title(l10n);
    final body = _body(l10n);
    final palette = context.palette;
    final ink = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bubble = own ? palette.ownBubble : palette.peerBubble;
    // The chip tints the bubble it sits in, so this — not the bubble — is the
    // background everything inside it has to be readable against.
    final fill = WeftContrast.flatten(ink.withValues(alpha: 0.10), bubble);

    // The rule down the left takes the network's colour when the target is on a
    // known leg — in a merged chat that is the answer to "which app was this
    // said on?", which the reply itself may not share.
    final accent = preview.network == null
        ? ink.withValues(alpha: 0.45)
        : palette.networkColor(preview.network!);

    // The title is *text*, so it owes 4.5:1 rather than the rule's 3:1 — and
    // on the user's own bubble it gives up the network colour entirely, which
    // is derived from the same primary the bubble is filled with and would be
    // invisible against it. Same rule the merged-bubble label follows.
    final titleInk = preview.network == null || own
        ? ink
        : WeftContrast.ensure(palette.networkTextColor(preview.network!), fill);

    // One node, and a button only when there is somewhere to go. The chip's
    // title and body were two separate announcements, and the stub — the state
    // whose whole purpose is to say "tap me and I will go and find it" — had no
    // way of saying so.
    return Semantics(
      button: onTap != null,
      // Its own node. Inside the composer's context bar the chip would
      // otherwise merge into the live region above it, and the bar would
      // announce the quoted message twice — once as its own summary and once
      // as the chip's.
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      label: semanticsSentence([
        preview.isStub ? title : l10n.chatReplyingTo(title),
        if (preview.network != null && !preview.isStub)
          l10n.replyChipOnNetwork(preview.network!.label),
        body,
      ]),
      // Four dp short of the guideline on a one-line quote, and the chip is
      // the only way back to the message being answered — so it is the target
      // someone chasing a thread hits most often and misses most often.
      child: WeftTapTarget(
        child: Padding(
          padding: const EdgeInsets.only(bottom: WeftSpace.xs),
          child: Material(
            color: ink.withValues(alpha: 0.10),
            borderRadius: WeftRadius.allSm,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Container(
                constraints: BoxConstraints(maxWidth: compact ? 640 : 496),
                padding: const EdgeInsetsDirectional.fromSTEB(
                  WeftSpace.sm,
                  WeftSpace.xs,
                  WeftSpace.sm,
                  WeftSpace.xs,
                ),
                decoration: BoxDecoration(
                  border: BorderDirectional(
                    start: BorderSide(color: accent, width: 3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (preview.network != null) ...[
                          NetworkGlyph(network: preview.network!, size: 11),
                          const SizedBox(width: WeftSpace.xs),
                        ],
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelSmall?.copyWith(
                              color: preview.isStub
                                  ? palette.muted(ink, fill, alpha: 0.6)
                                  : titleInk,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      body,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(
                        color: palette.muted(
                          ink,
                          fill,
                          alpha: preview.isStub ? 0.55 : 0.8,
                        ),
                        fontStyle: body != preview.body
                            ? FontStyle.italic
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _title(AppL10n l10n) {
    if (preview.isStub) return l10n.replyChipStubTitle;
    return preview.senderName?.trim().isNotEmpty ?? false
        ? preview.senderName!
        : preview.senderId ?? l10n.replyChipUnknownSender;
  }

  /// The body line. When it differs from [ReplyPreview.body] it is stand-in
  /// text rather than the sender's words, and is set in italics so it is never
  /// mistaken for something they wrote.
  String _body(AppL10n l10n) {
    if (preview.isStub) return l10n.replyChipStubBody;
    if (preview.redacted) return l10n.chatMessageDeleted;
    if (preview.body.isNotEmpty) return preview.body;
    return l10n.messageKind(preview.kind ?? MessageKind.text);
  }
}
