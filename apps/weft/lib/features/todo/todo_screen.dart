import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/auto_reply_providers.dart' show autoReplyEndpointProvider;
import '../../app/localisation.dart';
import '../../app/todo_providers.dart';
import '../../services/integrations/home_assistant.dart';
import '../../services/todo/todo_item.dart';
import '../settings/integrations_screen.dart' show homeAssistantProvider;
import '../settings/settings_section.dart';

/// The to-do list: what is open on top, what is done folded away below.
///
/// Entries come from two places — the field at the top, and the assistant
/// reading chats when the user has switched it on in the settings sheet. An
/// assistant entry says which chat it came from, so "Send Anna the photos"
/// can be traced back to the conversation that asked for it.
class TodoScreen extends ConsumerStatefulWidget {
  const TodoScreen({super.key});

  @override
  ConsumerState<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends ConsumerState<TodoScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  bool _showDone = false;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add() {
    final added = ref.read(todoListProvider.notifier).add(_field.text);
    if (added == null) return;
    _field.clear();
    // Kept focused: lists are typed in runs.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = ref.watch(todoListProvider);
    final open = [
      for (final i in items)
        if (!i.done) i,
    ];
    final done = [
      for (final i in items)
        if (i.done) i,
    ];

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(l10n.todoTitle),
        actions: [
          IconButton(
            tooltip: l10n.todoSettingsTooltip,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => const TodoSettingsSheet(),
            ),
          ),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: WeftSpace.md),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
              child: TextField(
                controller: _field,
                focusNode: _focus,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _add(),
                decoration: InputDecoration(
                  hintText: l10n.todoAddHint,
                  suffixIcon: IconButton(
                    tooltip: l10n.commonAdd,
                    icon: const Icon(Icons.add_rounded),
                    onPressed: _add,
                  ),
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.sm),
            if (open.isEmpty)
              Padding(
                padding: const EdgeInsets.all(WeftSpace.lg),
                child: Text(
                  l10n.todoEmpty,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            for (final item in open) _TodoTile(item: item),
            if (done.isNotEmpty) ...[
              const Divider(height: WeftSpace.xl),
              ListTile(
                title: Text(l10n.todoDoneSection(done.length)),
                leading: Icon(
                  _showDone
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                onTap: () => setState(() => _showDone = !_showDone),
                trailing: TextButton(
                  onPressed: () {
                    ref.read(todoListProvider.notifier).clearDone();
                    showWeftMessage(context, l10n.todoDoneCleared);
                  },
                  child: Text(l10n.todoClearDone),
                ),
              ),
              if (_showDone)
                for (final item in done) _TodoTile(item: item),
            ],
          ],
        ),
      ),
    );
  }
}

class _TodoTile extends ConsumerWidget {
  const _TodoTile({required this.item});

  final TodoItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final list = ref.read(todoListProvider.notifier);
    final details = [
      if (item.due != null)
        l10n.todoDueOn(
          MaterialLocalizations.of(context).formatMediumDate(item.due!),
        ),
      if (item.chatTitle != null) l10n.todoFromChat(item.chatTitle!),
    ];
    final overdue =
        !item.done &&
        item.due != null &&
        item.due!.isBefore(DateUtils.dateOnly(DateTime.now()));

    return Dismissible(
      key: ValueKey('todo-${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
        color: context.colors.errorContainer,
        child: Icon(
          Icons.delete_outline_rounded,
          color: context.colors.onErrorContainer,
        ),
      ),
      onDismissed: (_) {
        list.remove(item.id);
        showWeftMessage(context, l10n.todoDeleted);
      },
      child: CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        value: item.done,
        onChanged: (value) => list.setDone(item.id, done: value ?? false),
        title: Text(
          item.title,
          style: item.done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: context.colors.onSurfaceVariant,
                )
              : null,
        ),
        subtitle: details.isEmpty
            ? null
            : Text(
                details.join(' · '),
                style: overdue ? TextStyle(color: context.colors.error) : null,
              ),
        secondary: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.fromAi)
              Tooltip(
                message: l10n.todoAddedByAssistant,
                child: Icon(
                  Icons.auto_awesome_outlined,
                  size: 18,
                  semanticLabel: l10n.todoAddedByAssistant,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            IconButton(
              tooltip: l10n.todoEditTitle,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_Edit>(
      context: context,
      builder: (_) => _EditDialog(item: item),
    );
    if (result == null) return;
    if (result.delete) {
      ref.read(todoListProvider.notifier).remove(item.id);
      return;
    }
    ref
        .read(todoListProvider.notifier)
        .edit(item.id, title: result.title, due: result.due);
  }
}

class _Edit {
  const _Edit({required this.title, this.due, this.delete = false});

  final String title;
  final DateTime? due;
  final bool delete;
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.item});

  final TodoItem item;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _title = TextEditingController(text: widget.item.title);
  late DateTime? _due = widget.item.due;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _due = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.todoEditTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.todoTitleField),
          ),
          const SizedBox(height: WeftSpace.md),
          Wrap(
            spacing: WeftSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(
                  _due == null
                      ? l10n.todoSetDue
                      : l10n.todoDueOn(
                          MaterialLocalizations.of(
                            context,
                          ).formatMediumDate(_due!),
                        ),
                ),
                onPressed: _pickDue,
              ),
              if (_due != null)
                IconButton(
                  tooltip: l10n.todoClearDue,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _due = null),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_Edit(title: widget.item.title, delete: true)),
          child: Text(l10n.commonDelete),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_Edit(title: _title.text, due: _due)),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// The two switches: the assistant, and the Home Assistant mirror.
