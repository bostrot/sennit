import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';

import 'emoji_picker_sheet.dart';

/// What a long-press on a bubble can lead to.
enum MessageAction {
  reply,

  /// A key was chosen from the quick row; see [MessageActionChoice.emoji].
  react,

  /// The picker, rather than one of the six quick keys.
  moreReactions,

  edit,
  copy,

  /// Copy *part* of the message: opens the text in a selectable view.
  selectText,
  forward,
  delete,
  transcribe,
  retranscribe,

  /// Schedule a local notification pointing back at this message.
  remind,

  /// Fire the message at the user's Home Assistant as a `weft_message` event.
  sendToHomeAssistant,

  /// Change the time of a calendar proposal already sent. Everyone else sees
  /// it as an edit.
  editInvite,

  /// The versions of a message that has been edited.
  ///
  /// Here rather than only on the "edited" marker under the bubble. That marker
  /// is a 10dp italic run inside a metadata line — TAP-15, the smallest target
  /// in the app by a distance — and a line of running text cannot be grown to
  /// 48dp without pushing the bubble apart. So the affordance moved to where
  /// every other operation on a message already lives, which also makes it the
  /// first one reachable from a keyboard.
  editHistory,
}

/// The sheet's answer: what to do, and for [MessageAction.react], with what.
@immutable
class MessageActionChoice {
  const MessageActionChoice(this.action, {this.emoji});

  final MessageAction action;

  /// The reaction key, set only for [MessageAction.react].
  final String? emoji;

  @override
  String toString() =>
      'MessageActionChoice($action${emoji == null ? '' : ', $emoji'})';
}

/// The actions available on one message.
///
/// Composed from what the message *is* rather than from a fixed list: only the
/// sender can edit or delete, only a message with words can be copied, and the
/// voice actions are the ones this bubble already carried — `onTranscribe` and
/// `onRetranscribe` have been on the bubble since the transcription phase and
/// moving the rest of the actions into a sheet must not quietly lose them.
///
/// Edit and delete are offered only for [WeftMessage.isOwn]. The homeserver
/// will happily accept a replacement of someone else's event and every
/// well-behaved client will then ignore it, so an "edit" the reader could reach
/// on a peer's message would be a control that does nothing.
Future<MessageActionChoice?> showMessageActionsSheet(
  BuildContext context, {
  required WeftMessage message,
  bool canTranscribe = false,
  bool hasTranscript = false,
  bool homeAssistant = false,
}) {
  return showModalBottomSheet<MessageActionChoice>(
    context: context,
    showDragHandle: true,
    // Scroll-controlled so the sheet sizes to its actions. At the default cap
    // of nine sixteenths of the screen the last row — which is Delete — falls
    // off the bottom on a short device, and an action reachable only by a
    // scroll with nothing to suggest it is there is an action that is not
    // there.
    isScrollControlled: true,
    builder: (context) => _MessageActionsSheet(
      message: message,
      canTranscribe: canTranscribe,
      hasTranscript: hasTranscript,
      homeAssistant: homeAssistant,
    ),
  );
}

class _MessageActionsSheet extends StatelessWidget {
  const _MessageActionsSheet({
    required this.message,
    required this.canTranscribe,
    required this.hasTranscript,
    required this.homeAssistant,
  });

  final WeftMessage message;
  final bool canTranscribe;
  final bool hasTranscript;
  final bool homeAssistant;

