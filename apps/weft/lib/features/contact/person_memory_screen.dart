import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/auto_reply_providers.dart' show autoReplyEndpointProvider;
import '../../app/billing_providers.dart';
import '../../app/localisation.dart';
import '../../app/person_memory_providers.dart';
import '../../app/providers.dart';
import '../../app/quick_message_providers.dart' show quickMessageClientProvider;
import '../../services/ai/conversation_context.dart' show kAiContextMessages;
import '../../services/ai/llm_budget.dart' show AiFeature;
import '../../services/ai/person_memory.dart';
import '../../services/ai/writing_style.dart' show kStyleMaxChars;
import '../../services/billing/entitlements.dart';
import '../settings/person_memory_settings_screen.dart';
import '../settings/pro_screen.dart';

/// The people of a group whose memory can be opened from it, or that a fact
/// can be added to: whoever wrote in the part of it the timeline has loaded.
/// See [directMemoryPerson] for a direct chat's.
final chatMemoryPeopleProvider = FutureProvider.autoDispose
    .family<List<MemoryPerson>, String>((ref, chatId) async {
      final chat = (ref.watch(chatsProvider).value ?? const <Chat>[])
          .where((c) => c.id == chatId)
          .firstOrNull;
      if (chat == null || !chat.isGroup) return const [];
      final repository = ref.watch(chatRepositoryProvider);
      final messages = (await repository.timelineFor(chatId)).view().messages;
      return memoryPeopleFor(repository.identityGraph, chat, messages);
    });

/// The person the direct chat [chat] is with, whose memory is the chat's.
MemoryPerson directMemoryPerson(WidgetRef ref, Chat chat) => (
  name: chat.title,
  keys: personMemoryKeysFor(
    ref.read(chatRepositoryProvider).identityGraph,
    chat,
  ),
);

/// The one memory of the chat [chatId]: "About Anna" for a direct chat,
/// "About this group" for a group. The note, what was learned on its own,
/// and the button that learns from the chat now.
class ChatMemoryScreen extends ConsumerWidget {
  const ChatMemoryScreen({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = (ref.watch(chatsProvider).value ?? const <Chat>[])
        .where((c) => c.id == chatId)
        .firstOrNull;
    if (chat == null) {
      return Scaffold(
        appBar: WeftAppBar(),
        body: Center(child: Text(context.l10n.contactGone)),
      );
    }
    final repository = ref.watch(chatRepositoryProvider);
    return MemoryEditor.chat(
      chat: chat,
      people: chat.isGroup
          ? ref.watch(chatMemoryPeopleProvider(chatId)).value ?? const []
          : [directMemoryPerson(ref, chat)],
      loadMessages: (wanted) async =>
          loadHistoryForAi(await repository.timelineFor(chat.id), wanted),
    );
  }
}

/// The memory of one person of a group, used in every chat they are in.
class PersonMemoryScreen extends StatelessWidget {
  const PersonMemoryScreen({super.key, required this.person});

  final MemoryPerson person;

  @override
  Widget build(BuildContext context) => MemoryEditor.person(person: person);
}

/// The editor for either layer, given what it edits rather than finding it —
/// which is what lets a test pump it without a repository.
class MemoryEditor extends ConsumerStatefulWidget {
  /// A chat's memory: a group's own, or for a direct chat the person's it is
  /// with — the single entry of [people] — which is all a direct chat has.
  /// In a group, [people] are who a fact can be added to instead.
  /// [loadMessages] is the conversation "Learn now" reads, at least the
  /// number of messages it is given when there are that many.
  MemoryEditor.chat({
    super.key,
    required Chat this.chat,
    required this.people,
    required Future<List<WeftMessage>> Function(int wanted) this.loadMessages,
  }) : person = null,
       keys = !chat.isGroup && people.isNotEmpty
           ? people.first.keys
           : chatMemoryKeys(chat);

  /// A person's memory.
  MemoryEditor.person({super.key, required MemoryPerson this.person})
    : chat = null,
      people = const [],
      loadMessages = null,
      keys = person.keys;

  final Chat? chat;
  final MemoryPerson? person;
  final List<MemoryPerson> people;
  final Future<List<WeftMessage>> Function(int wanted)? loadMessages;

