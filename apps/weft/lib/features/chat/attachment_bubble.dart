/// The contents of a bubble that carries a file.
///
/// Split out of `chat_view.dart` because "what a photo looks like" and "what a
/// PDF looks like" are different enough to be worth naming, and because the
/// upload bubble has to render the *same* shapes before there is an event to
/// fetch bytes for. Every colour, radius and gap here comes from `weft_design`:
/// a bubble that invents its own padding stops matching the ones above it the
/// first time the scale changes.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft_richtext/weft_richtext.dart';

import '../../app/a11y.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../services/attachments/attachment_byte_cache.dart';
import '../../services/audio/voice_player.dart';
import 'rich_text_view.dart';

/// The hero tag joining a bubble's thumbnail to its full-screen self.
///
/// Published here, where the flight starts, so the viewer has one place to read
/// it from and the two cannot drift into two different strings — a hero whose
/// ends disagree does not fail, it simply stops animating, which is the kind of
/// bug nobody files.
///
/// Keyed by room *and* event: a merged conversation draws messages from several
/// rooms at once, and two servers issuing the same event id — unlikely, but
/// nothing forbids it — would make Flutter throw on a duplicate tag.
String mediaHeroTag(WeftMessage message) =>
    'attachment:${message.roomId}/${message.eventId}';

/// Kinds that render as an attachment rather than as their `body` text.
///
/// [MessageKind.voice] is deliberately absent: a voice note has its own bubble
/// with a waveform, and it is a recording rather than a file the user chose.
const Set<MessageKind> kAttachmentKinds = {
  MessageKind.image,
  MessageKind.video,
  MessageKind.sticker,
  MessageKind.audio,
  MessageKind.file,
};

/// Whether [message] should draw an [AttachmentBubble].
///
/// The `attachmentUrl` check is what separates a real `m.file` event from a
/// text message that merely mentions one — `mapEvent` only sets it when the
/// event actually carries a `url` or a `file` block.
bool rendersAsAttachment(WeftMessage message) =>
    message.attachmentUrl != null && kAttachmentKinds.contains(message.kind);

/// The user's caption for an attachment, or null when there is nothing worth
/// showing under it.
///
/// Bridges label a forwarded picture "Forwarded", and a client that predates
/// MSC2530 captions puts the *filename* in `body` — so the naive reading shows
/// `IMG_4021.jpg` under a photo of a dog. Both are noise rather than captions.
/// Lifted out of the old inline heuristic so the file bubble, which shows the
/// name deliberately, does not have to re-derive the same rule backwards.
///
/// A sender who wrote [WeftMessage.attachmentName] said which key is which, and
/// is believed without further argument. Running the heuristic over a body that
/// has already been declared a caption can only lose: a one-word caption naming
/// a file — "screenshot.png", typed by a person, under a screenshot — would be
/// thrown away for looking like the thing the sender explicitly said it is not.
String? attachmentCaption(WeftMessage message) {
  final caption = message.body.trim();
  if (caption.isEmpty) return null;
  if (message.attachmentName != null) return caption;
  if (caption.toLowerCase() == 'forwarded') return null;
  // A body that is exactly the filename is a filename, not a caption. The same
  // rule the save path uses to decide whether that body is worth writing the
  // file under, so the two cannot disagree about what is a name.
  if (looksLikeFilename(caption)) return null;
  return caption;
}

/// What to call the file in a bubble that shows a name: a PDF, an archive, an
/// audio file, a contact card.
///
/// [WeftMessage.attachmentName] when the sender separated the two keys, and
/// [WeftMessage.body] otherwise — which is the same fallback every client that
/// predates MSC2530 makes, and correct there because without a caption `body`
/// *is* the name. Empty when there is neither, which the callers word for
/// themselves rather than being handed an invented placeholder to render.
String attachmentFilename(WeftMessage message) =>
    message.attachmentName ?? message.body;