  @override
  Widget build(BuildContext context) {
    void choose(MessageAction action, {String? emoji}) =>
        Navigator.of(context).pop(MessageActionChoice(action, emoji: emoji));

    // A redacted message has nothing left to react to, quote, edit or copy.
    // Everything below is gated on it rather than the sheet being suppressed,
    // because "delete" still has to be reachable for a local tidy-up.
    final live = !message.redacted;

    // The sheet says which message it acts on. Every row in it — Reply, Edit,
    // Delete — is a verb with no object, and the bubble it came from is behind
    // a modal barrier the reader cannot navigate back to.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticsSentence([
        'Actions for the message from',
        message.isOwn ? 'you' : message.senderName,
        message.redacted ? 'deleted' : replyPreviewText(message),
      ]),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (live) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WeftSpace.md,
                    vertical: WeftSpace.xs,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // A bare emoji `Text` inside an `InkWell` is not a button
                      // to a screen reader — it is a character, announced by
                      // whatever name the platform has for that glyph, with no
                      // hint that tapping it sends a reaction.
                      for (final key in kQuickReactions)
                        Semantics(
                          button: true,
                          label: 'React with $key',
                          excludeSemantics: true,
                          onTap: () => choose(MessageAction.react, emoji: key),
                          // A glyph plus 8dp of padding is 50dp tall and 27dp
                          // wide — tall enough and half as wide as it needs to
                          // be, in a row of six identical neighbours where the
                          // cost of missing is sending the wrong reaction.
                          child: WeftTapTarget(
                            child: InkWell(
                              onTap: () =>
                                  choose(MessageAction.react, emoji: key),
                              borderRadius: WeftRadius.pill,
                              child: Padding(
                                padding: const EdgeInsets.all(WeftSpace.sm),
                                child: Text(
                                  key,
                                  style: const TextStyle(fontSize: 24),
                                ),
                              ),
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: 'More reactions',
                        icon: const Icon(Icons.add_reaction_outlined),
                        onPressed: () => choose(MessageAction.moreReactions),
                      ),
                    ],
                  ),
                ),
                Divider(color: context.palette.divider, height: WeftSpace.lg),
                ListTile(
                  leading: const Icon(Icons.reply_rounded),
                  title: const Text('Reply'),
                  onTap: () => choose(MessageAction.reply),
                ),
                if (message.isOwn && message.kind == MessageKind.text)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Edit'),
                    onTap: () => choose(MessageAction.edit),
                  ),
                if (message.isOwn && message.calendarInvite != null)
                  ListTile(
                    leading: const Icon(Icons.edit_calendar_rounded),
                    title: const Text('Change the time'),
                    onTap: () => choose(MessageAction.editInvite),
                  ),
                if (message.body.trim().isNotEmpty) ...[
                  ListTile(
                    leading: const Icon(Icons.copy_rounded),
                    title: const Text('Copy text'),
                    onTap: () => choose(MessageAction.copy),
                  ),
                  ListTile(
                    leading: const Icon(Icons.text_fields_rounded),
                    title: const Text('Select text'),
                    onTap: () => choose(MessageAction.selectText),
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.forward_rounded),
                  title: const Text('Forward'),
                  onTap: () => choose(MessageAction.forward),
                ),
                ListTile(
                  leading: const Icon(Icons.alarm_add_rounded),
                  title: const Text('Remind me'),
                  onTap: () => choose(MessageAction.remind),
                ),
                if (homeAssistant)
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Send to Home Assistant'),
                    onTap: () => choose(MessageAction.sendToHomeAssistant),
                  ),
                if (message.editHistory.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('Edit history'),
                    onTap: () => choose(MessageAction.editHistory),
                  ),
                if (canTranscribe && !hasTranscript)
                  ListTile(
                    leading: const Icon(Icons.graphic_eq_rounded),
                    title: const Text('Transcribe'),
                    onTap: () => choose(MessageAction.transcribe),
                  ),
                if (canTranscribe && hasTranscript)
                  ListTile(
                    leading: const Icon(Icons.translate_rounded),
                    title: const Text('Re-transcribe in…'),
                    onTap: () => choose(MessageAction.retranscribe),
                  ),
              ],
              if (message.isOwn)
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: context.colors.error,
                  ),
                  title: Text(
                    'Delete',
                    style: TextStyle(color: context.colors.error),
                  ),
                  onTap: () => choose(MessageAction.delete),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirms a redaction.
///
/// A dialog rather than an undo toast: a redaction is sent to the homeserver
/// and reaches every other client in the room, so there is nothing to undo once
/// it has gone.
Future<bool> confirmRedaction(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this message?'),
      content: const Text(
        'It is removed for everyone in the conversation. This cannot be '
        'undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