  /// Where the note is filed.
  final List<String> keys;

  /// Whether this is a direct chat's memory: its person's.
  bool get direct => chat != null && !chat!.isGroup && people.isNotEmpty;

  @override
  ConsumerState<MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends ConsumerState<MemoryEditor> {
  /// Held rather than read from `ref` each time, because the last save happens
  /// in [dispose], where `ref` may no longer be read.
  late final PersonMemoryNotifier _memory = ref.read(
    personMemoryProvider.notifier,
  );
  // A direct chat's, with what older versions kept for the chat itself
  // folded in — saved after the first frame, see [initState].
  late final TextEditingController _note = TextEditingController(
    text: widget.direct
        ? _memory.book
              .foldChatInto(chatMemoryKeys(widget.chat!), widget.keys)
              .noteFor(widget.keys)
        : _memory.book.noteFor(widget.keys),
  );
  Timer? _debounce;
  bool _busy = false;

  /// The model's short version of a person's note, waiting for Replace.
  String? _condensed;

  bool get _isChat => widget.chat != null;

  bool get _direct => widget.direct;

  @override
  void initState() {
    super.initState();
    if (_direct) {
      // Not while building: publishing rebuilds whoever watches the memory.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _memory.fold(chatMemoryKeys(widget.chat!), widget.keys);
        }
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // After the frame: publishing rebuilds the contact screen's rows, and a
    // rebuild may not be scheduled while this tree is being torn down.
    final text = _note.text;
    if (_memory.book.noteFor(widget.keys) != text.trim()) {
      final memory = _memory;
      final keys = widget.keys;
      unawaited(Future(() => memory.saveNote(keys, text)));
    }
    _note.dispose();
    super.dispose();
  }

  /// Writes the field when it differs from what is filed. Called a moment
  /// after typing stops, and before anything else touches the note, so an
  /// accepted fact is added to what was typed rather than to what was there
  /// before.
  void _save() {
    _debounce?.cancel();
    if (_memory.book.noteFor(widget.keys) == _note.text.trim()) return;
    _memory.saveNote(widget.keys, _note.text);
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _save);
    setState(() {});
  }

