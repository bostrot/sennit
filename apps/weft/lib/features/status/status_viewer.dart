import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import '../../app/localisation.dart';

import '../../app/providers.dart';
import '../../services/attachments/media_store.dart';
import '../../services/attachments/video_surface.dart';
import '../../services/status/status_feed.dart';

/// Full-screen pager through one contact's statuses, newest first.
///
/// Tap the right half for the next one, the left half for the previous —
/// the grammar every story viewer shares.
class StatusViewer extends ConsumerStatefulWidget {
  const StatusViewer({super.key, required this.entry});

  final StatusEntry entry;

  @override
  ConsumerState<StatusViewer> createState() => _StatusViewerState();
}

class _StatusViewerState extends ConsumerState<StatusViewer> {
  late final PageController _pages = PageController();
  int _index = 0;
  Timer? _advance;

  /// How long an image or text status stays before the pager moves on.
  static const Duration _dwell = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _armAutoAdvance();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _pages.dispose();
    super.dispose();
  }

  /// Stories play themselves: an image holds for [_dwell] and moves on, a
  /// video advances when the clip ends (via [_onVideoFinished]) rather than
  /// on a clock that would cut it off mid-sentence.
  void _armAutoAdvance() {
    _advance?.cancel();
    final message = widget.entry.messages[_index];
    if (message.kind == MessageKind.video) return;
    _advance = Timer(_dwell, () {
      if (mounted) _step(1);
    });
  }

  void _onVideoFinished(int index) {
    if (mounted && index == _index) _step(1);
  }

  void _step(int direction) {
    _advance?.cancel();
    final next = _index + direction;
    if (next < 0 || next >= widget.entry.messages.length) {
      Navigator.of(context).pop();
      return;
    }
    _pages.animateToPage(
      next,
      duration: WeftMotion.fast,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.entry.messages;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final width = MediaQuery.sizeOf(context).width;
                  _step(details.globalPosition.dx > width / 2 ? 1 : -1);
                },
                child: PageView.builder(
                  controller: _pages,
                  onPageChanged: (index) {
                    setState(() => _index = index);
                    _armAutoAdvance();
                  },
                  itemCount: messages.length,
                  itemBuilder: (context, index) => _StatusPage(
                    message: messages[index],
                    onVideoFinished: () => _onVideoFinished(index),
                  ),
                ),
              ),
            ),
            // Progress dashes + who and when, over the content.
            Positioned(
              top: WeftSpace.sm,
              left: WeftSpace.md,
              right: WeftSpace.md,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < messages.length; i++)
                        Expanded(
                          child: Container(
                            height: 3,
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(
                              color: i <= _index
                                  ? Colors.white
                                  : Colors.white38,
                              borderRadius: WeftRadius.pill,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.statusViewerCaption(
                            widget.entry.senderName,
                            DateFormat.Hm().format(messages[_index].timestamp),
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.commonClose,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPage extends ConsumerStatefulWidget {
  const _StatusPage({required this.message, required this.onVideoFinished});

  final WeftMessage message;

  /// Tells the pager this page's clip has played to the end.
  final VoidCallback onVideoFinished;

  @override
  ConsumerState<_StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends ConsumerState<_StatusPage> {
  Uint8List? _bytes;
  File? _video;
  bool _failed = false;

  bool get _isVideo => widget.message.kind == MessageKind.video;

  bool get _isMedia =>
      widget.message.kind == MessageKind.image ||
      _isVideo ||
      widget.message.attachmentUrl != null;

  @override
  void initState() {
    super.initState();
    if (_isMedia) _load();
  }

  Future<void> _load() async {
    // A video is a file for the player, not bytes for an image decoder —
    // feeding it to Image.memory is exactly the "Invalid image data" that
    // used to sit where the story should play.
    if (_isVideo) {
      try {
        final file = await ref
            .read(mediaFileStoreProvider)
            .stage(
              widget.message,
              repository: ref.read(chatRepositoryProvider),
              shouldContinue: () async => mounted,
            );
        if (mounted) setState(() => _video = file);
      } on Object catch (error) {
        debugPrint('weft: status video failed: $error');
        if (mounted) setState(() => _failed = true);
      }
      return;
    }

    final bytes = await ref
        .read(chatRepositoryProvider)
        .attachmentBytes(widget.message.roomId, widget.message.eventId);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isMedia) {
      // A text status gets the coloured-card treatment it has on the network.
      return Container(
        color: const Color(0xFF075E54),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Text(
          widget.message.body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
      );
    }

    if (_failed) {
      return Center(
        child: Text(
          context.l10n.statusLoadFailed,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    if (_isVideo) {
      final video = _video;
      if (video == null) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
      return ref.watch(storyVideoSurfaceProvider)(
        context,
        video,
        widget.onVideoFinished,
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(child: Image.memory(bytes, fit: BoxFit.contain));
  }
}
