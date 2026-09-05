import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/auto_reply_providers.dart';
import '../../app/l10n_labels.dart';
import '../../app/labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../services/ai/auto_reply_writer.dart';
import 'settings_section.dart';

/// Rules that answer for the user when they are not there — and leave the
/// conversation unread.
///
/// The list, the switches, and the way to the editor. Everything that decides
/// *whether* a rule fires is `weft_autoreply`; this screen only edits values
/// and states, in an always-visible box, what turning one on actually does.
/// That box is not decoration: a feature that sends messages to other people
/// under someone's name must not be switchable on by anyone who has not been
/// told, in the same breath, exactly what it will do.
class AutoReplyScreen extends ConsumerWidget {
  const AutoReplyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final rules = ref.watch(autoReplyRulesProvider);
    final endpoint = ref.watch(autoReplyEndpointProvider);

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.autoReplyTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editRule(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.autoReplyNewRule),
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            WeftSpace.lg,
            WeftSpace.lg,
            WeftSpace.fabClearance,
          ),
          children: [
            // Three sentences, always on screen, never behind a disclosure:
            // messages go out by themselves, the chat stays unread, and there
            // is a ceiling. Every one of them is something a user would be
            // upset to discover afterwards.
            PrivacyNotice(
              message: l10n.autoReplyExplainer(kAutoReplyMaxPerConversation),
            ),
            const SizedBox(height: WeftSpace.lg),

            if (endpoint == null) ...[
              _NoEndpointNotice(),
              const SizedBox(height: WeftSpace.lg),
            ],

            SettingsSectionHeader(
              title: l10n.autoReplyRulesTitle,
              subtitle: l10n.autoReplyRulesSubtitle,
            ),
            if (rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: WeftSpace.lg),
                child: Text(
                  l10n.autoReplyNoRules,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final rule in rules)
                _RuleRow(
                  rule: rule,
                  onEdit: () => _editRule(context, ref, rule),
                ),

            const SizedBox(height: WeftSpace.xl),
            const _AttemptLog(),
          ],
        ),
      ),
    );
  }

  Future<void> _editRule(
    BuildContext context,
    WidgetRef ref,
    AutoReplyRule? existing,
  ) async {
    final saved = await Navigator.of(context).push<AutoReplyRule>(
      MaterialPageRoute<AutoReplyRule>(
        builder: (_) => AutoReplyRuleEditor(rule: existing),
      ),
    );
    if (saved != null) ref.read(autoReplyRulesProvider.notifier).save(saved);
  }
}

/// One rule in the list: its name, who it answers, and its switch.
class _RuleRow extends ConsumerWidget {
  const _RuleRow({required this.rule, required this.onEdit});

  final AutoReplyRule rule;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final name = rule.name.trim().isEmpty
        ? l10n.autoReplyAudience(rule.audience)
        : rule.name.trim();

    return SwitchListTile(
      // The switch is the tile, so the row is one target and one node rather
      // than a label a reader meets separately from the control it names.
      title: Text(name),
      subtitle: Text(
        semanticsSentence([
          l10n.autoReplyAudience(rule.audience),
          l10n.autoReplyCooldownLabel(rule.cooldown.inMinutes),
          if (rule.window != null) l10n.autoReplyWindowSet,
          if (rule.prompt.trim().isEmpty) l10n.autoReplyNoPrompt,
        ]),
      ),
      value: rule.enabled,
      // A rule with no prompt has nothing to send, so its switch is dead
      // rather than lying about being armed.
      onChanged: rule.prompt.trim().isEmpty
          ? null
          : (value) => ref
                .read(autoReplyRulesProvider.notifier)
                .setEnabled(rule.id, enabled: value),
      secondary: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: l10n.autoReplyEditRule,
        onPressed: onEdit,
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}

/// Why nothing will happen yet, and where to fix it.
class _NoEndpointNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: context.colors.primary,
          ),
          const SizedBox(width: WeftSpace.md),
          Expanded(
            child: Text(
              // The section is named from its own key rather than spelled out
              // here, so the pointer cannot drift from the row it points at
              // when one of them is renamed or retranslated.
              context.l10n.autoReplyNoEndpoint(
                context.l10n.settingsEndpointsTitle,
              ),
              style: context.text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// What auto-reply has done lately.
///
/// A feature that speaks for someone must be able to say what it said. This is
/// also where a failure surfaces: a model that would not answer, a conversation
/// that hit its cap, a send the homeserver refused.
class _AttemptLog extends ConsumerWidget {
  const _AttemptLog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final attempts = ref.watch(autoReplyLogProvider);
    if (attempts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          title: l10n.autoReplyRecentTitle,
          subtitle: l10n.autoReplyRecentSubtitle,
        ),
        for (final attempt in attempts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              attempt.succeeded
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded,
              color: attempt.succeeded
                  ? context.colors.primary
                  : context.colors.error,
            ),
            title: Text(attempt.chatTitle),
            subtitle: Text(
              semanticsSentence([
                l10n.autoReplyAttemptOutcome(attempt),
                if (attempt.text != null) '“${attempt.text}”',
              ]),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => ref.read(autoReplyLogProvider.notifier).clear(),
            child: Text(l10n.autoReplyClearLog),
          ),
        ),
      ],
    );
  }
}

