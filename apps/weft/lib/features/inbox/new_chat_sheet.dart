import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/providers.dart';
import '../../app/stores.dart';
import '../../services/contacts/device_contacts.dart';
import '../chat/chat_view.dart';

/// Starts a conversation — from a readable list of people, not a form.
///
/// The list is who the user already talks to (their existing conversations,
/// by name and face) plus the device address book when they opted into it,
/// searchable together. Identifiers stay out of sight: a Matrix id or a raw
/// number lives behind the one "By ID or number" row at the bottom for the
/// rare person no list has.
Future<void> showNewChatSheet(BuildContext context, WidgetRef ref) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const NewChatScreen()));
}

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(chatRepositoryProvider);
    final query = _search.text.trim().toLowerCase();

    // People the user already talks to: their DM conversations, by name.
    final chats =
        (ref.watch(chatsProvider).value ?? const <Chat>[])
            .where(
              (c) =>
                  !c.isGroup &&
                  !c.archived &&
                  !repository.serviceChatIds.contains(c.id) &&
                  !c.title.toLowerCase().contains('status broadcast') &&
                  (query.isEmpty || c.title.toLowerCase().contains(query)),
            )
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );

    // The address book, minus the people already covered above. The cache is
    // the one the address-book-names preference maintains; without that
    // preference the section simply is not there.
    final knownTitles = {for (final c in chats) c.title.toLowerCase()};
    Map<String, Object?>? contactsJson;
    try {
      contactsJson = ref
          .read(storesProvider)
          .settings
          .getJson(kContactNamesCacheKey);
    } on Object {
      contactsJson = null;
    }
    final fromBook = <(String name, String phone)>[];
    if (contactsJson != null) {
      final seen = <String>{};
      for (final entry in contactsJson.entries) {
        final name = entry.value;
        if (name is! String || name.trim().isEmpty) continue;
        final lower = name.toLowerCase();
        if (knownTitles.contains(lower) || !seen.add(lower)) continue;
        if (query.isNotEmpty && !lower.contains(query)) continue;
        fromBook.add((name, entry.key));
      }
      fromBook.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    }

    final headers = ref.watch(mediaHeadersProvider);

    return Scaffold(
      appBar: WeftAppBar(title: const Text('New chat')),
      body: WeftReadingPane(
        maxWidth: 560,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                WeftSpace.lg,
                WeftSpace.sm,
                WeftSpace.lg,
                WeftSpace.sm,
              ),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Search people',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.group_add_rounded),
              title: const Text('New group'),
              onTap: () => unawaited(_newGroup(context, ref)),
            ),
            if (chats.isNotEmpty) _header(context, 'Your conversations'),
            for (final chat in chats)
              ListTile(
                leading: WeftAvatar(
                  label: chat.title,
                  imageUrl: chat.avatarUrl,
                  imageHeaders: headers,
                  networks: chat.networks,
                  size: 40,
                ),
                title: Text(chat.title),
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatView(chatId: chat.id),
                  ),
                ),
              ),
            if (fromBook.isNotEmpty) _header(context, 'From your address book'),
            for (final (name, phone) in fromBook)
              ListTile(
                leading: WeftAvatar(label: name, size: 40),
                title: Text(name),
                onTap: () => unawaited(_startWithNumber(name, phone)),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: const Text('By ID or number'),
              subtitle: const Text('A Matrix ID, or a number no list has'),
              onTap: () => unawaited(_newDirectChat(context, ref)),
            ),
            const SizedBox(height: WeftSpace.xl),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String title) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(
      WeftSpace.lg,
      WeftSpace.lg,
      WeftSpace.lg,
      WeftSpace.xs,
    ),
    child: Text(
      title,
      style: context.text.labelLarge?.copyWith(
        color: context.colors.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  /// A person from the address book: pick the bridge, ask its bot for the
  /// portal. The name stays on screen; the number never has to be.
  Future<void> _startWithNumber(String name, String phone) async {
    final repository = ref.read(chatRepositoryProvider);
    final bridged = repository.availableNetworks
        .where(
          (n) =>
              n != ChatNetwork.matrix &&
              n != ChatNetwork.sms &&
              n != ChatNetwork.unknown,
        )
        .toList();
    if (bridged.isEmpty) {
      showWeftMessage(context, 'No bridge is connected to reach $name over.');
      return;
    }

    final network = bridged.length == 1
        ? bridged.single
        : await showWeftPanel<ChatNetwork>(
            context: context,
            showDragHandle: true,
            builder: (sheet) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(WeftSpace.md),
                    child: Text(
                      'Reach $name over…',
                      style: context.text.titleSmall,
                    ),
                  ),
                  for (final n in bridged)
                    ListTile(
                      leading: Icon(
                        Icons.circle,
                        size: 14,
                        color: context.palette.networkColor(n),
                      ),
                      title: Text(n.label),
                      onTap: () => Navigator.of(sheet).pop(n),
                    ),
                ],
              ),
            ),
          );
    if (network == null || !mounted) return;

    final sent = await repository.startBridgeChat(network, '+$phone');
    if (!mounted) return;
    showWeftMessage(
      context,
      sent
          ? 'Asked the ${network.label} bridge to open a chat with $name — '
                'it will appear in the inbox in a moment.'
          : 'No ${network.label} bridge is connected.',
    );
  }
}

