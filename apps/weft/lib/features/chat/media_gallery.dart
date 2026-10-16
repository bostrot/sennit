/// Several photos sent together, drawn as one bubble with a grid in it.
///
/// A batch of thirteen pictures used to be thirteen full-size bubbles, which
/// pushed everything said around them off the screen. Every phone messenger
/// folds such a batch into one album — two by two, with a "+9" over the last
/// tile — and that is the shape a reader expects when they scroll past one.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../services/attachments/attachment_byte_cache.dart';
import 'attachment_bubble.dart';

/// How many photos in a row it takes to make an album.
///
/// Four, as WhatsApp does: it is the smallest batch that fills the grid, and
/// two or three pictures read perfectly well as bubbles of their own.
const int kGalleryMinimum = 4;

/// The longest pause between two photos of one batch.
///
/// Generous because the photos are separate events: a slow upload, or a bridge
/// relaying one picture at a time, spaces them out by seconds, not minutes.
const Duration kGalleryGap = Duration(minutes: 2);

/// One album: the photos it holds and where it sits in the list.
class GalleryRun {
  const GalleryRun({required this.items, required this.oldestIndex});

  /// The photos in reading order, oldest first — the order they were sent in.
  final List<WeftMessage> items;

  /// Index of [items.first] in the newest-first list the run came from.
  final int oldestIndex;
}

/// Where the albums are in a newest-first timeline.
class GalleryLayout {
  const GalleryLayout({required this.runs, required this.hidden});

  /// Keyed by the index of each album's *newest* photo, which is the row that
  /// draws it: the read marker and the ticks belong to the latest message.
  final Map<int, GalleryRun> runs;

  /// The rows whose photo is drawn by an album further down.
  final Set<int> hidden;

  static const GalleryLayout none = GalleryLayout(runs: {}, hidden: {});
}

/// Whether [message] can sit in an album at all.
///
/// Only a plain photo. A caption, a reply, a reaction or a thread is something
/// said about *that* picture, and folded into a grid it would either vanish or
/// appear to be about the whole batch. A photo that failed to send stands
/// alone too: the album shows one set of ticks, its newest photo's, and the
/// failure mark is the one thing about the batch that must not be hidden.
bool galleryEligible(WeftMessage message) =>
    message.kind == MessageKind.image &&
    rendersAsAttachment(message) &&
    !message.redacted &&
    message.deliveryState != DeliveryState.failed &&
    message.replyToEventId == null &&
    message.threadRootId == null &&
    message.reactions.isEmpty &&
    attachmentCaption(message) == null;

/// Finds the batches of photos in [newestFirst] that make an album.
///
/// A batch is [kGalleryMinimum] or more [galleryEligible] photos in a row, from
/// one sender on one network and in one room, on the same day and never more
/// than [kGalleryGap] apart. [standsAlone] keeps out anything the caller knows
/// more about — a photo with a thread hanging off it, say.
GalleryLayout galleryLayout(
  List<WeftMessage> newestFirst, {
  bool Function(WeftMessage message)? standsAlone,
}) {
  bool fits(WeftMessage m) =>
      galleryEligible(m) && !(standsAlone?.call(m) ?? false);

  final runs = <int, GalleryRun>{};
  final hidden = <int>{};
  var start = 0;
  while (start < newestFirst.length) {
    if (!fits(newestFirst[start])) {
      start++;
      continue;
    }
    var end = start;
    while (end + 1 < newestFirst.length &&
        fits(newestFirst[end + 1]) &&
        _sameBatch(newestFirst[end + 1], newestFirst[end])) {
      end++;
    }
    if (end - start + 1 >= kGalleryMinimum) {
      runs[start] = GalleryRun(
        items: newestFirst.sublist(start, end + 1).reversed.toList(),
        oldestIndex: end,
      );
      hidden.addAll([for (var i = start + 1; i <= end; i++) i]);
    }
    start = end + 1;
  }
  return runs.isEmpty
      ? GalleryLayout.none
      : GalleryLayout(runs: runs, hidden: hidden);
}

bool _sameBatch(WeftMessage older, WeftMessage newer) {
  final a = older.timestamp.toLocal();
  final b = newer.timestamp.toLocal();
  return older.senderId == newer.senderId &&
      older.isOwn == newer.isOwn &&
      older.network == newer.network &&
      older.roomId == newer.roomId &&
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      newer.timestamp.difference(older.timestamp).abs() <= kGalleryGap;
}

