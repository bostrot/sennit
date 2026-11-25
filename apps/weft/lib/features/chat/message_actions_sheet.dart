import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_richtext/weft_richtext.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';

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

  /// Translate the message with the user's own AI model.
  translate,
  forward,
  delete,
  transcribe,
  retranscribe,

  /// Schedule a local notification pointing back at this message.
  remind,

  /// Re-attempt a send that failed.
  retrySend,

  /// Drop a failed local echo — it never reached the room.
  discardSend,

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
  List<String> quickReactions = kQuickReactions,
  bool canTranslate = false,
  SendFailure? sendFailure,
}) {
  return showWeftPanel<MessageActionChoice>(
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
      quickReactions: quickReactions,
      canTranslate: canTranslate,
      sendFailure: sendFailure,
    ),
  );
}

class _MessageActionsSheet extends StatelessWidget {
  const _MessageActionsSheet({
    required this.message,
    required this.canTranscribe,
    required this.hasTranscript,
    required this.homeAssistant,
    required this.quickReactions,
    required this.canTranslate,
    this.sendFailure,
  });

  final WeftMessage message;
  final bool canTranscribe;
  final bool hasTranscript;
  final bool homeAssistant;

  /// The quick row — see `quickReactionsWith`.
  final List<String> quickReactions;

  /// Whether the user has an AI model set up to translate with.
  final bool canTranslate;

