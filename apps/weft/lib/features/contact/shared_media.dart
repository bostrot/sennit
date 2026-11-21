/// What has been shared in a conversation: its photos and videos, and the
/// links people sent.
///
/// The chat info screen's answer to "where was that picture" — every phone
/// messenger has it, and without it the only way back to a photo from last
/// month is scrolling the conversation until it turns up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import '../../app/a11y.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../services/links/link_preview_service.dart';
import '../chat/attachment_bubble.dart';
import '../chat/link_preview_card.dart';
import '../chat/media_gallery.dart';
import '../chat/media_viewer.dart';
import '../chat/rich_text_view.dart';

/// How many messages back the screen looks before it settles for what it has.
///
/// The timeline is paged from the server, and walking a conversation's entire
/// history to fill a strip of thumbnails would turn opening the info screen
/// into a sync. A few hundred messages covers "recently", which is what the
/// strip promises; anything older is still in the conversation itself.
const int kSharedContentReach = 300;

/// Thumbnails in the info screen's strip before "See all" takes over.
const int kSharedMediaStrip = 12;

/// Link rows in the info screen before "See all" takes over.
const int kSharedLinksPreview = 3;

/// One url someone sent, and the message it came in.
@immutable
class SharedLink {
  const SharedLink({required this.url, required this.message});

  final String url;

  /// Carried for its network, which decides whether a preview may be fetched.
  final WeftMessage message;
}

/// A conversation's photos, videos and links.
@immutable
class SharedContent {
  const SharedContent({required this.media, required this.links});

  /// Builds both lists from a newest-first timeline.
  factory SharedContent.of(List<WeftMessage> newestFirst) {
    final seen = <String>{};
    return SharedContent(
      // Photos and videos only. A sticker is a reaction rather than something
      // anyone goes looking for later, and every messenger leaves them out of
      // this grid.
      media: [
        for (final message in viewableMedia(newestFirst))
          if (!message.redacted && kSharedMediaKinds.contains(message.kind))
            message,
      ],
      // Newest first, one row per url: the same link pasted twice is one
      // thing that was shared, and the row that matters is the latest.
      links: [
        for (final message in newestFirst)
          if (!message.redacted && !rendersAsAttachment(message))
            for (final url in extractLinkUrls(messageDocument(message)))
              if (seen.add(url)) SharedLink(url: url, message: message),
      ],
    );
  }

  static const SharedContent empty = SharedContent(media: [], links: []);

  /// Oldest first, the order [openMediaViewer] swipes through.
  final List<WeftMessage> media;

  /// Newest first, the order a list of links is read in.
  final List<SharedLink> links;

  bool get isEmpty => media.isEmpty && links.isEmpty;
}

/// Kinds that count as shared media here.
const Set<MessageKind> kSharedMediaKinds = {
  MessageKind.image,
  MessageKind.video,
};

/// The shared content of one conversation.
///
/// Reads the same timeline the conversation does, paging back until it holds
/// [kSharedContentReach] messages or history runs out. Disposed with the
/// screen, so reopening it picks up whatever arrived in between.
final sharedContentProvider = FutureProvider.autoDispose
    .family<SharedContent, String>((ref, chatId) async {
      final timeline = await ref
          .watch(chatRepositoryProvider)
          .timelineFor(chatId);
      var view = timeline.view();
      while (view.messages.length < kSharedContentReach &&
          timeline.hasMoreHistory) {
        final before = view.messages.length;
        view = await timeline.loadMoreUntilVisibleGrowth(count: 50);
        if (view.messages.length == before) break;
      }
      return SharedContent.of(view.messages);
    });

/// Opens [url] in whatever on the device handles it.
///
/// No confirmation, unlike a tap on a link inside a bubble: there the anchor
/// text can claim one host while the href names another, and here the row
/// shows the url itself.
Future<void> openSharedLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  final noHandler = context.l10n.chatLinkNoHandler;
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) showWeftMessage(context, noHandler);
  } on Object catch (error) {
    // Deliberately Object: a platform with no handler registered throws out
    // of the method channel rather than answering false.
    debugPrint('weft: could not open $url: $error');
    if (context.mounted) showWeftMessage(context, noHandler);
  }
}

/// Opens [message] full screen, swiping through the rest of [media].
void _openMedia(
  BuildContext context,
  List<WeftMessage> media,
  WeftMessage message,
) {
  final index = media.indexOf(message);
  unawaited(
    openMediaViewer(
      context,
      items: index < 0 ? [message] : media,
      initialIndex: index < 0 ? 0 : index,
    ),
  );
}