/// The album itself: up to four square tiles, the last one carrying "+N" when
/// there are more photos than tiles.
///
/// Each tile is its own control. Tapping one opens that photo in the viewer,
/// which already pages through every picture in the conversation — so the
/// photos behind "+N" are a swipe away rather than hidden.
class MediaGallery extends StatelessWidget {
  const MediaGallery({
    super.key,
    required this.items,
    this.onOpen,
    this.onActions,
  });

  /// Oldest first, as [GalleryRun.items] gives them.
  final List<WeftMessage> items;

  final ValueChanged<WeftMessage>? onOpen;

  /// Long-press on a tile: the actions for that one photo, so a single picture
  /// can still be deleted, forwarded or replied to.
  final ValueChanged<WeftMessage>? onActions;

  /// Square tiles, wider together than a lone photo's 220 so the grid does not
  /// shrink each picture to a thumbnail.
  static const double tileSize = 124;
  static const double gap = 3;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(4).toList();
    final more = items.length - shown.length;
    // Scaled down rather than clipped on a screen too narrow for two full
    // tiles beside an avatar; at its natural size everywhere else.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: tileSize * 2 + gap,
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < shown.length; i++)
              _GalleryTile(
                key: ValueKey(mediaHeroTag(shown[i])),
                message: shown[i],
                position: i + 1,
                total: items.length,
                more: i == shown.length - 1 ? more : 0,
                onOpen: onOpen == null ? null : () => onOpen!(shown[i]),
                onActions: onActions == null
                    ? null
                    : () => onActions!(shown[i]),
              ),
          ],
        ),
      ),
    );
  }
}

class _GalleryTile extends ConsumerStatefulWidget {
  const _GalleryTile({
    super.key,
    required this.message,
    required this.position,
    required this.total,
    required this.more,
    this.onOpen,
    this.onActions,
  });

  final WeftMessage message;
  final int position;
  final int total;

  /// Photos past the fourth, counted on the last tile. Zero everywhere else.
  final int more;

  final VoidCallback? onOpen;
  final VoidCallback? onActions;

  @override
  ConsumerState<_GalleryTile> createState() => _GalleryTileState();
}

/// Loads the same way a lone photo does, through the same cache, so a picture
/// already seen in the viewer or in an earlier layout costs nothing here.
class _GalleryTileState extends ConsumerState<_GalleryTile> {
  Uint8List? _bytes;
  bool _failed = false;

  String get _cacheKey =>
      AttachmentByteCache.keyFor(widget.message.roomId, widget.message.eventId);

  @override
  void initState() {
    super.initState();
    final cached = ref.read(attachmentByteCacheProvider).get(_cacheKey);
    if (cached != null) {
      _bytes = cached;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(widget.message.roomId, widget.message.eventId);
    if (bytes != null) {
      ref.read(attachmentByteCacheProvider).put(_cacheKey, bytes);
    }
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const size = MediaGallery.tileSize;
    return WeftFocusable(
      image: true,
      button: _bytes != null && widget.onOpen != null,
      onTap: _bytes == null ? null : widget.onOpen,
      onLongPress: widget.onActions,
      label: semanticsSentence([
        l10n.chatGalleryItem(widget.position, widget.total),
        if (widget.more > 0) l10n.chatGalleryMore(widget.more),
        if (_failed)
          l10n.attachmentCouldNotLoad
        else if (_bytes == null)
          l10n.attachmentLoading,
      ]),
      borderRadius: WeftRadius.allSm,
      child: ClipRRect(
        borderRadius: WeftRadius.allSm,
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              switch ((_bytes, _failed)) {
                // The same hero tag a lone photo uses, so the viewer flies
                // this tile open exactly as it would the full bubble.
                (final Uint8List bytes, _) => Hero(
                  tag: mediaHeroTag(widget.message),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                    errorBuilder: (_, _, _) => _placeholder(broken: true),
                  ),
                ),
                (_, true) => _placeholder(broken: true),
                _ => _placeholder(broken: false),
              },
              if (widget.more > 0)
                IgnorePointer(
                  child: ColoredBox(
                    color: context.colors.scrim.withValues(alpha: 0.45),
                    child: Center(
                      // A count, not a sentence: the spoken version above
                      // says it in words.
                      child: ExcludeSemantics(
                        // l10n-ignore: a count, the same in every language this app ships; its screen-reader label is translated.
                        child: Text(
                          '+${widget.more}',
                          style: context.text.headlineMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder({required bool broken}) => ColoredBox(
    color: context.colors.surfaceContainerHighest,
    child: Center(
      child: broken
          ? Icon(
              Icons.broken_image_outlined,
              color: context.colors.onSurfaceVariant,
            )
          : const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    ),
  );
}
