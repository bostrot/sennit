import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/intents.dart';
import '../../app/localisation.dart';
import '../../data/chat_repository.dart';
import '../../data/room_joiner.dart';

/// Opens the room a Matrix room link names, joining it first if need be.
///
/// A room the user is already in opens straight away — the link was only ever
/// a way to get there. A room they are not in asks before joining: joining is
/// visible to everyone in the room, so it is not something a tap on a link in
/// someone else's message should do on its own.
Future<void> openRoomLink(
  BuildContext context, {
  required ChatRepository repository,
  required OpenRoomLink link,
  required void Function(String chatId) open,
}) async {
  final joiner = repository is RoomJoiner ? repository as RoomJoiner : null;
  final existing = joiner != null
      ? joiner.chatForRoomLink(link.roomIdOrAlias)
      : repository.chatForRoom(link.roomIdOrAlias);
  if (existing != null) {
    open(existing.id);
    return;
  }
  if (joiner == null) {
    // Demo mode, or a browser on Sennit Web: no account here to join with.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.chatUnavailableNotInInbox)),
    );
    return;
  }

  final chatId = await showDialog<String>(
    context: context,
    builder: (context) => _JoinRoomDialog(joiner: joiner, link: link),
  );
  if (chatId != null) open(chatId);
}

class _JoinRoomDialog extends StatefulWidget {
  const _JoinRoomDialog({required this.joiner, required this.link});

  final RoomJoiner joiner;
  final OpenRoomLink link;

  @override
  State<_JoinRoomDialog> createState() => _JoinRoomDialogState();
}

class _JoinRoomDialogState extends State<_JoinRoomDialog> {
  bool _joining = false;
  bool _failed = false;

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _failed = false;
    });
    String? chatId;
    try {
      chatId = await widget.joiner.joinRoom(
        widget.link.roomIdOrAlias,
        via: widget.link.via,
      );
    } on Object catch (error) {
      debugPrint('weft: joining ${widget.link.roomIdOrAlias} failed: $error');
    }
    if (!mounted) return;
    if (chatId == null) {
      // Stays open with the reason, so "Join" can be tried again without
      // finding the link a second time.
      setState(() {
        _joining = false;
        _failed = true;
      });
      return;
    }
    Navigator.of(context).pop(chatId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.roomLinkJoinTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            widget.link.roomIdOrAlias,
            style: context.text.titleSmall,
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(l10n.roomLinkJoinBody),
          if (_failed) ...[
            const SizedBox(height: WeftSpace.sm),
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.roomLinkJoinFailed,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.error,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _joining ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _joining ? null : _join,
          child: _joining
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.roomLinkJoin),
        ),
      ],
    );
  }
}
