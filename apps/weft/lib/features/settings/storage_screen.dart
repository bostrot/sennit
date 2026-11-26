import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/attachments/attachment_byte_cache.dart';
import '../../services/attachments/local_media_storage.dart';
import 'settings_section.dart';

/// Whether pictures download by themselves, and how much room they may take.
///
/// Both are this device's alone and never sync: a phone on mobile data and a
/// laptop on fibre want different answers, and the space is this disk's.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  /// Bytes in use, or null while they are still being counted.
  int? _used;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    final used = await ref.read(localMediaStorageProvider).usedBytes();
    if (mounted) setState(() => _used = used);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsRevisionProvider);
    final l10n = context.l10n;
    final settings = ref.watch(storesProvider).settings;
    final used = _used;
    final limitMb =
        settings.getInt(WeftSettings.mediaLimitMb) ?? kDefaultMediaLimitMb;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsStorageTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            SwitchListTile(
              title: Text(l10n.storageAutoDownloadTitle),
              subtitle: Text(l10n.storageAutoDownloadSubtitle),
              value: mediaAutoDownload(settings),
              onChanged: (value) {
                settings.setBool(WeftSettings.mediaAutoDownload, value: value);
                ref.read(settingsRevisionProvider.notifier).bump();
              },
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: l10n.storageSpaceTitle,
              subtitle: l10n.storageSpaceSubtitle,
            ),
            Text(
              used == null
                  ? l10n.storageCounting
                  : l10n.storageUsed(formatAttachmentSize(used)),
              style: context.text.titleMedium,
            ),
            const SizedBox(height: WeftSpace.lg),
            Text(l10n.storageLimitTitle, style: context.text.labelLarge),
            const SizedBox(height: WeftSpace.sm),
            Wrap(
              spacing: WeftSpace.sm,
              runSpacing: WeftSpace.sm,
              children: [
                for (final mb in kMediaLimitChoicesMb)
                  ChoiceChip(
                    label: Text(
                      mb == 0 ? l10n.storageLimitNone : _megabytes(mb),
                    ),
                    selected: limitMb == mb,
                    onSelected: (_) => _setLimit(mb),
                  ),
              ],
            ),
            const SizedBox(height: WeftSpace.lg),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(l10n.storageClear),
                onPressed: _clearing || used == 0 ? null : _clear,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "2 GB" rather than "2.0 GB": these are round numbers someone picks.
  static String _megabytes(int mb) =>
      formatAttachmentSize(mb * 1024 * 1024).replaceFirst('.0 ', ' ');

  Future<void> _setLimit(int mb) async {
    final settings = ref.read(storesProvider).settings;
    settings.setInt(WeftSettings.mediaLimitMb, mb);
    ref.read(settingsRevisionProvider.notifier).bump();
    // A smaller limit means the oldest files go now, not at the next launch.
    await ref.read(localMediaStorageProvider).trimTo(mediaLimitBytes(settings));
    await _measure();
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    final freed = await ref.read(localMediaStorageProvider).clear();
    // Pictures already decoded for the timeline go too, so clearing reads as
    // clearing when the user goes back to a chat.
    ref.read(attachmentByteCacheProvider).clear();
    if (!mounted) return;
    setState(() => _clearing = false);
    showWeftMessage(
      context,
      context.l10n.storageCleared(formatAttachmentSize(freed)),
    );
    await _measure();
  }
}
