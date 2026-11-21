/// The card under a bubble that says what is behind the link in it.
///
/// Everything here is built around one rule: **absence is the default and
/// absence is not an error.** The gate being off, the network being excluded,
/// an encrypted room the user has not opted into, no homeserver, a request the
/// homeserver refused, a page with no OpenGraph tags, a fetch still in flight —
/// the reader sees the same thing in all seven cases, which is their message and nothing else. A card that announced its
/// own failure would turn a privacy setting the user chose into a row of
/// apologies down the conversation, and would leak which links the homeserver
/// declined to look at.
///
/// The content is a stranger's, twice over: the sender chose the url and the
/// page behind it chose the words. It is rendered as *text only* — never
/// through [parseFormattedBody], never as markup — and clamped by
/// [LinkPreview] on the way in and on the way out of the cache.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import '../../app/localisation.dart';
import '../../services/links/link_preview_service.dart';
import 'attachment_bubble.dart';
import 'rich_text_view.dart';

/// The preview for [message]'s first link, or nothing at all.
///
/// Takes the message rather than a url so the decision of *which* link is made
/// in one place — [firstPreviewableUrl], which picks the first because a
/// message carrying five links is a list and five cards under it bury the words
/// the sender wrote.
///
/// Reuses [messageDocument], so the parse is the same one the bubble's text
/// already paid for; a scroll past this widget costs a map lookup.
class LinkPreviewCard extends ConsumerWidget {
  const LinkPreviewCard({
    super.key,
    required this.message,
    required this.own,
    this.onTapUrl,
  });

  final WeftMessage message;

  /// Which side of the conversation this bubble is on, which decides the ink
  /// the card has to stay readable in.
  final bool own;

  /// Same signature as the bubble's link taps, so the card and a tap on the
  /// url inside the message go through one confirmation path.
  final void Function(String url, String label)? onTapUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A deleted message has no link left to be curious about, and an
    // attachment's body is a filename.
    if (message.redacted || rendersAsAttachment(message)) {
      return const SizedBox.shrink();
    }

    // Asked before the document is even looked at: with the gate closed there
    // is no reason to walk a tree looking for something that will not be
    // shown.
    final settings = ref.watch(linkPreviewSettingsProvider);
    if (!settings.showsCards(message.network)) return const SizedBox.shrink();

    final url = firstPreviewableUrl(messageDocument(message));
    final attached = message.bridgedLinkPreviews;

    final LinkPreview? preview;
    if (attached != null) {
      // The sender — a bridge relaying what WhatsApp showed, or a client that
      // supports MSC4095 — already said what is behind the link. That answer
      // costs no request, needs no gate beyond the master switch, and wins
      // over anything the homeserver could add; an empty list is the sender
      // saying "no card", and is honoured.
      preview = embeddedLinkPreview(attached, firstUrl: url);
    } else if (url == null) {
      return const SizedBox.shrink();
    } else {
      // A known answer — from this run, or from the disk cache — draws in the
      // first frame, so a card scrolled back into view does not pop in again.
      // Only an unknown one goes through the provider and its request.
      final peek = ref
          .watch(linkPreviewServiceProvider)
          .peek(url, network: message.network, encrypted: message.encrypted);
      preview = peek.known
          ? peek.preview
          : ref
                .watch(
                  linkPreviewProvider(
                    LinkPreviewRequest(
                      url,
                      message.network,
                      encrypted: message.encrypted,
                    ),
                  ),
                )
                .value;
    }

    final shown = preview != null && preview.hasContent ? preview : null;

    // Grows into place rather than jumping in. A card that arrives with the
    // homeserver's answer would otherwise shove every bubble below it by its
    // own height in a single frame, under the reader's eye. One that is
    // already known when the bubble is built has no previous size to grow
    // from, and appears without moving anything.
    return AnimatedSize(
      duration: context.motion.normal,
      curve: WeftMotion.enter,
      alignment: AlignmentDirectional.topStart,
      child: shown == null
          ? const SizedBox.shrink()
          : LinkPreviewCardBody(
              preview: shown,
              own: own,
              network: message.network,
              onTap: onTapUrl == null
                  ? null
                  : () => onTapUrl!(shown.url, shown.title ?? shown.url),
            ),
    );
  }
}

/// The card itself, with no provider behind it.
///
/// Split out so a golden can be taken of a known preview without a homeserver,
/// a cache or a settings row — and so the widget that decides *whether* to draw
/// stays separate from the one that decides *how*.
class LinkPreviewCardBody extends StatelessWidget {
  const LinkPreviewCardBody({
    super.key,
    required this.preview,
    required this.own,
    required this.network,
    this.onTap,
    this.image,
  });