Future<void> _newDirectChat(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(chatRepositoryProvider);
  final bridged = repository.availableNetworks
      .where(
        (n) =>
            n != ChatNetwork.matrix &&
            n != ChatNetwork.sms &&
            n != ChatNetwork.unknown,
      )
      .toList();

  final input = TextEditingController();
  var network = bridged.firstOrNull;
  final result = await showDialog<(String, ChatNetwork?)>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) {
        final text = input.text.trim();
        final isMatrixId = text.startsWith('@') && text.contains(':');
        return AlertDialog(
          title: const Text('New chat'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: input,
                autofocus: true,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '@user:server or phone number',
                  hintText: '@anna:matrix.org · +49151…',
                ),
              ),
              if (!isMatrixId && bridged.isNotEmpty) ...[
                const SizedBox(height: WeftSpace.md),
                Text(
                  'A phone number is opened through the bridge:',
                  style: Theme.of(dialog).textTheme.bodySmall,
                ),
                const SizedBox(height: WeftSpace.xs),
                Wrap(
                  spacing: WeftSpace.sm,
                  children: [
                    for (final n in bridged)
                      ChoiceChip(
                        label: Text(n.label),
                        selected: network == n,
                        onSelected: (_) => setState(() => network = n),
                      ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: text.isEmpty
                  ? null
                  : () => Navigator.of(
                      dialog,
                    ).pop((text, isMatrixId ? null : network)),
              child: const Text('Start'),
            ),
          ],
        );
      },
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), input.dispose);
  if (result == null || !context.mounted) return;
  final (identifier, via) = result;

  if (via == null) {
    // Matrix: the room exists as soon as the call returns; open it.
    try {
      final chatId = await repository.createDirectChat(identifier);
      if (chatId == null || !context.mounted) return;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => ChatView(chatId: chatId)),
        ),
      );
    } on Object catch (error) {
      if (context.mounted) {
        showWeftMessage(context, 'That chat could not be started: $error');
      }
    }
    return;
  }

  // Bridged: the bot resolves the number and the portal arrives by sync.
  final sent = await repository.startBridgeChat(via, identifier);
  if (!context.mounted) return;
  showWeftMessage(
    context,
    sent
        ? 'Asked the ${via.label} bridge to open a chat with $identifier — '
              'it will appear in the inbox in a moment.'
        : 'No ${via.label} bridge is connected.',
  );
}

Future<void> _newGroup(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(chatRepositoryProvider);
  // People this account can invite to a Matrix room: matrix-native handles.
  final candidates = repository.identityGraph.handles
      .where(
        (h) => h.network == ChatNetwork.matrix && h.matrixUserId.isNotEmpty,
      )
      .toList();

  final name = TextEditingController();
  final manual = TextEditingController();
  final selected = <String>{};
  final result = await showDialog<(String, List<String>)>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: const Text('New group'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Group name'),
                ),
                const SizedBox(height: WeftSpace.md),
                if (candidates.isNotEmpty) ...[
                  Text('Invite:', style: Theme.of(dialog).textTheme.bodySmall),
                  for (final handle in candidates)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        handle.displayName ?? handle.matrixUserId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: selected.contains(handle.matrixUserId),
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          selected.add(handle.matrixUserId);
                        } else {
                          selected.remove(handle.matrixUserId);
                        }
                      }),
                    ),
                ],
                TextField(
                  controller: manual,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'More Matrix IDs (comma-separated)',
                    hintText: '@anna:matrix.org, @ben:example.org',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: name.text.trim().isEmpty
                ? null
                : () => Navigator.of(dialog).pop((
                    name.text.trim(),
                    [
                      ...selected,
                      ...manual.text
                          .split(',')
                          .map((id) => id.trim())
                          .where(
                            (id) => id.startsWith('@') && id.contains(':'),
                          ),
                    ],
                  )),
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), () {
    name.dispose();
    manual.dispose();
  });
  if (result == null || !context.mounted) return;

  try {
    final chatId = await repository.createGroupChat(result.$1, result.$2);
    if (chatId == null || !context.mounted) return;
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ChatView(chatId: chatId))),
    );
  } on Object catch (error) {
    if (context.mounted) {
      showWeftMessage(context, 'The group could not be created: $error');
    }
  }
}