  void _setText(String text) {
    _note.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _accept(String fact) {
    _save();
    _memory.accept(widget.keys, fact);
    _setText(_memory.book.noteFor(widget.keys));
  }

  Future<void> _promote(String fact) async {
    final people = widget.people;
    final target = people.length == 1
        ? people.single
        : await showWeftPanel<MemoryPerson>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(WeftSpace.lg),
                    child: Text(
                      context.l10n.personMemoryPromoteTo,
                      style: context.text.titleMedium,
                    ),
                  ),
                  // Whoever the fact starts with first: in a group the model
                  // is asked to name the person each fact is about.
                  for (final person in [
                    ...people.where((p) => fact.startsWith(p.name)),
                    ...people.where((p) => !fact.startsWith(p.name)),
                  ])
                    ListTile(
                      leading: const Icon(Icons.person_outline_rounded),
                      title: Text(person.name),
                      onTap: () => Navigator.of(context).pop(person),
                    ),
                ],
              ),
            ),
          );
    if (target == null || !mounted) return;
    _save();
    _memory.promote(widget.keys, target.keys, fact);
  }

  /// Whether the build may ask the model at all; sends the user to Pro when
  /// it may not.
  bool _mayAsk() {
    if (!ref.read(proControllerProvider).unlocks(ProFeature.aiReplies)) {
      pushProScreen(context);
      return false;
    }
    return true;
  }

  Future<void> _learn() async {
    final l10n = context.l10n;
    final chat = widget.chat!;
    if (!_mayAsk()) return;
    _save();
    setState(() => _busy = true);
    PersonFactsResult result;
    final endpoint = ref.read(autoReplyEndpointProvider);
    try {
      result = await learnPersonFacts(
        settings: ref.read(personMemorySettingsProvider),
        endpoint: endpoint,
        memory: _memory,
        chat: chat,
        people: widget.people,
        // As much as the model's window has room for: hundreds of messages
        // on a big one, which the chat has usually not loaded yet.
        messages: await widget.loadMessages!(
          endpoint?.budget.forFeature(AiFeature.learnFacts).maxMessages ??
              kAiContextMessages,
        ),
        client: ref.read(quickMessageClientProvider),
      );
    } on Object {
      result = (outcome: PersonFactsOutcome.failed, changed: 0, status: null);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // Both are fixed by a switch on the memory settings screen.
    final toSettings =
        result.outcome == PersonFactsOutcome.memoryOff ||
        result.outcome == PersonFactsOutcome.encrypted;
    showWeftMessage(
      context,
      action: toSettings
          ? SnackBarAction(label: l10n.settingsTitle, onPressed: _openSettings)
          : null,
      switch (result.outcome) {
        PersonFactsOutcome.learned => l10n.personMemoryLearned(
          result.changed,
          chat.title,
        ),
        PersonFactsOutcome.nothingNew => l10n.personMemoryNothingNew,
        PersonFactsOutcome.memoryOff => l10n.personMemoryLearnOff,
        PersonFactsOutcome.encrypted => l10n.personMemoryLearnEncrypted,
        PersonFactsOutcome.noEndpoint => l10n.quickMessageNoEndpoint(
          l10n.settingsEndpointsTitle,
        ),
        PersonFactsOutcome.nothingToSend => l10n.personMemoryLearnNothing,
        PersonFactsOutcome.failed => switch (result.status) {
          final status? => l10n.personMemoryLearnHttpError(status),
          null => l10n.personMemoryLearnFailed,
        },
        PersonFactsOutcome.timedOut => l10n.personMemoryLearnTimedOut,
        PersonFactsOutcome.cutOff => l10n.personMemoryLearnCutOff,
        PersonFactsOutcome.unreadable => l10n.personMemoryLearnUnreadable,
      },
    );
  }

  Future<void> _condense() async {
    final l10n = context.l10n;
    if (!_mayAsk()) return;
    // Sending the note to the model is what the memory switch is about.
    if (!ref.read(personMemorySettingsProvider).useInAi) {
      showWeftMessage(context, l10n.personMemoryLearnOff);
      return;
    }
    final endpoint = ref.read(autoReplyEndpointProvider);
    if (endpoint == null) {
      showWeftMessage(
        context,
        l10n.quickMessageNoEndpoint(l10n.settingsEndpointsTitle),
      );
      return;
    }
    _save();
    setState(() => _busy = true);
    final short = await condensePersonMemory(
      baseUrl: endpoint.baseUrl,
      model: endpoint.model,
      apiKey: endpoint.apiKey,
      name: widget.person!.name,
      note: _note.text,
      budget: endpoint.budget,
      client: ref.read(quickMessageClientProvider),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _condensed = short;
    });
    if (short == null) showWeftMessage(context, l10n.personMemoryLearnFailed);
  }

  void _undo() {
    _memory.undoAutomatic();
    showWeftMessage(context, context.l10n.personMemoryUndone);
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const PersonMemorySettingsScreen()),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(personMemorySettingsProvider);
    final book = ref.watch(personMemoryProvider);
    final suggestions = _isChat
        ? book.suggestionsFor(widget.keys)
        : const <String>[];
    final learned = [
      for (final f in book.learnedFor(widget.keys))
        if (!f.style) f,
    ];
    // How the user writes here — filed under the chat's rooms — and, for
    // a person, how they write.
    final myStyle = _isChat
        ? book.styleFor(chatMemoryKeys(widget.chat!))
        : null;
    final theirStyle = _isChat && !_direct ? null : book.styleFor(widget.keys);
    final undo = book.undoTouches(widget.keys) ? book.undo : null;
    final hint = _direct
        ? l10n.directMemoryHint
        : _isChat
        ? l10n.groupMemoryHint
        : l10n.personMemoryHint;
    final length = _note.text.trim().length;
    // Only a group member's memory is meant to stay a few lines.
    final short = !_isChat;
    final long = short && length > kPersonMemorySoftLimit;

    Widget progress(IconData icon) => _busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon);

    return Scaffold(
      appBar: WeftAppBar(
        title: Text(
          _direct
              ? l10n.personMemoryScreenTitle(widget.people.first.name)
              : _isChat
              ? l10n.groupMemoryTitle
              : l10n.personMemoryScreenTitle(widget.person!.name),
        ),
      ),
      body: WeftReadingPane(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(
            WeftSpace.lg,
            WeftSpace.md,
            WeftSpace.lg,
            WeftSpace.xxl,
          ),
          children: [
            _Notice(
              icon: settings.useInAi
                  ? Icons.auto_awesome_outlined
                  : Icons.lock_outline_rounded,
              text: settings.useInAi
                  ? l10n.personMemoryOnNotice
                  : l10n.personMemoryOffNotice,
              action: TextButton(
                onPressed: _openSettings,
                child: Text(l10n.personMemorySettingsTitle),
              ),
            ),
            if (undo != null) ...[
              const SizedBox(height: WeftSpace.sm),
              _Notice(
                key: const ValueKey('memory-undo'),
                icon: Icons.history_rounded,
                text: l10n.personMemoryUpdatedAt(memoryDate(context, undo.at)),
                action: TextButton(
                  onPressed: _undo,
                  child: Text(l10n.personMemoryUndo),
                ),
              ),
            ],
            const SizedBox(height: WeftSpace.md),
            TextField(
              key: const ValueKey('memory-note'),
              controller: _note,
              minLines: _isChat ? 8 : 5,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _isChat && !_direct
                    ? l10n.groupMemoryTitle
                    : l10n.personMemoryTitle,
                alignLabelWithHint: true,
                hintText: hint,
                hintMaxLines: 12,
                helperText: short ? l10n.personMemorySharedHint : null,
                helperMaxLines: 3,
                counterText: short ? '$length / $kPersonMemorySoftLimit' : null,
                counterStyle: long
                    ? TextStyle(color: context.colors.error)
                    : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: _changed,
            ),
            const SizedBox(height: WeftSpace.md),
            Wrap(
              spacing: WeftSpace.sm,
              runSpacing: WeftSpace.sm,
              children: [
                if (_isChat)
                  FilledButton.tonalIcon(
                    key: const ValueKey('memory-learn'),
                    onPressed: _busy ? null : _learn,
                    icon: progress(Icons.auto_awesome_rounded),
                    label: Text(l10n.personMemoryLearn),
                  )
                else if (length > 0)
                  FilledButton.tonalIcon(
                    key: const ValueKey('memory-condense'),
                    onPressed: _busy ? null : _condense,
                    icon: progress(Icons.compress_rounded),
                    label: Text(l10n.personMemoryCondense),
                  ),
                if (length == 0)
                  TextButton(
                    onPressed: () {
                      _setText(hint);
                      _changed(hint);
                    },
                    child: Text(l10n.personMemoryUseTemplate),
                  ),
              ],
            ),
            if (myStyle != null) ...[
              const SizedBox(height: WeftSpace.xl),
              _Heading(
                title: l10n.personMemoryStyleTitle,
                hint: l10n.personMemoryMyStyleHint,
              ),
              LearnedFactTile(
                key: const ValueKey('memory-style'),
                memory: _memory,
                keys: chatMemoryKeys(widget.chat!),
                fact: myStyle,
              ),
            ],
            if (theirStyle != null) ...[
              SizedBox(height: myStyle == null ? WeftSpace.xl : WeftSpace.md),
              _Heading(
                title: myStyle == null ? l10n.personMemoryStyleTitle : '',
                hint: l10n.personMemoryTheirStyleHint,
              ),
              LearnedFactTile(
                key: const ValueKey('memory-their-style'),
                memory: _memory,
                keys: widget.keys,
                fact: theirStyle,
              ),
            ],
            if (learned.isNotEmpty) ...[
              const SizedBox(height: WeftSpace.xl),
              _Heading(
                title: l10n.personMemoryLearnedTitle,
                hint: l10n.personMemoryLearnedHint,
              ),
              for (final fact in learned)
                LearnedFactTile(memory: _memory, keys: widget.keys, fact: fact),
            ],
            if (_condensed case final short?) ...[
              const SizedBox(height: WeftSpace.xl),
              _Heading(
                title: l10n.personMemoryCondensed,
                hint: l10n.personMemorySuggestionsHint,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(WeftSpace.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(short),
                      const SizedBox(height: WeftSpace.sm),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: WeftSpace.sm,
                        children: [
                          TextButton(
                            onPressed: () => setState(() => _condensed = null),
                            child: Text(l10n.personMemoryDismiss),
                          ),
                          FilledButton.tonal(
                            onPressed: () {
                              _setText(short);
                              _save();
                              setState(() => _condensed = null);
                            },
                            child: Text(l10n.personMemoryReplace),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: WeftSpace.xl),
              _Heading(
                title: l10n.personMemorySuggestionsTitle,
                hint: l10n.personMemorySuggestionsHint,
              ),
              for (final fact in suggestions)
                _Suggestion(
                  fact: fact,
                  onAccept: () => _accept(fact),
                  onPromote: widget.people.isEmpty || _direct
                      ? null
                      : () => _promote(fact),
                  onDismiss: () => _memory.dismiss(widget.keys, fact),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(
              title,
              style: context.text.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: WeftSpace.xs),
          ],
          Text(
            hint,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
  });

  final IconData icon;
  final String text;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(WeftSpace.md),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.md,
          WeftSpace.md,
          WeftSpace.sm,
          WeftSpace.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: colors.onSurfaceVariant),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    text,
                    style: context.text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            Align(alignment: AlignmentDirectional.centerEnd, child: action),
          ],
        ),
      ),
    );
  }
}