/// Playback length as `m:ss`, or null when the sender never announced one.
String? formatMediaDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final total = Duration(milliseconds: milliseconds);
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The body of a bubble carrying an attachment.
///
/// Dispatches on [WeftMessage.kind] rather than on the mime type: the mapping
/// from `m.image`/`m.video`/`m.audio`/`m.file` to a kind already happened in
/// `weft_matrix`, and re-deciding it here is how the two drift apart.
class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    super.key,
    required this.message,
    required this.own,
    this.onOpen,
    this.transcribing = false,
    this.onTranscribe,
    this.onRetranscribe,
    this.accent,
    this.onTapLink,
    this.onTapMention,
  });

  final WeftMessage message;

  /// Own messages sit on a different bubble colour, so everything drawn on top
  /// of them needs the matching foreground.
  final bool own;

  /// Opens the full-screen viewer. Null until it exists, which is why the
  /// bubble is tappable only when there is somewhere to go.
  final VoidCallback? onOpen;

  final bool transcribing;
  final VoidCallback? onTranscribe;
  final VoidCallback? onRetranscribe;

  /// Link and mention colour for a caption, matching the text bubble's. Null
  /// falls back to the bubble's own foreground, which is what an own bubble
  /// uses anyway.
  final Color? accent;

  /// The same handlers the text bubble passes to [RichTextView]. A caption is
  /// message text that happens to sit under a picture: a link in one has to open
  /// the same way a link in the other does, and a mention of the reader has to
  /// resolve to the same person.
  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

  @override
  Widget build(BuildContext context) {
    return switch (message.kind) {
      MessageKind.image ||
      MessageKind.video ||
      MessageKind.sticker => MediaAttachment(
        message: message,
        own: own,
        onOpen: onOpen,
        accent: accent,
        onTapLink: onTapLink,
        onTapMention: onTapMention,
      ),
      MessageKind.audio => _AudioAttachment(
        message: message,
        own: own,
        transcribing: transcribing,
        onTranscribe: onTranscribe,
        onRetranscribe: onRetranscribe,
        accent: accent,
        onTapLink: onTapLink,
        onTapMention: onTapMention,
      ),
      _ when _isContactCard(message) => _ContactAttachment(
        message: message,
        own: own,
        onOpen: onOpen,
      ),
      _ => _FileAttachment(
        message: message,
        own: own,
        onOpen: onOpen,
        accent: accent,
        onTapLink: onTapLink,
        onTapMention: onTapMention,
      ),
    };
  }

  /// A vCard riding as a file — how every bridge relays "shared a contact".
  ///
  /// Reads the *name*, not the body: a captioned vCard puts the sender's words
  /// in `body`, and a caption that happened to end in ".vcf" would otherwise
  /// decide the bubble's whole shape.
  static bool _isContactCard(WeftMessage message) {
    final name = attachmentFilename(message).toLowerCase();
    return name.endsWith('.vcf') || name.endsWith('.vcard');
  }
}

/// A shared contact: WhatsApp and friends send these as .vcf files, and a
/// bubble reading "IMG_0001.vcf · 1.2 KB" buried what it was. Opening hands
/// the card to the OS, whose contacts app owns the import.
class _ContactAttachment extends StatelessWidget {
  const _ContactAttachment({
    required this.message,
    required this.own,
    this.onOpen,
  });

  final WeftMessage message;
  final bool own;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    // "Anna Maven.vcf" → "Anna Maven".
    final name = attachmentFilename(
      message,
    ).replaceFirst(RegExp(r'\.(vcf|vcard)$', caseSensitive: false), '');

