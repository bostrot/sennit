import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/quick_message_providers.dart';
import '../../services/ai/quick_messages.dart';
import '../chat/quick_message_sheet.dart' show QuickMessageEmoji;
import 'settings_section.dart';

/// The quick messages the attach menu offers: add, edit, reorder, delete, and
/// put the shipped ones back.
///
/// The privacy box is on top for the reason every AI screen has one: picking
/// a quick message sends part of a conversation to the user's model, and the
/// place to say so is where the list is made.
class QuickMessagesScreen extends ConsumerWidget {
  const QuickMessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final messages = ref.watch(quickMessagesProvider);

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(l10n.quickMessageSheetTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_backup_restore_rounded),
            tooltip: l10n.quickMessagesRestoreDefaults,
            onPressed: () => _confirmRestore(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.quickMessagesAdd),
      ),
      body: WeftReadingPane(
        child: ReorderableListView.builder(
          // Symmetric, because this list takes no directional padding; the
          // top and the room under the button are the header and footer.
          padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
          footer: const SizedBox(height: WeftSpace.fabClearance),
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: WeftSpace.lg),
              PrivacyNotice(
                message: l10n.quickMessagesExplainer(
                  kQuickMessageContextMessages,
                ),
              ),
              const SizedBox(height: WeftSpace.lg),
              if (messages.isEmpty)
                Text(
                  l10n.quickMessagesEmpty,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          itemCount: messages.length,
          onReorderItem: ref.read(quickMessagesProvider.notifier).reorder,
          itemBuilder: (context, index) {
            final message = messages[index];
            return ListTile(
              key: ValueKey(message.id),
              contentPadding: const EdgeInsetsDirectional.only(
                end: WeftSpace.xl,
              ),
              leading: QuickMessageEmoji(message: message),
              title: Text(l10n.quickMessageTitle(message)),
              subtitle: Text(
                message.effectivePrompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: l10n.quickMessagesEditOne,
                onPressed: () => _edit(context, ref, message),
              ),
              onTap: () => _edit(context, ref, message),
            );
          },
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    QuickMessage? existing,
  ) async {
    final saved = await Navigator.of(context).push<QuickMessage>(
      MaterialPageRoute<QuickMessage>(
        builder: (_) => QuickMessageEditor(message: existing),
      ),
    );
    if (saved != null) ref.read(quickMessagesProvider.notifier).save(saved);
  }

  Future<void> _confirmRestore(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.quickMessagesRestoreDefaults),
        content: Text(l10n.quickMessagesRestoreConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.quickMessagesRestoreDefaults),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(quickMessagesProvider.notifier).restoreDefaults();
    }
  }
}

/// One quick message's title, emoji and prompt.
///
/// A built-in one opens with its shipped words filled in, and saves only what
/// was actually changed: an untouched title keeps following the app language,
/// an untouched prompt keeps any later improvement to it.
class QuickMessageEditor extends ConsumerStatefulWidget {
  const QuickMessageEditor({super.key, this.message});

  final QuickMessage? message;

  @override
  ConsumerState<QuickMessageEditor> createState() => _QuickMessageEditorState();
}

class _QuickMessageEditorState extends ConsumerState<QuickMessageEditor> {
  late final TextEditingController _title = TextEditingController();
  late final TextEditingController _emoji = TextEditingController(
    text: widget.message?.emoji ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.message?.effectivePrompt ?? '',
  );
  late String _shippedTitle;
  var _started = false;

  late final String _id =
      widget.message?.id ??
      'qm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final message = widget.message;
    final preset = message?.preset;
    _shippedTitle = preset == null
        ? ''
        : context.l10n.quickMessagePreset(preset);
    _title.text = message == null
        ? ''
        : context.l10n.quickMessageTitle(message);
  }

  @override
  void dispose() {
    _title.dispose();
    _emoji.dispose();
    _prompt.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty && _prompt.text.trim().isNotEmpty;

  QuickMessage get _draft {
    final preset = widget.message?.preset;
    final title = _title.text.trim();
    final prompt = _prompt.text.trim();
    final shippedPrompt = preset == null
        ? null
        : kQuickMessageDefaultPrompts[preset];
    return QuickMessage(
      id: _id,
      preset: preset,
      title: preset != null && title == _shippedTitle ? null : title,
      emoji: _emoji.text.trim(),
      prompt: prompt == shippedPrompt ? null : prompt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(
          widget.message == null
              ? l10n.quickMessagesAdd
              : l10n.quickMessagesEditOne,
        ),
        actions: [
          if (widget.message != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: l10n.commonDelete,
              onPressed: () {
                ref.read(quickMessagesProvider.notifier).remove(_id);
                Navigator.of(context).pop();
              },
            ),
          TextButton(
            onPressed: _valid ? () => Navigator.of(context).pop(_draft) : null,
            child: Text(l10n.commonSave),
          ),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            WeftLabelledField(
              label: l10n.quickMessageFieldTitle,
              child: TextField(
                controller: _title,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.quickMessageFieldTitle,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            WeftLabelledField(
              label: l10n.quickMessageFieldEmoji,
              child: TextField(
                controller: _emoji,
                textInputAction: TextInputAction.next,
                maxLength: 8,
                decoration: InputDecoration(
                  labelText: l10n.quickMessageFieldEmoji,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            WeftLabelledField(
              label: l10n.quickMessageFieldPrompt,
              child: TextField(
                controller: _prompt,
                minLines: 3,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: l10n.quickMessageFieldPrompt,
                  hintText: l10n.quickMessageFieldPromptHint,
                  helperText: l10n.quickMessageFieldPromptHelper,
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
