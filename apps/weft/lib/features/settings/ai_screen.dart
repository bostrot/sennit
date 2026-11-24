import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import 'auto_reply_screen.dart';
import 'endpoints_screen.dart';
import 'models_screen.dart';
import 'person_memory_settings_screen.dart';
import 'quick_messages_screen.dart';

/// Every AI setting behind one door.
///
/// Endpoints, local models and auto-reply used to be three rows on the main
/// settings list, and which of them held "where does the model run" was a
/// guess. They are still three screens — each is long enough to deserve its
/// own — but there is now exactly one place to start looking.
class AiSettingsScreen extends StatelessWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required Widget screen,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => screen)),
      );
    }

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsAiTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.only(bottom: WeftSpace.xxl),
          children: [
            tile(
              icon: Icons.manage_search_rounded,
              title: l10n.settingsEndpointsTitle,
              subtitle: l10n.settingsEndpointsSubtitle,
              screen: const EndpointsScreen(),
            ),
            tile(
              icon: Icons.download_for_offline_outlined,
              title: l10n.settingsModelsTitle,
              subtitle: l10n.settingsModelsSubtitle,
              screen: const ModelsScreen(),
            ),
            tile(
              icon: Icons.smart_toy_outlined,
              title: l10n.settingsAutoReplyTitle,
              subtitle: l10n.settingsAutoReplySubtitle,
              screen: const AutoReplyScreen(),
            ),
            tile(
              icon: Icons.bolt_rounded,
              title: l10n.quickMessageSheetTitle,
              subtitle: l10n.quickMessagesSettingsSubtitle,
              screen: const QuickMessagesScreen(),
            ),
            tile(
              icon: Icons.sticky_note_2_outlined,
              title: l10n.personMemorySettingsTitle,
              subtitle: l10n.personMemorySettingsSubtitle,
              screen: const PersonMemorySettingsScreen(),
            ),
          ],
        ),
      ),
    );
  }
}