/// Writes or edits one rule. Pops the rule, or null when cancelled.
class AutoReplyRuleEditor extends ConsumerStatefulWidget {
  const AutoReplyRuleEditor({super.key, this.rule});

  final AutoReplyRule? rule;

  @override
  ConsumerState<AutoReplyRuleEditor> createState() =>
      _AutoReplyRuleEditorState();
}

class _AutoReplyRuleEditorState extends ConsumerState<AutoReplyRuleEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.rule?.name ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.rule?.prompt ?? '',
  );

  late AutoReplyAudience _audience =
      widget.rule?.audience ?? const EveryoneAudience();
  late ReplyWindow? _window = widget.rule?.window;
  late int _cooldownMinutes =
      widget.rule?.cooldown.inMinutes ?? kAutoReplyDefaultCooldown.inMinutes;

  /// The last dry run, or null before one has been asked for.
  AutoReplyDraft? _preview;
  bool _previewing = false;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  /// The rule id, stable across edits.
  ///
  /// A new id on every save would reset the cooldown ledger — which is exactly
  /// the moment someone is experimenting with a prompt and least wants a
  /// surprise message going out.
  late final String _id =
      widget.rule?.id ??
      'rule_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  AutoReplyRule get _draft => AutoReplyRule(
    id: _id,
    name: _name.text.trim(),
    prompt: _prompt.text,
    audience: _audience,
    // Editing never arms a rule. Saving an edit to a rule that was already on
    // keeps it on; a new rule is off until its switch is moved in the list,
    // which is a second, deliberate act.
    enabled: widget.rule?.enabled ?? false,
    window: _window,
    cooldown: Duration(minutes: _cooldownMinutes),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(
          widget.rule == null ? l10n.autoReplyNewRule : l10n.autoReplyEditRule,
        ),
        actions: [
          if (widget.rule != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: l10n.autoReplyDeleteRule,
              onPressed: _confirmDelete,
            ),
          TextButton(
            onPressed: _prompt.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(_draft),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            WeftLabelledField(
              label: l10n.autoReplyNameLabel,
              child: TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.autoReplyNameLabel,
                  hintText: l10n.autoReplyNameHint,
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.lg),

            WeftLabelledField(
              label: l10n.autoReplyPromptLabel,
              child: TextField(
                controller: _prompt,
                minLines: 4,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: l10n.autoReplyPromptLabel,
                  hintText: l10n.autoReplyPromptHint,
                  // The prompt is the feature. It goes to the model verbatim,
                  // which is what this says so nobody has to guess whether
                  // Braid rewrites it first.
                  helperText: l10n.autoReplyPromptHelper,
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: WeftSpace.lg),

            SettingsSectionHeader(
              title: l10n.autoReplyAudienceTitle,
              subtitle: l10n.autoReplyAudienceSubtitle,
            ),
            _AudienceEditor(
              audience: _audience,
              onChanged: (audience) => setState(() => _audience = audience),
            ),
            const SizedBox(height: WeftSpace.lg),

            SettingsSectionHeader(
              title: l10n.autoReplyWindowTitle,
              subtitle: l10n.autoReplyWindowSubtitle,
            ),
            _WindowEditor(
              window: _window,
              onChanged: (window) => setState(() => _window = window),
            ),
            const SizedBox(height: WeftSpace.lg),

            SettingsSectionHeader(
              title: l10n.autoReplyCooldownTitle,
              subtitle: l10n.autoReplyCooldownSubtitle(
                kAutoReplyMaxPerConversation,
              ),
            ),
            Semantics(
              // A slider announces "45" and nothing else. The unit and the
              // thing it governs have to be in the label, or the control is
              // unusable without sight of the row above it.
              label: l10n.autoReplyCooldownLabel(_cooldownMinutes),
              child: Slider(
                value: _cooldownMinutes.toDouble(),
                max: 240,
                divisions: 16,
                label: l10n.autoReplyCooldownLabel(_cooldownMinutes),
                onChanged: (value) =>
                    setState(() => _cooldownMinutes = value.round()),
              ),
            ),
            const SizedBox(height: WeftSpace.lg),

            _PreviewSection(
              busy: _previewing,
              draft: _preview,
              onRun: _prompt.text.trim().isEmpty ? null : _runPreview,
            ),
          ],
        ),
      ),
    );
  }

  /// Writes a reply against a real conversation and shows it, sending nothing.
  ///
  /// The safe way to tune a prompt. It deliberately goes around `shouldReply`:
  /// the point is to try a night-time rule in the afternoon, and a preview that
  /// obeyed the schedule would answer "not now" to the one question the button
  /// is for.
  Future<void> _runPreview() async {
    final service = ref.read(autoReplyServiceProvider);
    final chat = previewChatFor(ref.read(chatsProvider).value ?? const []);
    if (service == null || chat == null) {
      setState(
        () => _preview = const AutoReplyDraft.failed(
          AutoReplyOutcome.notConfigured,
        ),
      );
      return;
    }

    setState(() {
      _previewing = true;
      _preview = null;
    });
    final draft = await service.preview(_draft, chat);
    if (!mounted) return;
    setState(() {
      _previewing = false;
      _preview = draft;
    });
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.autoReplyDeleteRule),
        content: Text(l10n.autoReplyDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    ref.read(autoReplyRulesProvider.notifier).remove(_id);
    if (mounted) Navigator.of(context).pop();
  }
}

