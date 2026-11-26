/// The full-screen view of an attachment, and the way it leaves the app.
///
/// A picture in a bubble is a thumbnail with a caption under it; this is the
/// picture. The two are joined by a hero flight rather than a page push so the
/// photo the user tapped is visibly the photo that fills the screen — with a
/// cut, the eye has to find it again.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../services/attachments/media_exporter.dart';
import '../../services/attachments/media_store.dart';
import '../../services/attachments/video_surface.dart';
import 'attachment_bubble.dart';

/// Kinds the viewer can actually show a picture of.
///
/// Narrower than [kAttachmentKinds] on purpose: a PDF and a song open in the
/// viewer too — it is where Save and Share live — but they are not part of the
/// gallery a swipe moves through. Sliding from a photo of a dog to a
/// spreadsheet is not a gesture anyone means to make.
const Set<MessageKind> kViewableMediaKinds = {
  MessageKind.image,
  MessageKind.video,
  MessageKind.sticker,
};

/// The conversation's media, oldest first.
///
/// Oldest first because the timeline is held newest-first and a gallery is not:
/// swiping right must move forward in time, the way every photo roll does.
List<WeftMessage> viewableMedia(List<WeftMessage> messages) => [
  for (final message in messages.reversed)
    if (rendersAsAttachment(message) &&
        kViewableMediaKinds.contains(message.kind))
      message,
];