///
/// Each says what it sends where before it can be switched on, like every
/// other gate in settings. Neither can be switched on without what it needs —
/// an AI endpoint, a connected Home Assistant — and says where to set that up
/// instead of failing quietly later.
class TodoSettingsSheet extends ConsumerStatefulWidget {
  const TodoSettingsSheet({super.key});

  @override
  ConsumerState<TodoSettingsSheet> createState() => _TodoSettingsSheetState();
}

class _TodoSettingsSheetState extends ConsumerState<TodoSettingsSheet> {
  Future<List<HomeAssistantTodoList>>? _lists;

  /// Asks again on the next build. Not here: every settings write rebuilds
  /// [homeAssistantProvider] and closes the client it had, so a request
  /// started on the client in hand would be cut off by the write that
  /// prompted it. The build reads the fresh one.
  void _reloadLists() {
    setState(() {
      _lists = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(todoPreferencesProvider);
    final hasEndpoint = ref.watch(autoReplyEndpointProvider) != null;
    final ha = ref.watch(homeAssistantProvider);
    if (ha != null && prefs.homeAssistantSync && _lists == null) {
      _lists = ha.todoLists();
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.lg,
          0,
          WeftSpace.lg,
          WeftSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: PrivacyGatedTitle(
                title: l10n.todoAiTitle,
                warning: l10n.todoAiWarning,
              ),
              subtitle: Text(
                hasEndpoint ? l10n.todoAiSubtitle : l10n.todoAiNeedsEndpoint,
              ),
              value: prefs.aiEnabled && hasEndpoint,
              onChanged: hasEndpoint
                  ? (v) => writeTodoPreference(ref, TodoSettings.aiEnabled, v)
                  : null,
            ),
            const Divider(height: WeftSpace.xl),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.todoHaTitle),
              subtitle: Text(
                ha == null ? l10n.todoHaNeedsSetup : l10n.todoHaSubtitle,
              ),
              value: prefs.homeAssistantSync && ha != null,
              onChanged: ha == null
                  ? null
                  : (v) {
                      writeTodoPreference(
                        ref,
                        TodoSettings.homeAssistantSync,
                        v,
                      );
                      if (v) _reloadLists();
                    },
            ),
            if (ha != null && prefs.homeAssistantSync)
              FutureBuilder<List<HomeAssistantTodoList>>(
                future: _lists,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(WeftSpace.md),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.todoHaLoadFailed('${snapshot.error}'),
                            style: TextStyle(color: context.colors.error),
                          ),
                        ),
                        TextButton(
                          onPressed: _reloadLists,
                          child: Text(l10n.commonRetry),
                        ),
                      ],
                    );
                  }
                  final lists = snapshot.data ?? const [];
                  if (lists.isEmpty) {
                    return Text(
                      l10n.todoHaNoLists,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    );
                  }
                  final current = prefs.homeAssistantEntity;
                  return DropdownButtonFormField<String>(
                    initialValue: lists.any((l) => l.entityId == current)
                        ? current
                        : null,
                    decoration: InputDecoration(
                      labelText: l10n.todoHaListField,
                    ),
                    items: [
                      for (final list in lists)
                        DropdownMenuItem(
                          value: list.entityId,
                          child: Text(list.name),
                        ),
                    ],
                    onChanged: (entity) {
                      if (entity == null) return;
                      writeTodoPreference(
                        ref,
                        TodoSettings.homeAssistantEntity,
                        entity,
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