    return WeftFocusable(
      button: onOpen != null,
      onTap: onOpen,
      label: semanticsSentence([
        context.l10n.attachmentContactCard,
        name,
        if (onOpen != null) context.l10n.attachmentContactOpensToSave,
      ]),
      borderRadius: WeftRadius.allSm,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: onBubble.withValues(alpha: 0.15),
            child: Icon(Icons.person_rounded, color: onBubble),
          ),
          const SizedBox(width: WeftSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.isEmpty
                    ? context.l10n.attachmentContactFallbackName
                    : name,
                style: context.text.bodyMedium?.copyWith(
                  color: onBubble,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                context.l10n.attachmentContactSubtitle,
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

/// An image, video poster or sticker, loaded through the repository so an
/// encrypted attachment is decrypted locally before display.
///
/// Without this an image message rendered as its `body` — often just the
/// filename, or "Forwarded" for a forwarded picture — which looked like the
/// picture had been lost.
class MediaAttachment extends ConsumerStatefulWidget {
  const MediaAttachment({
    super.key,
    required this.message,
    this.own = true,
    this.onOpen,
    this.accent,
    this.onTapLink,
    this.onTapMention,
  });

  final WeftMessage message;

  /// Which bubble fill the caption is read against. Defaults to the own bubble
  /// because the pre-send preview — the one caller that has no message yet — is
  /// always drawing the user's own photo.
  final bool own;

  final VoidCallback? onOpen;
  final Color? accent;
  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

  @override
  ConsumerState<MediaAttachment> createState() => _MediaAttachmentState();
}

class _MediaAttachmentState extends ConsumerState<MediaAttachment> {
  Uint8List? _bytes;
  bool _failed = false;

  String get _cacheKey =>
      AttachmentByteCache.keyFor(widget.message.roomId, widget.message.eventId);

  @override
  void initState() {
    super.initState();
    // Synchronous cache hit first: a row scrolling back into view must get its
    // pixels in the same frame it is built, or the timeline reflows under the
    // reader's thumb — which is what "scrolling back down keeps jumping" was.
    final cached = ref.read(attachmentByteCacheProvider).get(_cacheKey);
    if (cached != null) {
      _bytes = cached;
    } else {
      _loadWhenSettled();
    }
  }

  /// Starts the download once the list has stopped flinging past this row.
  ///
  /// A fling through history builds every row it crosses for a frame or two,
  /// and each one used to start fetching — and, in an encrypted room,
  /// decrypting — its full original on the spot, for a picture that was
  /// gone before it arrived. The same rule `Image` applies to its own
  /// decoding: while the scrollable says loading should wait, wait a frame
  /// and ask again.
  void _loadWhenSettled() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Scrollable.recommendDeferredLoadingForContext(context)) {
        SchedulerBinding.instance.scheduleFrame();
        _loadWhenSettled();
        return;
      }
      _load();
    });
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
    final caption = attachmentCaption(widget.message);
    final isVideo = widget.message.kind == MessageKind.video;
    final isSticker = widget.message.kind == MessageKind.sticker;

