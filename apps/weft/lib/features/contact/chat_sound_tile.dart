import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/localisation.dart';
import '../../app/notification_providers.dart';
import '../../services/notifications/chat_sound_settings.dart';

/// How one chat's notifications sound: normally, or shown without a sound.
///
/// Silent is Sennit's own and works everywhere. Picking a *different* sound is
/// Android's: it keeps one per conversation in its own settings, so the sheet
/// opens that page rather than keeping a second copy of the choice here.
class ChatSoundTile extends ConsumerWidget {
  const ChatSoundTile({required this.chat, super.key});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final silent = ref.watch(
      notificationPolicyProvider.select((p) => p.overrideFor(chat.id).silent),
    );
    return ListTile(
      leading: Icon(
        silent ? Icons.volume_off_outlined : Icons.volume_up_outlined,
      ),
      title: Text(context.l10n.chatSoundTitle),
      subtitle: Text(
        silent ? context.l10n.chatSoundSilent : context.l10n.chatSoundDefault,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showWeftPanel<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => _ChatSoundSheet(chat: chat),
      ),
    );
  }
}

class _ChatSoundSheet extends ConsumerWidget {
  const _ChatSoundSheet({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final silent = ref.watch(
      notificationPolicyProvider.select((p) => p.overrideFor(chat.id).silent),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: WeftSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
              child: Text(
                l10n.chatSoundTitle,
                style: context.text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.sm),
            RadioGroup<bool>(
              groupValue: silent,
              onChanged: (next) {
                if (next == null) return;
                ref
                    .read(notificationPolicyProvider.notifier)
                    .setChatSilent(chat.id, silent: next);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: false,
                    title: Text(l10n.chatSoundDefault),
                  ),
                  RadioListTile<bool>(
                    value: true,
                    title: Text(l10n.chatSoundSilent),
                    subtitle: Text(l10n.chatSoundSilentSubtitle),
                  ),
                ],
              ),
            ),
            if (canChooseChatSound)
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: Text(l10n.chatSoundChoose),
                subtitle: Text(l10n.chatSoundChooseSubtitle),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => openChatSoundSettings(chat),
              ),
          ],
        ),
      ),
    );
  }
}
