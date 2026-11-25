import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../services/schedule/scheduled_actions.dart';

/// Everything waiting on a time: messages queued to send and reminders.
///
/// One list for both because the user's question is the same — "what did I
/// set up for later?" — and the answer used to be scattered over every chat
/// it was set up in. Each entry can be moved, edited or taken back here.
class ScheduledScreen extends ConsumerWidget {
  const ScheduledScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final messages = [...ref.watch(messageSchedulerProvider)]
      ..sort((a, b) => a.dueAtMs.compareTo(b.dueAtMs));
    final reminders = [...ref.watch(reminderListProvider)]
      ..sort((a, b) => a.dueAtMs.compareTo(b.dueAtMs));

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.scheduledTitle)),
      body: WeftReadingPane(
        child: messages.isEmpty && reminders.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(WeftSpace.xl),
                  child: Text(
                    l10n.scheduledEmpty,
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: WeftSpace.xxl),
                children: [
                  if (messages.isNotEmpty) ...[
                    _Header(l10n.scheduledMessagesHeader),
                    for (final message in messages)
                      _ScheduledMessageTile(message: message),
                  ],
                  if (reminders.isNotEmpty) ...[
                    _Header(l10n.scheduledRemindersHeader),
                    for (final reminder in reminders)
                      _ReminderTile(reminder: reminder),
                  ],
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(
      WeftSpace.lg,
      WeftSpace.lg,
      WeftSpace.lg,
      WeftSpace.xs,
    ),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: context.text.labelLarge?.copyWith(
          color: context.colors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

enum _Action { editText, changeTime, delete }

class _ScheduledMessageTile extends ConsumerWidget {
  const _ScheduledMessageTile({required this.message});

  final ScheduledMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduler = ref.read(messageSchedulerProvider.notifier);

    Future<void> act(_Action action) async {
      switch (action) {
        case _Action.editText:
          final body = await _editText(context, message.body);
          if (body != null) scheduler.replace(message.copyWith(body: body));
        case _Action.changeTime:
          final when = await pickScheduleTime(context, from: message.dueAt);
          if (when != null) scheduler.replace(message.copyWith(dueAt: when));
        case _Action.delete:
          scheduler.cancel(message.id);
      }
    }

    return _EntryTile(
      icon: Icons.schedule_send_rounded,
      chatTitle: message.chatTitle,
      dueAt: message.dueAt,
      body: message.body,
      actions: const [_Action.editText, _Action.changeTime, _Action.delete],
      onAction: act,
    );
  }
}

class _ReminderTile extends ConsumerWidget {
  const _ReminderTile({required this.reminder});

  final PendingReminder reminder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.read(reminderListProvider.notifier);

    Future<void> act(_Action action) async {
      switch (action) {
        case _Action.changeTime:
          final when = await pickScheduleTime(context, from: reminder.dueAt);
          if (when != null) await reminders.reschedule(reminder, when);
        case _Action.delete:
          await reminders.cancel(reminder);
        case _Action.editText:
          break;
      }
    }

    return _EntryTile(
      icon: Icons.alarm_rounded,
      chatTitle: reminder.chatTitle.isEmpty
          ? reminder.title
          : reminder.chatTitle,
      dueAt: reminder.dueAt,
      body: reminder.body,
      actions: const [_Action.changeTime, _Action.delete],
      onAction: act,
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.chatTitle,
    required this.dueAt,
    required this.body,
    required this.actions,
    required this.onAction,
  });

  final IconData icon;
  final String chatTitle;
  final DateTime dueAt;
  final String body;
  final List<_Action> actions;
  final Future<void> Function(_Action) onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String label(_Action action) => switch (action) {
      _Action.editText => l10n.scheduledEditText,
      _Action.changeTime => l10n.scheduledChangeTime,
      _Action.delete => l10n.commonDelete,
    };

    return ListTile(
      leading: Icon(icon),
      title: Text(chatTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            DateFormat.MMMEd().add_Hm().format(dueAt),
            style: context.text.labelMedium?.copyWith(
              color: context.colors.primary,
            ),
          ),
          if (body.isNotEmpty)
            Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
      isThreeLine: body.isNotEmpty,
      trailing: PopupMenuButton<_Action>(
        tooltip: l10n.commonMore,
        onSelected: onAction,
        itemBuilder: (context) => [
          for (final action in actions)
            PopupMenuItem(value: action, child: Text(label(action))),
        ],
      ),
    );
  }
}

/// Asks for the new text of a scheduled message; null when dismissed or
/// emptied.
Future<String?> _editText(BuildContext context, String current) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _EditTextDialog(current: current),
  );
  return result == null || result.isEmpty ? null : result;
}

/// Owns its controller so it lives as long as the dialog does, closing
/// animation included.
class _EditTextDialog extends StatefulWidget {
  const _EditTextDialog({required this.current});

  final String current;

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.scheduledEditText),
    content: TextField(
      controller: _controller,
      autofocus: true,
      minLines: 1,
      maxLines: 6,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.commonCancel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: Text(context.l10n.commonSave),
      ),
    ],
  );
}

/// Date then time, starting at [from]; null when either step is dismissed or
/// the moment picked has already passed.
Future<DateTime?> pickScheduleTime(
  BuildContext context, {
  required DateTime from,
}) async {
  final now = DateTime.now();
  final start = from.isAfter(now) ? from : now;
  final date = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start),
  );
  if (time == null || !context.mounted) return null;
  final when = DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  if (!when.isAfter(DateTime.now())) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(context.l10n.chatTimeAlreadyPast)));
    return null;
  }
  return when;
}