    // One node for the whole picture: what it is, what the sender wrote under
    // it, and whether there is anything there yet. A photo previously announced
    // *nothing at all* — an `Image.memory` under a bare `GestureDetector` has
    // no semantics of its own — and the caption was a second, unattached node.
    return WeftFocusable(
      image: true,
      button: _bytes != null && widget.onOpen != null,
      onTap: _bytes == null ? null : widget.onOpen,
      label: semanticsSentence([
        context.l10n.messageKind(widget.message.kind),
        caption,
        if (_failed)
          context.l10n.attachmentCouldNotLoad
        else if (_bytes == null)
          context.l10n.attachmentLoading,
      ]),
      borderRadius: WeftRadius.allSm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: WeftRadius.allSm,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320, minWidth: 140),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // The flight the viewer lands: the same decoded bytes on both
                  // ends, so the picture the user tapped is visibly the picture
                  // that fills the screen. Only wrapped once there *are* bytes —
                  // a hero whose source is a grey placeholder animates a grey
                  // box into a photo, which reads as a glitch.
                  //
                  // No tap of its own any more: the focusable above owns it, and
                  // a second recogniser on the same pixels was only ever a
                  // duplicate of the one the keyboard also has to be able to
                  // reach.
                  switch ((_bytes, _failed)) {
                    (final Uint8List bytes, _) => Hero(
                      tag: mediaHeroTag(widget.message),
                      // Exactly the placeholder's box, so the swap from grey to
                      // pixels changes *nothing* about layout. Any difference
                      // here reflows every row below it — in a reversed list,
                      // that is a shove against the direction the reader is
                      // scrolling. `cacheWidth` bounds the decode to what the
                      // box can show; a 12-megapixel original decoded in full
                      // on the UI thread was most of the remaining jank.
                      child: SizedBox(
                        width: _boxWidth,
                        height: _boxHeight,
                        child: Image.memory(
                          bytes,
                          // A photo fills its box; a sticker is a transparent
                          // cutout and has to fit inside one. Cropping a photo
                          // to the bubble's shape is the intended look, but
                          // doing it to a sticker slices the parrot's head off
                          // whenever the bridge sent no dimensions and the box
                          // fell back to a landscape default.
                          fit: isSticker ? BoxFit.contain : BoxFit.cover,
                          cacheWidth:
                              (_boxWidth *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          errorBuilder: (_, _, _) =>
                              _placeholder(context, broken: true),
                        ),
                      ),
                    ),
                    (_, true) => _placeholder(context, broken: true),
                    _ => _placeholder(context, broken: false),
                  },
                  // Over the picture rather than under it: a poster with a
                  // caption line reading "Video" is indistinguishable from a
                  // still at a glance, which is the one thing the badge exists to
                  // prevent.
                  if (isVideo) const PlayBadge(),
                ],
              ),
            ),
          ),
          AttachmentCaption(
            message: widget.message,
            own: widget.own,
            accent: widget.accent,
            onTapLink: widget.onTapLink,
            onTapMention: widget.onTapMention,
          ),
        ],
      ),
    );
  }

  /// One box for both states. The placeholder reserves it and the loaded
  /// image fills it, so the timeline's geometry is settled the moment the row
  /// is built and never changes again.
  static const double _boxWidth = 220;

  double get _boxHeight {
    final ratio = widget.message.mediaAspectRatio;
    return ratio == null ? 140.0 : (_boxWidth / ratio).clamp(90.0, 320.0);
  }

  /// Reserves the attachment's own shape while the bytes are still coming.
  ///
  /// [WeftMessage.mediaAspectRatio] is used when the sender announced one, so an
  /// encrypted photo does not lay out as a squat grey box and then reflow the
  /// whole timeline under the reader's thumb when it decodes.
  Widget _placeholder(BuildContext context, {required bool broken}) {
    // A video whose event carried no thumbnail has nothing to show and nothing
    // wrong with it: the sender's client simply did not make one, which is
    // ordinary on several bridges. A broken-image glyph says the opposite —
    // that something failed — so a poster says what is actually true. The
    // play control is drawn over this by the caller either way.
    //
    // A sticker is the same story for a different reason. The timeline declines
    // to fetch one whose file is not a picture — Telegram's animated stickers
    // are WebM wearing an `m.sticker` msgtype, see [attachmentServesAsThumbnail]
    // — and a decline is not a failure. Refusing the file and *then* drawing the
    // broken-image glyph over it would leave the timeline looking exactly as
    // broken as it did before any of this was fixed.
    final isVideo = widget.message.kind == MessageKind.video;
    final isSticker = widget.message.kind == MessageKind.sticker;
    final missingByDesign = broken && (isVideo || isSticker);

    return Container(
      width: _boxWidth,
      height: _boxHeight,
      color: missingByDesign
          ? context.colors.surfaceContainerHigh
          : context.colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: switch ((broken, missingByDesign, isVideo)) {
        // Nothing at all: the caller draws a play control over this, dead
        // centre, and a film glyph behind it is two symbols stacked on the
        // same pixels saying the same thing.
        (_, true, true) => const SizedBox.shrink(),
        // A sticker gets no badge drawn over it, so the same empty box would be
        // a mystery rather than a restraint. Its own glyph names what is
        // missing without claiming the fetch went wrong.
        (_, true, false) => Icon(
          Icons.emoji_emotions_outlined,
          color: context.colors.onSurfaceVariant,
        ),
        (true, _, _) => Icon(
          Icons.broken_image_outlined,
          color: context.colors.onSurfaceVariant,
        ),
        _ => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      },
    );
  }
}

/// The sender's words under an attachment, or nothing when they wrote none.
///
/// Rendered through [RichTextView], not as a bare `Text`, and that is the point
/// of the widget rather than a detail of it. A caption **is** message text: it
/// carries the sender's `formatted_body` when they wrote one, and a link or a
/// mention inside it has to behave exactly as it would three bubbles up. Drawn
/// as plain text it showed the markup source — `**at the beach**`, asterisks and
/// all — and a mention pill arrived as a bare user id.
///
/// Shared by all three attachment shapes because a caption on a PDF is the same
/// thing as a caption on a photo, and the version that existed only under
/// pictures meant a captioned file bubble simply lost the sentence.
class AttachmentCaption extends StatelessWidget {
  const AttachmentCaption({
    super.key,
    required this.message,
    required this.own,
    this.accent,
    this.onTapLink,
    this.onTapMention,
  });

  final WeftMessage message;
  final bool own;
  final Color? accent;
  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

