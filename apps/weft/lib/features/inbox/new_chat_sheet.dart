import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/providers.dart';
import '../chat/chat_view.dart';

/// Starts a conversation that does not exist yet.
///
/// Three ways in, because that is how many kinds of "new chat" this app has:
/// a Matrix user by id, a bridged contact by phone number (the bridge bot is
/// asked to open the portal, which then arrives by sync), and a named Matrix
/// group with invitees.
Future<void> showNewChatSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person_add_alt_rounded),
            title: const Text('New chat'),
            subtitle: const Text(
              'A Matrix user, or a phone number a bridge '
              'can reach',
            ),
            onTap: () {
              Navigator.of(sheet).pop();
              unawaited(_newDirectChat(context, ref));
            },
          ),
          ListTile(
            leading: const Icon(Icons.group_add_rounded),
            title: const Text('New group'),
            subtitle: const Text(
              'A named Matrix room with the people you '
              'pick',
            ),
            onTap: () {
              Navigator.of(sheet).pop();
              unawaited(_newGroup(context, ref));
            },
          ),
        ],
      ),
    ),
  );
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