/// Opens [items] full screen, starting at [initialIndex].
///
/// A [PageRouteBuilder] with an opaque black background rather than a
/// `MaterialPageRoute`: the hero does the motion, and a page transition sliding
/// underneath it competes with the flight instead of supporting it.
Future<void> openMediaViewer(
  BuildContext context, {
  required List<WeftMessage> items,
  required int initialIndex,
}) {
  if (items.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: WeftMotion.normal,
      reverseTransitionDuration: WeftMotion.normal,
      pageBuilder: (_, _, _) =>
          MediaViewer(items: items, initialIndex: initialIndex),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Full-screen media, one page per item.
class MediaViewer extends ConsumerStatefulWidget {
  const MediaViewer({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<WeftMessage> items;
  final int initialIndex;

  @override
  ConsumerState<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<MediaViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// Attachments already on disk, keyed by event id.
  ///
  /// Held for the life of the viewer so swiping back to a video does not fetch
  /// it a second time, and so Share after Save is free.
  final Map<String, File> _staged = {};

  /// Why an item could not be staged. Rendered in place rather than as a
  /// snackbar: the failure belongs to the page it happened on, and a toast over
  /// a black screen leaves nothing behind explaining why it is black.
  final Map<String, String> _failures = {};

  /// Fetches under way, so a rebuild mid-download does not start a second one.
  ///
  /// The *future* rather than a flag, because Save tapped while a video is
  /// still coming down has to wait for that same download rather than give up:
  /// a button that does nothing on the one file slow enough to make the user
  /// reach for it is the worst possible case to fail on.
  final Map<String, Future<File?>> _fetching = {};

  bool _disposed = false;

  WeftMessage get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    unawaited(_stage(_current));
  }

  @override
  void dispose() {
    _disposed = true;
    _pages.dispose();
    super.dispose();
  }

  /// Puts [message]'s attachment on disk, once.
  ///
  /// Returns null when it could not be fetched; the reason is in [_failures] and
  /// on screen by the time this resolves.
  Future<File?> _stage(WeftMessage message) {
    final existing = _staged[message.eventId];
    if (existing != null) return Future.value(existing);
    if (_failures.containsKey(message.eventId)) return Future.value();
    return _fetching[message.eventId] ??= _fetch(message);
  }

  Future<File?> _fetch(WeftMessage message) async {
    try {
      final file = await ref
          .read(mediaFileStoreProvider)
          .stage(
            message,
            repository: ref.read(chatRepositoryProvider),
            // Leaving the viewer abandons the download. A user who backs out of
            // a 200 MB video has said what they want, and finishing it anyway
            // spends their data on a file nothing will open.
            shouldContinue: () async => !_disposed,
          );
      if (_disposed) return null;
      setState(() => _staged[message.eventId] = file);
      return file;
    } on MediaUnavailableException catch (e) {
      if (!_disposed) setState(() => _failures[message.eventId] = e.message);
      return null;
    } on Object catch (error) {
      // Deliberately Object: a cancelled download throws, and so does a full
      // disk, and neither should take the viewer down with it.
      debugPrint('weft: staging ${message.eventId} failed: $error');
      if (!_disposed) {
        // The reason rides along. "Could not be downloaded" with nothing after
        // it turns every distinct failure — an expired link, a 401, a full
        // disk — into the same unreportable sentence.
        setState(
          () => _failures[message.eventId] =
              '${context.l10n.mediaDownloadFailed}\n$error',
        );
      }
      return null;
    } finally {
      // The removed value is the future this call is already inside, so there
      // is nothing to wait for — only the key needed clearing.
      _fetching.remove(message.eventId)?.ignore();
    }
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final message = _current;
    final file = await _stage(message);
    if (file == null || !mounted) return;

    final exporter = ref.read(mediaExporterProvider);
    try {
      final path = await exporter.save(
        file,
        suggestedName: attachmentFileName(
          message,
          mimeType: stagedMimeType(file),
        ),
      );
      // Null is the user cancelling the dialog, which is not an outcome worth
      // reporting back to them.
      if (path != null) _report(l10n.mediaSavedTo(path));
    } on Object catch (error) {
      debugPrint('weft: saving ${message.eventId} failed: $error');
      _report(l10n.mediaSaveFailed);
    }
  }

  Future<void> _share(Rect? origin) async {
    final l10n = context.l10n;
    final message = _current;
    final file = await _stage(message);
    if (file == null || !mounted) return;

    try {
      await ref
          .read(mediaExporterProvider)
          .share(file, mimeType: stagedMimeType(file), origin: origin);
    } on Object catch (error) {
      debugPrint('weft: sharing ${message.eventId} failed: $error');
      _report(l10n.mediaShareFailed);
    }
  }

  void _report(String message) {
    if (!mounted) return;
    // Save and Share report themselves *only* here, and a bare `SnackBar` sets
    // no live region and is gone in four seconds — so "Could not save this
    // file" reached a reader who happened to be elsewhere in the tree as
    // silence, and then as nothing to navigate back to.
    showWeftMessage(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final message = _current;
    final caption = attachmentCaption(message);
    final exporter = ref.watch(mediaExporterProvider);
    final busy = _fetching.containsKey(message.eventId);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: WeftAppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        elevation: 0,
        foregroundColor: Colors.white,
        title: _ViewerTitle(message: message),
        actions: [
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  // A live region, because this spinner is the only sign that
                  // Save is waiting on a download rather than ignoring the tap.
                  child: Semantics(
                    liveRegion: true,
                    label: context.l10n.mediaDownloadingLabel,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (exporter.canSave)
            IconButton(
              tooltip: context.l10n.commonSave,
              icon: const Icon(Icons.download_rounded),
              onPressed: _save,
            ),
          // `Builder` so the rect below is the button's own, not the Scaffold's:
          // it anchors the share popover on iPad and macOS, and the whole-screen
          // rect puts it in the middle with nothing to point at.
          Builder(
            builder: (context) => IconButton(
              tooltip: context.l10n.commonShare,
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => _share(_originOf(context)),
            ),
          ),
          const SizedBox(width: WeftSpace.xs),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.items.length,
            // Nothing is fetched for a page until it is the page: a
            // conversation with eighty photos in it would otherwise start
            // pulling neighbours the moment the viewer opened.
            onPageChanged: (index) {
              setState(() => _index = index);
              // A swipe replaces the whole screen and says nothing. Position
              // first, because "4 of 9" is the fact a swipe is asking about;
              // the app bar's title node carries who and when for anyone who
              // navigates up to it.
              announce(
                context,
                semanticsSentence([
                  context.l10n.mediaPosition(index + 1, widget.items.length),
                  mediaLabel(context.l10n, widget.items[index]),
                ]),
              );
              unawaited(_stage(widget.items[index]));
            },
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return _MediaPage(
                message: item,
                file: _staged[item.eventId],
                failure: _failures[item.eventId],
              );
            },
          ),
          if (caption != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // Excluded rather than labelled: the caption is already the tail
              // of the picture's own label, and a second node over the photo
              // saying the same words is the duplicate this replaces.
              child: ExcludeSemantics(child: _CaptionBar(caption: caption)),
            ),
        ],
      ),
    );
  }

  /// The global rect of [context]'s box, or null before it has been laid out.
  static Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// What this item is, for a reader who cannot see it.
///
/// Kind, sender and caption in that order: on a black screen holding one
/// picture, "Photo" is the first thing there is to say and the caption is the
/// only thing that describes *this* photo rather than any photo.
String mediaLabel(AppL10n l10n, WeftMessage message) => semanticsSentence([
  l10n.messageKind(message.kind),
  message.isOwn ? l10n.mediaFromYou : l10n.mediaFromSender(message.senderName),
  attachmentCaption(message),
]);

/// Who sent it and when, in the app bar.
class _ViewerTitle extends StatelessWidget {
  const _ViewerTitle({required this.message});

  final WeftMessage message;

  @override
  Widget build(BuildContext context) {
    // One node: a name and a date read as two nodes are two stops on the way
    // out of the app bar, and neither half is useful without the other.
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message.isOwn ? context.l10n.commonYou : message.senderName,
            style: context.text.titleSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            DateFormat.yMMMd().add_Hm().format(message.timestamp),
            style: context.text.labelSmall?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

/// The caption, over the picture rather than beside it.
///
/// A scrim behind it because a caption is white text and the thing under it is
/// whatever the sender photographed — over a snow scene, unscrimmed text is
/// simply gone.
class _CaptionBar extends StatelessWidget {
  const _CaptionBar({required this.caption});

  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Text(
          caption,
          style: context.text.bodyMedium?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// One item, full screen.
///
/// The thumbnail is loaded here and the full file is handed down from the
/// viewer, which is what makes the hero land on a picture instead of on a
/// spinner: the bubble's own bytes are already decoded, so the flight ends on
/// something recognisable and the original replaces it a moment later.
class _MediaPage extends ConsumerStatefulWidget {
  const _MediaPage({required this.message, this.file, this.failure});

  final WeftMessage message;

  /// The staged original, once it is on disk.
  final File? file;

  /// Why there will never be one.
  final String? failure;

  @override
  ConsumerState<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends ConsumerState<_MediaPage> {
  Uint8List? _preview;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  Future<void> _loadPreview() async {
    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(widget.message.roomId, widget.message.eventId);
    if (!mounted || bytes == null) return;
    setState(() => _preview = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final failure = widget.failure;
    final file = widget.file;

    if (failure != null) {
      // The picture the user tapped never arrives and the screen stays black.
      // A live region is the only thing that says why.
      return Semantics(
        liveRegion: true,
        child: _Message(icon: Icons.error_outline_rounded, text: failure),
      );
    }

    // Video only becomes playable once the whole file is down, so until then the
    // page is the poster with the badge the bubble drew — the same picture, in
    // the same place, which is what the hero flight promised.
    if (message.kind == MessageKind.video && file != null) {
      return ref.watch(videoSurfaceProvider)(context, file);
    }

    // A PDF gets read in place instead of a filename on a black screen.
    final looksLikePdf =
        message.body.toLowerCase().endsWith('.pdf') ||
        (file != null && stagedMimeType(file) == 'application/pdf');
    if (looksLikePdf) {
      if (file == null) {
        return Center(
          child: Semantics(
            label: context.l10n.mediaDocumentLoading,
            child: const CircularProgressIndicator(color: Colors.white),
          ),
        );
      }
      return PdfViewer.file(
        file.path,
        params: const PdfViewerParams(backgroundColor: Colors.black),
      );
    }

    if (!kViewableMediaKinds.contains(message.kind)) {
      return _Message(
        icon: Icons.insert_drive_file_rounded,
        text: message.body.isEmpty
            ? context.l10n.messageKindFile
            : message.body,
        detail: message.mediaSizeBytes == null
            ? null
            : context.l10n.fileSize(message.mediaSizeBytes!),
      );
    }

    final image = file != null
        ? Image.file(file, fit: BoxFit.contain)
        : _preview != null
        ? Image.memory(_preview!, fit: BoxFit.contain)
        : null;

    if (image == null) {
      return Center(
        child: Semantics(
          label: context.l10n.mediaKindLoading(
            context.l10n.messageKind(message.kind),
          ),
          child: const CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Semantics(
      image: true,
      container: true,
      // The caption is drawn as an overlay by the viewer above; it belongs to
      // this picture, so it is said as part of it rather than as a second node
      // floating over a picture that had nothing to say for itself.
      label: mediaLabel(context.l10n, message),
      child: Hero(
        tag: mediaHeroTag(message),
        child: InteractiveViewer(
          // Panning is only meaningful once zoomed, and `clipBehavior: none`
          // would let a dragged photo spill over the app bar.
          minScale: 1,
          maxScale: 5,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(child: image),
              // Still buffering the file: say the video is coming rather than
              // leaving a play badge that does nothing when tapped.
              if (message.kind == MessageKind.video)
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A centred glyph and a line of text, for the states with no picture.
class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.detail});

  final IconData icon;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.white70),
            const SizedBox(height: WeftSpace.md),
            Text(
              text,
              textAlign: TextAlign.center,
              style: context.text.bodyLarge?.copyWith(color: Colors.white),
            ),
            if (detail != null) ...[
              const SizedBox(height: WeftSpace.xxs),
              Text(
                detail,
                style: context.text.bodySmall?.copyWith(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