/// A short date as the app's locale writes it: "24 Nov", "24. Nov.".
String memoryDate(BuildContext context, DateTime at) =>
    DateFormat.MMMd(Localizations.localeOf(context).toString()).format(at);

/// Asks for a new wording of [fact], filed under [keys], and saves it —
/// pinned from then on. A style profile may be longer than a fact.
Future<void> editLearnedFact(
  BuildContext context,
  PersonMemoryNotifier memory,
  List<String> keys,
  LearnedFact fact,
) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => _EditFactDialog(fact: fact),
  );
  if (text == null || !context.mounted) return;
  memory.editLearned(keys, fact, text);
}

/// The dialog [editLearnedFact] shows. Its own widget so the field's
/// controller lives until the dialog has finished closing, not only until
/// it has answered.
class _EditFactDialog extends StatefulWidget {
  const _EditFactDialog({required this.fact});

  final LearnedFact fact;

  @override
  State<_EditFactDialog> createState() => _EditFactDialogState();
}

class _EditFactDialogState extends State<_EditFactDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.fact.text,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = widget.fact.style;
    return AlertDialog(
      title: Text(
        style ? l10n.personMemoryEditStyle : l10n.personMemoryEditFact,
      ),
      content: TextField(
        key: const ValueKey('memory-fact-edit'),
        controller: _text,
        autofocus: true,
        maxLines: null,
        maxLength: style ? kStyleMaxChars : kPersonFactMaxChars,
        textCapitalization: TextCapitalization.sentences,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// One fact or style profile the model learned, filed under [keys]: what it
/// says, that it was learned and when — or that the user edited it — until
/// when it is kept when it is temporary, and pin, edit and delete.
class LearnedFactTile extends StatelessWidget {
  const LearnedFactTile({
    super.key,
    required this.memory,
    required this.keys,
    required this.fact,
  });

  final PersonMemoryNotifier memory;
  final List<String> keys;
  final LearnedFact fact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final date = memoryDate(context, fact.at);
    // The last day it is kept: it goes at the midnight after.
    final until = switch (fact.until) {
      final end? => memoryDate(
        context,
        end.subtract(const Duration(milliseconds: 1)),
      ),
      null => null,
    };
    void onPin() => memory.pinLearned(keys, fact, pinned: !fact.pinned);
    void onEdit() => unawaited(editLearnedFact(context, memory, keys, fact));
    void onDelete() => memory.deleteLearned(keys, fact);
    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.md,
          WeftSpace.sm,
          WeftSpace.xs,
          WeftSpace.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fact.text),
                  const SizedBox(height: WeftSpace.xs),
                  Row(
                    children: [
                      Icon(
                        until != null
                            ? Icons.event_outlined
                            : fact.edited
                            ? Icons.edit_outlined
                            : Icons.auto_awesome_outlined,
                        size: 14,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: WeftSpace.xs),
                      Flexible(
                        child: Text(
                          [
                            fact.edited
                                ? l10n.personMemoryEditedAt(date)
                                : l10n.personMemoryLearnedAt(date),
                            if (until != null)
                              fact.past
                                  ? l10n.personMemoryPastUntil(until)
                                  : l10n.personMemoryUntil(until),
                          ].join(' · '),
                          style: context.text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: fact.pinned
                  ? l10n.personMemoryUnpin
                  : l10n.personMemoryPin,
              isSelected: fact.pinned,
              icon: const Icon(Icons.push_pin_outlined),
              selectedIcon: Icon(Icons.push_pin, color: colors.primary),
              onPressed: onPin,
            ),
            IconButton(
              tooltip: l10n.personMemoryEditFact,
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: l10n.personMemoryDeleteFact,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({
    required this.fact,
    required this.onAccept,
    required this.onPromote,
    required this.onDismiss,
  });

  final String fact;
  final VoidCallback onAccept;
  final VoidCallback? onPromote;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.sm),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.md,
          WeftSpace.xs,
          WeftSpace.xs,
          WeftSpace.xs,
        ),
        child: Row(
          children: [
            Expanded(child: Text(fact)),
            IconButton(
              tooltip: l10n.personMemoryDismiss,
              icon: const Icon(Icons.close_rounded),
              onPressed: onDismiss,
            ),
            if (onPromote != null)
              IconButton(
                tooltip: l10n.personMemoryPromote,
                icon: const Icon(Icons.person_add_alt_outlined),
                onPressed: onPromote,
              ),
            IconButton.filledTonal(
              tooltip: l10n.personMemoryAccept,
              icon: const Icon(Icons.check_rounded),
              onPressed: onAccept,
            ),
          ],
        ),
      ),
    );
  }
}