/// Who a rule answers.
///
/// Four kinds behind one chip row, and the pickers underneath are the app's own
/// data rather than new lists: the labels come from `ChatLabels`, the networks
/// from the repository's `availableNetworks`, and the conversations from the
/// inbox itself.
class _AudienceEditor extends ConsumerWidget {
  const _AudienceEditor({required this.audience, required this.onChanged});

  final AutoReplyAudience audience;
  final ValueChanged<AutoReplyAudience> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final labels = ref.watch(chatLabelsProvider.notifier).all;
    final chats = ref.watch(chatsProvider).value ?? const <Chat>[];
    final networks = <ChatNetwork>{for (final chat in chats) ...chat.networks};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: WeftSpace.sm,
          runSpacing: WeftSpace.xs,
          children: [
            ChoiceChip(
              label: Text(l10n.autoReplyAudienceEveryone),
              selected: audience is EveryoneAudience,
              onSelected: (_) => onChanged(const EveryoneAudience()),
            ),
            ChoiceChip(
              label: Text(l10n.autoReplyAudienceNetworks),
              selected: audience is NetworkAudience,
              onSelected: networks.isEmpty
                  ? null
                  : (_) => onChanged(NetworkAudience({networks.first})),
            ),
            ChoiceChip(
              label: Text(l10n.autoReplyAudienceLabel),
              selected: audience is LabelAudience,
              onSelected: labels.isEmpty
                  ? null
                  : (_) => onChanged(LabelAudience(labels.first)),
            ),
            ChoiceChip(
              label: Text(l10n.autoReplyAudienceContacts),
              selected: audience is ContactAudience,
              onSelected: chats.isEmpty
                  ? null
                  : (_) => onChanged(const ContactAudience({})),
            ),
          ],
        ),
        const SizedBox(height: WeftSpace.sm),
        switch (audience) {
          EveryoneAudience() => const SizedBox.shrink(),
          NetworkAudience(:final networks) => _NetworkChoices(
            available: {for (final chat in chats) ...chat.networks}.toList(),
            selected: networks,
            onChanged: (next) => onChanged(NetworkAudience(next)),
          ),
          LabelAudience(:final label) => _LabelChoices(
            available: labels,
            selected: label,
            onChanged: (next) => onChanged(LabelAudience(next)),
          ),
          ContactAudience(:final ids) => _ChatChoices(
            chats: chats,
            selected: ids,
            onChanged: (next) => onChanged(ContactAudience(next)),
          ),
        },
      ],
    );
  }
}

class _NetworkChoices extends StatelessWidget {
  const _NetworkChoices({
    required this.available,
    required this.selected,
    required this.onChanged,
  });

  final List<ChatNetwork> available;
  final Set<ChatNetwork> selected;
  final ValueChanged<Set<ChatNetwork>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final network in available)
          NetworkToggleRow(
            network: network,
            allowed: selected.contains(network),
            onChanged: (on) => onChanged({
              for (final n in available)
                if (n == network ? on : selected.contains(n)) n,
            }),
          ),
      ],
    );
  }
}

class _LabelChoices extends StatelessWidget {
  const _LabelChoices({
    required this.available,
    required this.selected,
    required this.onChanged,
  });

  final List<String> available;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: WeftSpace.sm,
      runSpacing: WeftSpace.xs,
      children: [
        for (final label in available)
          ChoiceChip(
            label: Text(label),
            selected: label == selected,
            onSelected: (_) => onChanged(label),
          ),
      ],
    );
  }
}

/// The conversations a rule names.
///
/// Keyed on the *contact* id where the merge fold has one, so choosing a person
/// covers every network they reach the user on rather than one leg of them.
class _ChatChoices extends StatelessWidget {
  const _ChatChoices({
    required this.chats,
    required this.selected,
    required this.onChanged,
  });

