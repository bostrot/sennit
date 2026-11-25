import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/saved_messages.dart';
import '../../app/stores.dart';
import 'chat_view.dart';

/// The messages the user saved, newest save first, with a field to find one.
///
/// Every conversation's by default; with [rooms], only those in that
/// conversation's rooms — the list the chat's profile opens. A tap opens the
/// conversation at the message.
class SavedMessagesScreen extends ConsumerStatefulWidget {
  const SavedMessagesScreen({super.key, this.rooms});

  final Set<String>? rooms;

  @override
  ConsumerState<SavedMessagesScreen> createState() =>
      _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends ConsumerState<SavedMessagesScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(SavedMessage saved) {
    final chatId =
        ref.read(chatRepositoryProvider).chatForRoom(saved.roomId)?.id ??
        saved.chatId;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatView(chatId: chatId, initialEventId: saved.eventId),
      ),
    );
  }

  void _remove(SavedMessage saved) {
    final l10n = context.l10n;
    final settings = ref.read(storesProvider).settings;
    final revision = ref.read(settingsRevisionProvider.notifier);
    setMessageSaved(settings, saved, isSaved: false);
    revision.bump();
    showWeftMessage(
      context,
      l10n.savedMessagesRemoved,
      action: SnackBarAction(
        label: l10n.chatMessageSavedUndo,
        onPressed: () {
          setMessageSaved(settings, saved, isSaved: true);
          revision.bump();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final all = filterSavedMessages(
      ref.watch(savedMessagesProvider),
      rooms: widget.rooms,
    );
    final shown = filterSavedMessages(all, query: _query.text);

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.savedMessagesTitle)),
      body: WeftReadingPane(
        maxWidth: 720,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WeftSpace.lg,
                  vertical: WeftSpace.sm,
                ),
                child: WeftLabelledField(
                  label: l10n.savedMessagesSearch,
                  child: TextField(
                    controller: _query,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: l10n.savedMessagesSearch,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(WeftSpace.xl),
                        child: Text(
                          all.isEmpty
                              ? l10n.savedMessagesEmpty
                              : l10n.savedMessagesNoMatch,
                          textAlign: TextAlign.center,
                          style: context.text.bodyMedium?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: context.palette.divider),
                      itemBuilder: (context, index) {
                        final saved = shown[index];
                        final when = DateFormat.yMMMd().add_Hm().format(
                          saved.sentAt,
                        );
                        final attribution = saved.senderName.trim().isEmpty
                            ? when
                            : '${saved.senderName} · $when';
                        return ListTile(
                          title: Text(
                            saved.text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(attribution),
                          onTap: () => _open(saved),
                          trailing: IconButton(
                            icon: const Icon(Icons.bookmark_remove_outlined),
                            tooltip: l10n.messageActionUnsave,
                            onPressed: () => _remove(saved),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