  @override
  Widget build(BuildContext context) {
    // Gated on `attachmentCaption`, not on a non-empty body: for an attachment
    // with no MSC2530 `filename` the body is the *name*, and rendering it here
    // prints `IMG_4021.jpg` under the photo it names.
    if (attachmentCaption(message) == null) return const SizedBox.shrink();

    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;

    // Excluded because every caller already folds the caption into one sentence
    // about the whole attachment — "Photo, at the beach". Without this a reader
    // hears the words twice, once in that sentence and once on their own.
    return Padding(
      padding: const EdgeInsets.only(top: WeftSpace.xs),
      child: ExcludeSemantics(
        child: RichTextView.message(
          message: message,
          baseStyle:
              context.text.bodyMedium?.copyWith(color: onBubble) ??
              TextStyle(color: onBubble),
          // Same rule as the text bubble: an own-bubble link takes the bubble's
          // own ink, because the accent it is derived from is invisible against
          // the primary fill.
          accent: own ? onBubble : (accent ?? onBubble),
          onTapLink: onTapLink,
          onTapMention: onTapMention,
        ),
      ),
    );
  }
}

/// The play affordance on a video poster.
///
/// Its own scrim disc rather than a bare icon: a white glyph vanishes on a
/// bright frame and a dark one vanishes on a night shot.
class PlayBadge extends StatelessWidget {
  const PlayBadge({super.key, this.size = 48});

  /// The disc's diameter. The glyph inside keeps the same proportion, so a
  /// badge on a thumbnail is the bubble's badge made smaller, not a new one.
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.colors.scrim.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          size: size * 0.625,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// A sound file that is not a voice note: a song, a forwarded clip, an export.
///
/// Rendered as a file with a duration rather than as a waveform — the waveform
/// belongs to voice notes, where it says "someone spoke for this long". The
/// Transcribe action is carried over unchanged, because `canTranscribe` has
/// always covered [MessageKind.audio] and the only reason an audio attachment
/// never offered it is that it used to fall through to plain text.
class _AudioAttachment extends ConsumerWidget {
  const _AudioAttachment({
    required this.message,
    required this.own,
    required this.transcribing,
    this.onTranscribe,
    this.onRetranscribe,
    this.accent,
    this.onTapLink,
    this.onTapMention,
  });

  final WeftMessage message;
  final bool own;
  final bool transcribing;
  final VoidCallback? onTranscribe;
  final VoidCallback? onRetranscribe;
  final Color? accent;
  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

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
    final duration = formatMediaDuration(message.durationMs);
    final name = attachmentFilename(message);