/// A contact screen row for one memory: what the note starts with, or how to
/// begin one, and how many facts are waiting.
class _MemoryTile extends ConsumerWidget {
  const _MemoryTile({
    required this.icon,
    required this.keys,
    required this.empty,
    required this.open,
    this.withSuggestions = false,
  });

  final IconData icon;
  final List<String> keys;
  final String empty;
  final Widget Function() open;
  final bool withSuggestions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final book = ref.watch(personMemoryProvider);
    final note = book.memoryFor(keys);
    final waiting = withSuggestions ? book.suggestionsFor(keys).length : 0;
    return ListTile(
      leading: Icon(icon),
      title: Text(
        note.isEmpty ? empty : note,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: waiting == 0
          ? null
          : Text(
              l10n.personMemorySuggestionCount(waiting),
              style: TextStyle(color: context.colors.primary),
            ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => open())),
    );
  }
}

/// The contact screen's memory sections: for a direct chat one, "About
/// Anna"; for a group "About this group", then "About …" for each person who
/// wrote in it.
class ChatMemorySections extends ConsumerWidget {
  const ChatMemorySections({
    super.key,
    required this.chat,
    required this.header,
  });

  final Chat chat;

  /// The contact screen's own section header, so these read as its sections.
  final Widget Function(String title) header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (!chat.isGroup) {
      final person = directMemoryPerson(ref, chat);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(l10n.personMemoryScreenTitle(person.name)),
          _MemoryTile(
            icon: Icons.person_outline_rounded,
            // What is still filed under the chat's rooms too, until opening
            // it folds that in.
            keys: [...person.keys, ...chatMemoryKeys(chat)],
            empty: l10n.personMemoryEmpty,
            withSuggestions: true,
            open: () => ChatMemoryScreen(chatId: chat.id),
          ),
        ],
      );
    }
    final people =
        ref.watch(chatMemoryPeopleProvider(chat.id)).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header(l10n.groupMemoryTitle),
        _MemoryTile(
          icon: Icons.groups_outlined,
          keys: chatMemoryKeys(chat),
          empty: l10n.groupMemoryEmpty,
          withSuggestions: true,
          open: () => ChatMemoryScreen(chatId: chat.id),
        ),
        for (final person in people) ...[
          header(l10n.personMemoryScreenTitle(person.name)),
          _MemoryTile(
            icon: Icons.person_outline_rounded,
            keys: person.keys,
            empty: l10n.personMemoryEmpty,
            open: () => PersonMemoryScreen(person: person),
          ),
        ],
      ],
    );
  }
}