/// The Media and Links sections of the chat info screen.
///
/// Draws nothing while the timeline loads, when it fails, and for a
/// conversation with nothing shared in it: a heading over an empty strip is a
/// promise of content that is not there.
class SharedContentSections extends ConsumerWidget {
  const SharedContentSections({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content =
        ref.watch(sharedContentProvider(chatId)).value ?? SharedContent.empty;
    if (content.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (content.media.isNotEmpty) ...[
          _SeeAllHeader(
            title: l10n.contactMedia,
            seeAllLabel: l10n.contactSeeAllMedia(content.media.length),
            onSeeAll: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SharedMediaScreen(chatId: chatId),
              ),
            ),
          ),
          SharedMediaStrip(media: content.media),
        ],
        if (content.links.isNotEmpty) ...[
          _SeeAllHeader(
            title: l10n.contactLinks,
            seeAllLabel: l10n.contactSeeAllLinks(content.links.length),
            onSeeAll: content.links.length <= kSharedLinksPreview
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SharedLinksScreen(chatId: chatId),
                    ),
                  ),
          ),
          for (final link in content.links.take(kSharedLinksPreview))
            SharedLinkTile(link: link),
        ],
      ],
    );
  }
}

/// The newest photos and videos in one horizontal row.
class SharedMediaStrip extends StatelessWidget {
  const SharedMediaStrip({super.key, required this.media});

  /// Oldest first, as [SharedContent.media] holds them.
  final List<WeftMessage> media;

  static const double tileSize = 88;

  @override
  Widget build(BuildContext context) {
    final newest = media.reversed.take(kSharedMediaStrip).toList();
    return SizedBox(
      height: tileSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
        itemCount: newest.length,
        separatorBuilder: (_, _) => const SizedBox(width: WeftSpace.xs),
        itemBuilder: (context, i) => MediaTile(
          key: ValueKey(mediaHeroTag(newest[i])),
          message: newest[i],
          label: context.l10n.messageKind(newest[i].kind),
          size: tileSize,
          onOpen: () => _openMedia(context, media, newest[i]),
        ),
      ),
    );
  }
}

/// Every photo and video in reach, newest first, as a grid.
class SharedMediaScreen extends ConsumerWidget {
  const SharedMediaScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media =
        (ref.watch(sharedContentProvider(chatId)).value ?? SharedContent.empty)
            .media;
    final newest = media.reversed.toList();
    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.contactMedia)),
      body: GridView.builder(
        padding: const EdgeInsets.all(WeftSpace.xs),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 128,
          mainAxisSpacing: WeftSpace.xs,
          crossAxisSpacing: WeftSpace.xs,
        ),
        itemCount: newest.length,
        itemBuilder: (context, i) => LayoutBuilder(
          builder: (context, constraints) => MediaTile(
            key: ValueKey(mediaHeroTag(newest[i])),
            message: newest[i],
            label: context.l10n.messageKind(newest[i].kind),
            size: constraints.maxWidth,
            onOpen: () => _openMedia(context, media, newest[i]),
          ),
        ),
      ),
    );
  }
}

/// Every link in reach, newest first.
class SharedLinksScreen extends ConsumerWidget {
  const SharedLinksScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links =
        (ref.watch(sharedContentProvider(chatId)).value ?? SharedContent.empty)
            .links;
    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.contactLinks)),
      body: WeftReadingPane(
        maxWidth: 640,
        child: ListView.builder(
          itemCount: links.length,
          itemBuilder: (context, i) => SharedLinkTile(link: links[i]),
        ),
      ),
    );
  }
}

/// One shared link: the page's title and picture when a preview may be had,
/// the bare host otherwise, and the url under it either way.
///
/// Asks for the preview through the same gate and cache as the card under a
/// bubble, so a link already previewed in the conversation costs nothing and a
/// network the user excluded from previews stays excluded here.
class SharedLinkTile extends ConsumerWidget {
  const SharedLinkTile({super.key, required this.link});

  final SharedLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = link.message.network;
    final encrypted = link.message.encrypted;
    final preview =
        ref
            .watch(linkPreviewServiceProvider)
            .allows(network, encrypted: encrypted)
        ? ref
              .watch(
                linkPreviewProvider(
                  LinkPreviewRequest(link.url, network, encrypted: encrypted),
                ),
              )
              .value
        : null;
    final host = Uri.tryParse(link.url)?.host ?? link.url;
    final image = preview?.imageUrl;

    return ListTile(
      leading: image == null
          ? const Icon(Icons.link_rounded)
          : LinkPreviewThumbnail(mxc: image, size: 40),
      title: Text(
        preview?.title ?? host,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(link.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => openSharedLink(context, link.url),
    );
  }
}

/// A section heading with a "See all" on its trailing edge.
class _SeeAllHeader extends StatelessWidget {
  const _SeeAllHeader({
    required this.title,
    required this.seeAllLabel,
    this.onSeeAll,
  });

  final String title;

  /// What a screen reader hears for the button: "See all" beside a heading is
  /// clear to the eye and means nothing read on its own.
  final String seeAllLabel;

  /// Null hides the button, for a section already showing everything.
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        WeftSpace.lg,
        WeftSpace.md,
        WeftSpace.sm,
        WeftSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: context.text.labelLarge?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              child: Text(
                context.l10n.contactSeeAll,
                semanticsLabel: seeAllLabel,
              ),
            ),
        ],
      ),
    );
  }
}