  final List<Chat> chats;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final chat in chats.take(50))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            secondary: WeftAvatar(
              label: chat.title,
              size: 32,
              networks: chat.networks,
              semanticsLabel: '',
            ),
            title: Text(chat.title),
            value: selected.contains(_keyOf(chat)),
            onChanged: (on) {
              final key = _keyOf(chat);
              onChanged({
                for (final id in selected)
                  if (id != key) id,
                if (on ?? false) key,
              });
            },
          ),
      ],
    );
  }

  static String _keyOf(Chat chat) => chat.contactId ?? chat.id;
}

/// When a rule may fire.
class _WindowEditor extends StatelessWidget {
  const _WindowEditor({required this.window, required this.onChanged});

  final ReplyWindow? window;
  final ValueChanged<ReplyWindow?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = window;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.autoReplyWindowEnable),
          value: current != null,
          onChanged: (on) => onChanged(
            on
                ? ReplyWindow(
                    startMinute: 9 * 60,
                    endMinute: 17 * 60,
                    // The device's own offset, captured now, so a window set in
                    // Berlin still means nine in the morning in Berlin when the
                    // decision is taken in a background isolate that has no
                    // local timezone at all.
                    offsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
                  )
                : null,
          ),
        ),
        if (current != null) ...[
          Row(
            children: [
              Expanded(
                child: _MinutePicker(
                  label: l10n.autoReplyWindowFrom,
                  minute: current.startMinute,
                  onChanged: (m) => onChanged(current.copyWith(startMinute: m)),
                ),
              ),
              const SizedBox(width: WeftSpace.md),
              Expanded(
                child: _MinutePicker(
                  label: l10n.autoReplyWindowTo,
                  minute: current.endMinute,
                  onChanged: (m) => onChanged(current.copyWith(endMinute: m)),
                ),
              ),
            ],
          ),
          const SizedBox(height: WeftSpace.sm),
          Wrap(
            spacing: WeftSpace.xs,
            children: [
              for (var day = DateTime.monday; day <= DateTime.sunday; day++)
                FilterChip(
                  label: Text(l10n.autoReplyWeekday(day)),
                  selected:
                      current.weekdays.isEmpty ||
                      current.weekdays.contains(day),
                  onSelected: (on) {
                    // An empty set means every day. Unticking one of "all" has
                    // to materialise the set first, or the first tap would
                    // appear to do nothing.
                    final base = current.weekdays.isEmpty
                        ? {
                            for (
                              var d = DateTime.monday;
                              d <= DateTime.sunday;
                              d++
                            )
                              d,
                          }
                        : {...current.weekdays};
                    if (on) {
                      base.add(day);
                    } else {
                      base.remove(day);
                    }
                    onChanged(current.copyWith(weekdays: base));
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// An hour picker over minutes-since-midnight.
class _MinutePicker extends StatelessWidget {
  const _MinutePicker({
    required this.label,
    required this.minute,
    required this.onChanged,
  });

  final String label;
  final int minute;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    // The label rides in the decoration rather than in a `WeftLabelledField`
    // wrapper: that one declares `textField: true`, and a dropdown announced as
    // an edit box is worse than one announced by its own role.
    //
    // The hours come from `MaterialLocalizations` rather than a padded string,
    // so a locale that writes "9 AM" gets it — and so the device's own
    // 24-hour setting is honoured rather than overridden by a format literal.
    final words = MaterialLocalizations.of(context);
    return DropdownButtonFormField<int>(
      initialValue: (minute ~/ 60) * 60,
      decoration: InputDecoration(labelText: label),
      items: [
        for (var hour = 0; hour < 24; hour++)
          DropdownMenuItem(
            value: hour * 60,
            child: Text(
              words.formatTimeOfDay(
                TimeOfDay(hour: hour, minute: 0),
                alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                  context,
                ),
              ),
            ),
          ),
      ],
      onChanged: (value) => value == null ? null : onChanged(value),
    );
  }
}

/// The dry run and whatever it produced.
class _PreviewSection extends StatelessWidget {
  const _PreviewSection({
    required this.busy,
    required this.draft,
    required this.onRun,
  });

  final bool busy;
  final AutoReplyDraft? draft;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final result = draft;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          title: l10n.autoReplyPreviewTitle,
          subtitle: l10n.autoReplyPreviewSubtitle,
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onRun,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.autoReplyPreviewRun),
        ),
        if (result != null) ...[
          const SizedBox(height: WeftSpace.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(WeftSpace.md),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHighest,
              borderRadius: WeftRadius.allMd,
            ),
            child: Text(
              result.text ?? l10n.autoReplyOutcome(result.outcome),
              style: context.text.bodyMedium,
            ),
          ),
        ],
      ],
    );
  }
}
