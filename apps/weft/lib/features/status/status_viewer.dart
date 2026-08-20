import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/providers.dart';
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

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _step(int direction) {
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
                  onPageChanged: (index) => setState(() => _index = index),
                  itemCount: messages.length,
                  itemBuilder: (context, index) =>
                      _StatusPage(message: messages[index]),
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
                          '${widget.entry.senderName} · '
                          '${DateFormat.Hm().format(messages[_index].timestamp)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
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
  const _StatusPage({required this.message});

  final WeftMessage message;

  @override
  ConsumerState<_StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends ConsumerState<_StatusPage> {
  Uint8List? _bytes;
  bool _failed = false;

  bool get _isMedia =>
      widget.message.kind == MessageKind.image ||
      widget.message.kind == MessageKind.video ||
      widget.message.attachmentUrl != null;

  @override
  void initState() {
    super.initState();
    if (_isMedia) _load();
  }

  Future<void> _load() async {
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

    final bytes = _bytes;
    if (_failed) {
      return const Center(
        child: Text(
          'This status could not be loaded.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    if (bytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(child: Image.memory(bytes, fit: BoxFit.contain));
  }
}