    final playback = ref.watch(voicePlayerProvider);
    final isCurrent = playback.eventId == message.eventId;
    final playing = isCurrent && playback.playing;
    final loading = isCurrent && playback.loading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The button is its own 48dp semantics node; the name and duration
            // beside it stay a merged label. A label that is also the tap
            // target reads fine and fails every touch-target audit.
            Semantics(
              container: true,
              button: true,
              excludeSemantics: true,
              label: loading
                  ? context.l10n.attachmentAudioLoading
                  : playing
                  ? context.l10n.attachmentAudioPause
                  : context.l10n.attachmentAudioPlay,
              child: SizedBox(
                width: 48,
                height: 48,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2),
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
            const SizedBox(width: WeftSpace.sm),
            // "Audio, Interview take 2, 4:31" as one clause. The name and the
            // duration were two nodes and neither said what kind of thing this
            // is — the only signal was a music glyph.
            Flexible(
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label: semanticsSentence([
                  context.l10n.messageKindAudio,
                  name.isEmpty ? null : name,
                  attachmentCaption(message),
                  duration,
                  if (playing) context.l10n.attachmentPlaying,
                ]),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name.isEmpty ? context.l10n.messageKindAudio : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium?.copyWith(
                        color: onBubble,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (duration != null)
                      Text(
                        duration,
                        style: context.text.labelSmall?.copyWith(
                          color: palette.muted(onBubble, bubble, alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        AttachmentCaption(
          message: message,
          own: own,
          accent: accent,
          onTapLink: onTapLink,
          onTapMention: onTapMention,
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

/// Anything with no better rendering: a PDF, an archive, a spreadsheet.
class _FileAttachment extends StatelessWidget {
  const _FileAttachment({
    required this.message,
    required this.own,
    this.onOpen,
    this.accent,
    this.onTapLink,
    this.onTapMention,
  });

  final WeftMessage message;
  final bool own;
  final VoidCallback? onOpen;
  final Color? accent;
  final void Function(String url, String label)? onTapLink;
  final void Function(RichMention mention)? onTapMention;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bubble = own ? palette.ownBubble : palette.peerBubble;
    final bytes = message.mediaSizeBytes;
    final size = bytes == null ? null : formatAttachmentSize(bytes);
    final name = attachmentFilename(message);
    final caption = attachmentCaption(message);

    // The kind the glyph is picked from is stated in words. A reader was told
    // "report.pdf, 2.3 MB" and never that it was a PDF — which is the one thing
    // the icon exists to say, and the thing that decides whether the file is
    // worth opening.
    // The row is the tap target and the caption is not: a link inside a caption
    // has its own recogniser, and a wrapping `InkWell` would swallow the tap
    // before the span ever saw it — opening the file instead of the link.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: onOpen != null,
          excludeSemantics: true,
          onTap: onOpen,
          label: semanticsSentence([
            _kindLabelFor(context.l10n, name),
            name.isEmpty ? context.l10n.messageKindFile : name,
            size,
            caption,
          ]),
          child: InkWell(
            onTap: onOpen,
            borderRadius: WeftRadius.allSm,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AttachmentGlyph(
                  icon: _iconFor(name),
                  tint: onBubble,
                  bubble: bubble,
                ),
                const SizedBox(width: WeftSpace.sm),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name.isEmpty ? context.l10n.messageKindFile : name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(
                          color: onBubble,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // No size line at all when the sender omitted
                      // `info.size`: an invented "0 B" reads as a broken file
                      // rather than as a missing field.
                      if (size != null)
                        Text(
                          size,
                          style: context.text.labelSmall?.copyWith(
                            color: palette.muted(onBubble, bubble, alpha: 0.7),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        AttachmentCaption(
          message: message,
          own: own,
          accent: accent,
          onTapLink: onTapLink,
          onTapMention: onTapMention,
        ),
      ],
    );
  }

  /// Extension-driven glyph. Deliberately coarse — a handful of families the
  /// user recognises at a glance beats a long table nobody reads.
  static IconData _iconFor(String filename) => switch (_extension(filename)) {
    'pdf' => Icons.picture_as_pdf_rounded,
    'zip' || 'gz' || 'tar' || '7z' || 'rar' => Icons.folder_zip_rounded,
    'doc' ||
    'docx' ||
    'odt' ||
    'rtf' ||
    'txt' ||
    'md' => Icons.description_rounded,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
    'apk' || 'exe' || 'dmg' || 'deb' => Icons.terminal_rounded,
    _ => Icons.insert_drive_file_rounded,
  };

  /// The same families [_iconFor] draws, in words.
  ///
  /// One switch would be tidier than two, but they answer different questions
  /// and only one of them has an honest fallback: an unrecognised extension
  /// gets a generic glyph, and saying "File" twice — once as the kind and once
  /// as the name — is noise, so it returns null and the sentence joiner drops
  /// it.
  static String? _kindLabelFor(AppL10n l10n, String filename) =>
      switch (_extension(filename)) {
        'pdf' => l10n.attachmentKindPdf,
        'zip' || 'gz' || 'tar' || '7z' || 'rar' => l10n.attachmentKindArchive,
        'doc' ||
        'docx' ||
        'odt' ||
        'rtf' ||
        'txt' ||
        'md' => l10n.attachmentKindDocument,
        'xls' || 'xlsx' || 'ods' || 'csv' => l10n.attachmentKindSpreadsheet,
        'ppt' || 'pptx' || 'odp' => l10n.attachmentKindPresentation,
        'apk' || 'exe' || 'dmg' || 'deb' => l10n.attachmentKindApplication,
        _ => null,
      };

  static String _extension(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }
}

/// A file bubble's leading icon on its own tinted disc.
class _AttachmentGlyph extends StatelessWidget {
  const _AttachmentGlyph({
    required this.icon,
    required this.tint,
    required this.bubble,
  });

  final IconData icon;
  final Color tint;

  /// The bubble fill behind the disc, so the glyph's contrast is measured
  /// against what is really under it.
  final Color bubble;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: WeftRadius.allSm,
      ),
      child: Icon(
        icon,
        size: 20,
        // Measured against the disc it sits on rather than the bubble behind
        // it — the 12% tint is what is actually under this glyph.
        color: WeftContrast.dim(
          tint,
          WeftContrast.flatten(tint.withValues(alpha: 0.12), bubble),
          alpha: 0.9,
          minRatio: WeftContrast.uiComponent,
        ),
      ),
    );
  }
}

/// The Transcribe affordance and, once there is one, the transcript.
///
/// Shared by the voice bubble and the audio attachment rather than written
/// twice: they offer the same action against the same `canTranscribe` rule, and
/// a copy would have drifted the moment either gained a state.
class AttachmentTranscript extends StatelessWidget {
  const AttachmentTranscript({
    super.key,
    required this.message,
    required this.own,
    required this.transcribing,
    this.onTranscribe,
    this.onRetranscribe,
  });

  final WeftMessage message;
  final bool own;
  final bool transcribing;
  final VoidCallback? onTranscribe;

  /// Long-press action on an existing transcript.
  final VoidCallback? onRetranscribe;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bubble = own ? palette.ownBubble : palette.peerBubble;
    // The transcript block lays an 8% tint over the bubble, so anything drawn
    // inside it is read against the tint, not against the bubble.
    final transcriptFill = WeftContrast.flatten(
      onBubble.withValues(alpha: 0.08),
      bubble,
    );
    final transcript = message.transcript;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (transcribing)
          Padding(
            padding: const EdgeInsets.only(top: WeftSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.muted(onBubble, bubble, alpha: 0.8),
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                Text(
                  context.l10n.attachmentTranscribing,
                  style: context.text.labelSmall?.copyWith(
                    color: palette.muted(onBubble, bubble, alpha: 0.8),
                  ),
                ),
              ],
            ),
          )
        else if (transcript == null && onTranscribe != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: onTranscribe,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              icon: Icon(
                Icons.graphic_eq_rounded,
                size: 14,
                color: palette.muted(onBubble, bubble, alpha: 0.8),
              ),
              label: Text(
                context.l10n.attachmentTranscribe,
                style: context.text.labelSmall?.copyWith(
                  color: palette.muted(onBubble, bubble, alpha: 0.8),
                ),
              ),
            ),
          ),
        if (transcript != null) ...[
          const SizedBox(height: WeftSpace.sm),
          // Re-transcribing is long-press only, and a long-press on a
          // `GestureDetector` with no semantics is an action that does not
          // exist for a screen reader — it is not on any menu and there is no
          // other way to reach it. Naming it on the node is what puts it in the
          // rotor.
          WeftFocusable(
            // Not a button: there is nothing a tap does here. It is a block of
            // text with one long-press action on it, so Tab lands on it and a
            // reader finds "transcribe again" in the rotor, but neither is
            // told it activates.
            button: false,
            label: context.l10n.attachmentTranscriptLabel(transcript),
            onLongPress: onRetranscribe,
            onLongPressHint: context.l10n.attachmentRetranscribeHint,
            borderRadius: WeftRadius.allSm,
            ringInset: 0,
            child: Container(
              padding: const EdgeInsets.all(WeftSpace.sm),
              decoration: BoxDecoration(
                // A tint, not ink — it is the background the transcript is
                // read against, so it stays exactly as faint as it was.
                color: onBubble.withValues(alpha: 0.08),
                borderRadius: WeftRadius.allSm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 13,
                    color: palette.muted(onBubble, transcriptFill, alpha: 0.7),
                  ),
                  const SizedBox(width: WeftSpace.xs),
                  // The one run of message text that does not go through
                  // `RichTextView`, so it states its own line break: without
                  // it a dragged selection welds the transcript onto the
                  // caption above it.
                  Flexible(
                    child: WeftSelectionLine(
                      child: Text(
                        transcript,
                        style: context.text.bodySmall?.copyWith(
                          color: palette.muted(
                            onBubble,
                            transcriptFill,
                            alpha: 0.9,
                          ),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// An attachment the user has picked but the homeserver has not accepted yet.
///
/// Drawn from the [UploadTask] rather than from a message because there is no
/// message: no event id, nothing to fetch bytes for, and a real chance the
/// whole thing fails. What it owes the user is the two facts a spinner cannot
/// give — *how far* this is, and *a way out* — so the bar is determinate and the
/// cancel button is present from the first frame rather than appearing once the
/// upload is far enough along to be worth abandoning.
class UploadProgressBubble extends StatelessWidget {
  const UploadProgressBubble({
    super.key,
    required this.task,
    required this.own,
    required this.onCancel,
    required this.onRetry,
  });

  final UploadTask task;
  final bool own;

  /// Abandons the upload. Also the way a failed one is dismissed: the task is
  /// already terminal, so there is nothing left to stop, only something to
  /// clear off the timeline.
  final VoidCallback onCancel;

  /// Tries again with a fresh attempt budget. Only offered when the queue says
  /// the task can actually be retried.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onBubble = own ? palette.ownBubbleText : palette.peerBubbleText;
    final bubble = own ? palette.ownBubble : palette.peerBubble;
    final failed = task.state == UploadState.failed;
    final plan = task.plan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AttachmentGlyph(
              icon: failed ? Icons.error_outline_rounded : _kindIcon(plan.kind),
              tint: failed ? context.colors.error : onBubble,
              bubble: bubble,
            ),
            const SizedBox(width: WeftSpace.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    plan.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(
                      color: onBubble,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // A live region only once the upload has settled. The status
                  // line changes on every progress tick, and a region that
                  // re-announced "31% of 12.4 MB" forty times would make the
                  // conversation unusable — but a failure that is never
                  // announced is a send the user believes went out.
                  Semantics(
                    liveRegion: task.state.isTerminal,
                    child: Text(
                      _statusLine(context, task),
                      style: context.text.labelSmall?.copyWith(
                        color: failed
                            ? context.colors.error
                            : palette.muted(onBubble, bubble, alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: WeftSpace.sm),
            IconButton(
              onPressed: onCancel,
              // No `VisualDensity.compact`: it takes 4dp off each axis of the
              // tap target Material otherwise pads this out to, leaving a 40dp
              // box — and the glyph is already held down to 18 by `iconSize`,
              // so the density was buying nothing the size did not.
              iconSize: 18,
              // Named, because a timeline can hold several uploads at once and
              // "Cancel upload" three times over is three identical buttons
              // with three different consequences.
              tooltip: failed
                  ? context.l10n.attachmentDiscardUpload(plan.filename)
                  : context.l10n.attachmentCancelUpload(plan.filename),
              icon: Icon(
                Icons.close_rounded,
                color: palette.muted(onBubble, bubble, alpha: 0.8),
              ),
            ),
          ],
        ),
        // Determinate on purpose. An indeterminate bar over an upload whose
        // byte count is known says less than nothing: it is the state a stalled
        // 200 MB video and a finished one look identical in.
        Padding(
          padding: const EdgeInsets.only(top: WeftSpace.xs),
          // A `LinearProgressIndicator` carries no semantics of its own, so the
          // determinate bar this widget went out of its way to draw said
          // nothing at all to a reader. `value` is the field a screen reader
          // reads for exactly this.
          child: Semantics(
            value: context.l10n.uploadPercent(
              (task.progress.clamp(0.0, 1.0) * 100).round(),
            ),
            child: ClipRRect(
              borderRadius: WeftRadius.pill,
              child: LinearProgressIndicator(
                value: task.progress.clamp(0.0, 1.0),
                minHeight: 4,
                // The unfilled track behind the bar, not a foreground.
                backgroundColor: onBubble.withValues(alpha: 0.15),
                color: failed ? context.colors.error : context.colors.primary,
              ),
            ),
          ),
        ),
        if (task.canRetry)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: Text(context.l10n.commonRetry),
            ),
          ),
      ],
    );
  }

  /// One line saying what is happening, in the user's terms.
  ///
  /// A percentage only while there is one to report: `hashing` is reading and
  /// encrypting the file, which can take a visible moment on a large video and
  /// during which "0%" would look like a stall.
  static String _statusLine(BuildContext context, UploadTask task) {
    final l10n = context.l10n;
    final size = formatAttachmentSize(task.plan.sizeBytes);
    return switch (task.state) {
      UploadState.queued => l10n.uploadWaiting(size),
      UploadState.hashing => l10n.uploadPreparing(size),
      UploadState.uploading => l10n.uploadProgress(
        l10n.uploadPercent((task.progress * 100).round()),
        size,
      ),
      UploadState.retrying => l10n.uploadRetrying(task.attempts + 1),
      UploadState.sent => l10n.uploadSending,
      UploadState.cancelled => l10n.uploadCancelled,
      UploadState.failed => task.failure ?? l10n.uploadFailed,
    };
  }

  static IconData _kindIcon(MessageKind kind) => switch (kind) {
    MessageKind.image || MessageKind.sticker => Icons.image_rounded,
    MessageKind.video => Icons.movie_rounded,
    MessageKind.audio || MessageKind.voice => Icons.audiotrack_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}