  final LinkPreview preview;
  final bool own;
  final ChatNetwork network;
  final VoidCallback? onTap;

  /// Overrides the image the card would resolve for itself.
  ///
  /// Tests and goldens only: the real one is an authenticated request to the
  /// homeserver, which a widget test has no way to answer.
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = own ? palette.ownBubbleText : palette.peerBubbleText;
    // The card's own fill: a half-strength own bubble over the bubble itself,
    // or the peer bubble as-is. Everything inside is read against this.
    final card = own
        ? WeftContrast.flatten(
            palette.ownBubble.withValues(alpha: 0.55),
            palette.ownBubble,
          )
        : palette.peerBubble;
    // The rule down the left is a graphic and owes 3:1; the host line above is
    // text and owes 4.5:1, which is why they are two different derivations of
    // the same brand colour.
    final accent = own ? ink : palette.networkColor(network);
    final hostInk = own
        ? ink
        : WeftContrast.ensure(palette.networkTextColor(network), card);

    // Four text nodes with no role between them — host, title, description and
    // a second host line — announced as loose fragments after the message they
    // belong to. One link node instead, with the host first, for the same
    // reason it is drawn first: it is the line the reader can trust.
    return Semantics(
      link: true,
      button: onTap != null,
      excludeSemantics: true,
      onTap: onTap,
      label: semanticsSentence([
        context.l10n.linkPreviewSemanticsRole,
        preview.siteName ?? preview.host ?? preview.url,
        preview.title,
        preview.description,
        if (preview.siteName != null && preview.host != null) preview.host,
      ]),
      child: Padding(
        padding: const EdgeInsets.only(top: WeftSpace.xs),
        child: Material(
          color: own
              ? palette.ownBubble.withValues(alpha: 0.55)
              : palette.peerBubble,
          borderRadius: WeftRadius.allSm,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                border: BorderDirectional(
                  start: BorderSide(color: accent, width: 3),
                ),
              ),
              padding: const EdgeInsetsDirectional.fromSTEB(
                WeftSpace.sm,
                WeftSpace.sm,
                WeftSpace.sm,
                WeftSpace.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preview.imageUrl != null) ...[
                    LinkPreviewThumbnail(mxc: preview.imageUrl!, image: image),
                    const SizedBox(width: WeftSpace.sm),
                  ],
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The host first and always. It is the only line the
                        // homeserver did not get from the page, so it is the one
                        // the reader can trust — and a title reading "Sign in to
                        // your bank" over a host reading `evil.test` is a
                        // question answered before it is asked.
                        Text(
                          preview.siteName ?? preview.host ?? preview.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.labelSmall?.copyWith(
                            color: hostInk,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                          ),
                        ),
                        if (preview.title != null) ...[
                          const SizedBox(height: WeftSpace.xxs),
                          Text(
                            preview.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodySmall?.copyWith(
                              color: ink,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        ],
                        if (preview.description != null) ...[
                          const SizedBox(height: WeftSpace.xxs),
                          Text(
                            preview.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodySmall?.copyWith(
                              color: palette.muted(ink, card, alpha: 0.7),
                              height: 1.25,
                            ),
                          ),
                        ],
                        // Only when the site named itself, since otherwise the
                        // line above already is the host.
                        if (preview.siteName != null &&
                            preview.host != null) ...[
                          const SizedBox(height: WeftSpace.xxs),
                          Text(
                            preview.host!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelSmall?.copyWith(
                              color: palette.muted(ink, card, alpha: 0.55),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The preview image, or the space where one would have been.
///
/// The uri is `mxc://` — a copy the homeserver already fetched and is hosting —
/// so loading it tells the site nothing. That is the property the whole feature
/// rests on, and it is why this never accepts an `http` url: a card that
/// resolved a remote `og:image` would quietly undo the proxying and load a
/// tracking pixel from the reader's own address.
///
/// A failed load falls back to a blank tile rather than a broken-image glyph.
/// The homeserver may not serve thumbnails, the media may have expired, the
/// token may have rotated — none of which is something the reader can act on.
///
/// Public because the chat info screen's list of shared links shows the same
/// picture beside each row, through the same gate.
class LinkPreviewThumbnail extends ConsumerWidget {
  const LinkPreviewThumbnail({
    super.key,
    required this.mxc,
    this.image,
    this.size = 56,
  });

  final String mxc;
  final ImageProvider? image;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = image ?? ref.watch(linkPreviewImageProvider(mxc));
    if (provider == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: WeftRadius.allXs,
      child: SizedBox(
        width: size,
        height: size,
        child: Image(
          image: provider,
          fit: BoxFit.cover,
          // The card's own node says everything there is to say about this
          // link; the picture is the page's choice of illustration and has no
          // description anyone here can vouch for.
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}
