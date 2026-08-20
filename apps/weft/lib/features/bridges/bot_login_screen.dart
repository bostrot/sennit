import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/session_providers.dart';

/// Signs in to a bridge through its bot's management room.
///
/// Every mautrix bridge speaks a command language in its management DM —
/// `login`, `list-logins`, `cancel` — and answers in ordinary messages,
/// including the QR code as an image. This screen is that conversation with
/// the ceremony stripped away: the bot's answers are shown as instructions,
/// a QR arrives full-size, and the reply box is labelled as the place to
/// answer prompts. No provisioning URL required, which is the point — the
/// management room is the one interface every bridge is guaranteed to have.
class BridgeBotLoginScreen extends ConsumerStatefulWidget {
  const BridgeBotLoginScreen({
    super.key,
    required this.botUserId,
    required this.network,
  });

  final String botUserId;
  final ChatNetwork network;

  @override
  ConsumerState<BridgeBotLoginScreen> createState() =>
      _BridgeBotLoginScreenState();
}

class _BridgeBotLoginScreenState extends ConsumerState<BridgeBotLoginScreen> {
  sdk.Room? _room;
  sdk.Timeline? _timeline;
  String? _error;
  bool _sending = false;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final client = ref.read(matrixSessionProvider).client;
    try {
      final roomId = await client.startDirectChat(widget.botUserId);
      var room = client.getRoomById(roomId);
      // A freshly created DM may not have landed in the local store yet.
      for (var i = 0; i < 20 && room == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        room = client.getRoomById(roomId);
      }
      if (room == null) {
        throw Exception('The chat with ${widget.botUserId} did not open.');
      }
      final timeline = await room.getTimeline(
        onUpdate: () {
          if (mounted) setState(() {});
        },
      );
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      setState(() {
        _room = room;
        _timeline = timeline;
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _timeline?.cancelSubscriptions();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send(String command) async {
    final room = _room;
    final text = command.trim();
    if (room == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await room.sendTextEvent(text);
      _input.clear();
    } on Exception catch (e) {
      if (mounted) showWeftMessage(context, 'Could not send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The visible conversation, oldest first, bot and user messages only.
  List<sdk.Event> get _messages {
    final timeline = _timeline;
    if (timeline == null) return const [];
    return timeline.events
        .where(
          (e) =>
              e.type == sdk.EventTypes.Message &&
              !e.redacted &&
              (e.messageType == sdk.MessageTypes.Text ||
                  e.messageType == sdk.MessageTypes.Notice ||
                  e.messageType == sdk.MessageTypes.Image),
        )
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  /// Whether the newest bot message reads like a completed login.
  bool get _looksSignedIn {
    final last = _messages.lastOrNull;
    if (last == null || last.senderId != widget.botUserId) return false;
    return RegExp(
      r'successfully logged in|logged in as|login successful',
      caseSensitive: false,
    ).hasMatch(last.body);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final messages = _messages;

    return Scaffold(
      appBar: AppBar(title: Text('Sign in to ${widget.network.label}')),
      body: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(WeftSpace.xl),
                child: Text(error, textAlign: TextAlign.center),
              ),
            )
          : _room == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_looksSignedIn)
                  Container(
                    margin: const EdgeInsets.all(WeftSpace.md),
                    padding: const EdgeInsets.all(WeftSpace.md),
                    decoration: BoxDecoration(
                      color: context.palette.online.withValues(alpha: 0.15),
                      borderRadius: WeftRadius.allMd,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          color: context.palette.online,
                        ),
                        const SizedBox(width: WeftSpace.sm),
                        const Expanded(
                          child: Text(
                            'Signed in. The bridge is syncing your chats — '
                            'they will appear in the inbox as they arrive.',
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(WeftSpace.xl),
                            child: Text(
                              'This is the bridge\'s management chat. '
                              'Start sign-in below — the bridge will answer '
                              'here with its own instructions.',
                              textAlign: TextAlign.center,
                              style: context.text.bodyMedium?.copyWith(
                                color: context.colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.all(WeftSpace.lg),
                          itemCount: messages.length,
                          itemBuilder: (context, index) => _MessageCard(
                            event: messages[messages.length - 1 - index],
                            fromBot:
                                messages[messages.length - 1 - index]
                                    .senderId ==
                                widget.botUserId,
                          ),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(WeftSpace.md),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The commands someone actually needs, one tap each.
                        // Everything else the bot lists under `help`.
                        Wrap(
                          spacing: WeftSpace.sm,
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.login_rounded, size: 16),
                              label: const Text('Start sign-in'),
                              onPressed: _sending ? null : () => _send('login'),
                            ),
                            ActionChip(
                              label: const Text('My logins'),
                              onPressed: _sending
                                  ? null
                                  : () => _send('list-logins'),
                            ),
                            ActionChip(
                              label: const Text('Cancel action'),
                              onPressed: _sending
                                  ? null
                                  : () => _send('cancel'),
                            ),
                            ActionChip(
                              label: const Text('Help'),
                              onPressed: _sending ? null : () => _send('help'),
                            ),
                          ],
                        ),
                        const SizedBox(height: WeftSpace.sm),
                        Row(
                          children: [
                            Expanded(
                              child: WeftLabelledField(
                                label: 'Answer the bridge',
                                child: TextField(
                                  controller: _input,
                                  autocorrect: false,
                                  onSubmitted: _send,
                                  decoration: const InputDecoration(
                                    hintText:
                                        'Type an answer or command — e.g. a '
                                        'phone number, or "login qr"',
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: WeftSpace.sm),
                            IconButton.filled(
                              onPressed: _sending
                                  ? null
                                  : () => _send(_input.text),
                              icon: const Icon(Icons.send_rounded, size: 18),
                              tooltip: 'Send',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// One message in the flow: the bot's instructions, or the user's answer.
///
/// A bot image is almost always the QR code, so it renders big enough to scan
/// from another phone without pinching.
class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.event, required this.fromBot});

  final sdk.Event event;
  final bool fromBot;

  @override
  Widget build(BuildContext context) {
    final isImage = event.messageType == sdk.MessageTypes.Image;

    return Align(
      alignment: fromBot
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.only(bottom: WeftSpace.md),
        padding: const EdgeInsets.all(WeftSpace.md),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: fromBot
              ? context.colors.surfaceContainerHigh
              : context.palette.ownBubble,
          borderRadius: WeftRadius.allMd,
        ),
        child: isImage
            ? _BotImage(event: event)
            : SelectableText(
                event.body,
                style: context.text.bodyMedium?.copyWith(
                  color: fromBot ? null : context.palette.ownBubbleText,
                ),
              ),
      ),
    );
  }
}

class _BotImage extends StatefulWidget {
  const _BotImage({required this.event});

  final sdk.Event event;

  @override
  State<_BotImage> createState() => _BotImageState();
}

class _BotImageState extends State<_BotImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      if (mounted) setState(() => _bytes = Uint8List.fromList(file.bytes));
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (_failed) return const Text('The image could not be loaded.');
    if (bytes == null) {
      return const SizedBox(
        width: 260,
        height: 260,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Semantics(
      image: true,
      label:
          'Code from the bridge — usually the QR to scan with the phone that '
          'has the account',
      child: ClipRRect(
        borderRadius: WeftRadius.allSm,
        // White padding behind it: a QR on a dark theme's surface loses its
        // quiet zone and some scanners refuse it.
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(WeftSpace.md),
          child: Image.memory(bytes, width: 260, height: 260),
        ),
      ),
    );
  }
}