  /// Why the message failed, said under Retry so the choice is an informed
  /// one.
  final SendFailure? sendFailure;

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
        message.isOwn
            ? context.l10n.messageActionsSemanticsOwn
            : context.l10n.messageActionsSemantics(message.senderName),
        message.redacted
            ? context.l10n.chatMessageDeleted
            : replyPreviewText(message),
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
                  // `Wrap`, not `Row`. An emoji is text and scales with the
                  // text scaler, so six of them plus the picker button are 116
                  // points too wide for a phone at 2.0× — and because this row
                  // is the *first* thing in the sheet, what got clipped was the
                  // picker button, which is the way to every emoji that is not
                  // one of the six. `spaceBetween` on a `Wrap` spreads a run
                  // exactly as the `Row` did, and starts a second run instead of
                  // painting over the edge.
                  // Full width: the `Column` this sits in centres and therefore
                  // shrink-wraps its children, and a shrink-wrapped `Wrap` has
                  // no free space for `spaceBetween` to distribute — the seven
                  // controls would bunch together in the middle instead of
                  // spreading across the sheet the way the `Row` spread them.
                  // Same trap as `requests_screen.dart` and `merge_screen.dart`.
                  child: SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: WeftSpace.xs,
                      children: [
                        // A bare emoji `Text` inside an `InkWell` is not a button
                        // to a screen reader — it is a character, announced by
                        // whatever name the platform has for that glyph, with no
                        // hint that tapping it sends a reaction.
                        for (final key in quickReactions)
                          Semantics(
                            button: true,
                            label: context.l10n.messageActionReactWith(key),
                            excludeSemantics: true,
                            onTap: () =>
                                choose(MessageAction.react, emoji: key),
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
                          tooltip: context.l10n.messageActionMoreReactions,
                          icon: const Icon(Icons.add_reaction_outlined),
                          onPressed: () => choose(MessageAction.moreReactions),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(color: context.palette.divider, height: WeftSpace.lg),
                if (message.isOwn &&
                    message.deliveryState == DeliveryState.failed) ...[
                  ListTile(
                    leading: const Icon(Icons.refresh_rounded),
                    title: Text(context.l10n.messageActionRetrySend),
                    subtitle: sendFailure == null
                        ? null
                        : Text(context.l10n.sendFailureReason(sendFailure!)),
                    onTap: () => choose(MessageAction.retrySend),
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.close_rounded,
                      color: context.colors.error,
                    ),
                    title: Text(
                      context.l10n.messageActionDiscardSend,
                      style: TextStyle(color: context.colors.error),
                    ),
                    onTap: () => choose(MessageAction.discardSend),
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.reply_rounded),
                  title: Text(context.l10n.messageActionReply),
                  onTap: () => choose(MessageAction.reply),
                ),
                if (message.isOwn && message.kind == MessageKind.text)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(context.l10n.messageActionEdit),
                    onTap: () => choose(MessageAction.edit),
                  ),
                if (message.isOwn && message.calendarInvite != null)
                  ListTile(
                    leading: const Icon(Icons.edit_calendar_rounded),
                    title: Text(context.l10n.messageActionEditInvite),
                    onTap: () => choose(MessageAction.editInvite),
                  ),
                if (message.body.trim().isNotEmpty) ...[
                  ListTile(
                    leading: const Icon(Icons.copy_rounded),
                    title: Text(context.l10n.messageActionCopy),
                    onTap: () => choose(MessageAction.copy),
                  ),
                  ListTile(
                    leading: const Icon(Icons.text_fields_rounded),
                    title: Text(context.l10n.messageActionSelectText),
                    onTap: () => choose(MessageAction.selectText),
                  ),
                  if (canTranslate)
                    ListTile(
                      leading: const Icon(Icons.g_translate_rounded),
                      title: Text(context.l10n.messageActionTranslate),
                      onTap: () => choose(MessageAction.translate),
                    ),
                ],
                ListTile(
                  leading: const Icon(Icons.forward_rounded),
                  title: Text(context.l10n.messageActionForward),
                  onTap: () => choose(MessageAction.forward),
                ),
                ListTile(
                  leading: const Icon(Icons.alarm_add_rounded),
                  title: Text(context.l10n.messageActionRemind),
                  onTap: () => choose(MessageAction.remind),
                ),
                if (homeAssistant)
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: Text(context.l10n.messageActionSendToHomeAssistant),
                    onTap: () => choose(MessageAction.sendToHomeAssistant),
                  ),
                if (message.editHistory.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: Text(context.l10n.editHistoryTitle),
                    onTap: () => choose(MessageAction.editHistory),
                  ),
                if (canTranscribe && !hasTranscript)
                  ListTile(
                    leading: const Icon(Icons.graphic_eq_rounded),
                    title: Text(context.l10n.attachmentTranscribe),
                    onTap: () => choose(MessageAction.transcribe),
                  ),
                if (canTranscribe && hasTranscript)
                  ListTile(
                    leading: const Icon(Icons.translate_rounded),
                    title: Text(context.l10n.messageActionRetranscribe),
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
                    context.l10n.commonDelete,
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

/// The same decisions as the sheet, shaped for a pointer: a context menu at
/// the cursor. Desktop's right-click and the hover cluster's "more" both
/// land here; the sheet stays for touch and for keyboard activation, where
/// there is no cursor position worth anchoring to.
Future<MessageActionChoice?> showDesktopMessageMenu(
  BuildContext context, {
  required Offset position,
  required WeftMessage message,
  bool canTranscribe = false,
  bool hasTranscript = false,
  bool homeAssistant = false,
  List<String> quickReactions = kQuickReactions,
  bool canTranslate = false,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final l10n = context.l10n;
  final live = !message.redacted;

  PopupMenuItem<MessageActionChoice> item(
    MessageAction action,
    IconData icon,
    String label, {
    Color? color,
  }) => PopupMenuItem(
    value: MessageActionChoice(action),
    height: MacMetrics.menuItemHeight,
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: WeftSpace.sm),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    ),
  );

  return showMenu<MessageActionChoice>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      if (live)
        PopupMenuItem<MessageActionChoice>(
          enabled: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final key in quickReactions)
                InkWell(
                  borderRadius: WeftRadius.pill,
                  onTap: () => Navigator.of(
                    context,
                  ).pop(MessageActionChoice(MessageAction.react, emoji: key)),
                  child: Padding(
                    padding: const EdgeInsets.all(WeftSpace.xs),
                    child: Text(key, style: const TextStyle(fontSize: 20)),
                  ),
                ),
            ],
          ),
        ),
      if (message.isOwn && message.deliveryState == DeliveryState.failed) ...[
        item(
          MessageAction.retrySend,
          Icons.refresh_rounded,
          l10n.messageActionRetrySend,
        ),
        item(
          MessageAction.discardSend,
          Icons.close_rounded,
          l10n.messageActionDiscardSend,
          color: Theme.of(context).colorScheme.error,
        ),
      ],
      if (live) ...[
        item(MessageAction.reply, Icons.reply_rounded, l10n.messageActionReply),
        if (message.isOwn && message.kind == MessageKind.text)
          item(MessageAction.edit, Icons.edit_outlined, l10n.messageActionEdit),
        if (message.isOwn && message.calendarInvite != null)
          item(
            MessageAction.editInvite,
            Icons.edit_calendar_rounded,
            l10n.messageActionEditInvite,
          ),
        if (message.body.trim().isNotEmpty) ...[
          item(MessageAction.copy, Icons.copy_rounded, l10n.messageActionCopy),
          item(
            MessageAction.selectText,
            Icons.text_fields_rounded,
            l10n.messageActionSelectText,
          ),
          if (canTranslate)
            item(
              MessageAction.translate,
              Icons.g_translate_rounded,
              l10n.messageActionTranslate,
            ),
        ],
        item(
          MessageAction.forward,
          Icons.forward_rounded,
          l10n.messageActionForward,
        ),
        item(
          MessageAction.remind,
          Icons.alarm_add_rounded,
          l10n.messageActionRemind,
        ),
        if (homeAssistant)
          item(
            MessageAction.sendToHomeAssistant,
            Icons.home_outlined,
            l10n.messageActionSendToHomeAssistant,
          ),
        if (message.editHistory.isNotEmpty)
          item(
            MessageAction.editHistory,
            Icons.history_rounded,
            l10n.editHistoryTitle,
          ),
        if (canTranscribe && !hasTranscript)
          item(
            MessageAction.transcribe,
            Icons.graphic_eq_rounded,
            l10n.attachmentTranscribe,
          ),
        if (canTranscribe && hasTranscript)
          item(
            MessageAction.retranscribe,
            Icons.translate_rounded,
            l10n.messageActionRetranscribe,
          ),
      ],
      if (message.isOwn)
        item(
          MessageAction.delete,
          Icons.delete_outline_rounded,
          l10n.commonDelete,
          color: Theme.of(context).colorScheme.error,
        ),
    ],
  );
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
      title: Text(context.l10n.messageActionDeleteTitle),
      content: Text(context.l10n.messageActionDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(context.l10n.commonDelete),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
