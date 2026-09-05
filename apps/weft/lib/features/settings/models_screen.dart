import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/models/model_catalog.dart';
import '../../services/models/model_installer.dart';

final modelInstallerProvider = Provider<ModelInstaller>((ref) {
  final installer = ModelInstaller();
  ref.onDispose(installer.dispose);
  return installer;
});

/// Local models: download, progress, delete.
///
/// Downloads run through the OS download service, so they continue with the
/// app backgrounded and show a system notification — leaving this screen, or
/// the app, does not lose a 190 MB download at 60%.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  StreamSubscription<String>? _updates;

  @override
  void initState() {
    super.initState();
    final installer = ref.read(modelInstallerProvider);
    _updates = installer.updates.listen((_) {
      if (mounted) setState(() {});
    });
    installer.refresh();
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  String? get _selectedVoiceModel => ref
      .read(storesProvider)
      .settings
      .getString(WeftSettings.transcriptionLocalModel);

  String? get _selectedSearchModel => ref
      .read(storesProvider)
      .settings
      .getString(WeftSettings.embeddingLocalModel);

  /// Selecting a model makes on-device transcription take precedence over any
  /// configured endpoint — the private option wins once it is available.
  void _useForVoice(String? id) {
    ref
        .read(storesProvider)
        .settings
        .setString(WeftSettings.transcriptionLocalModel, id ?? '');
    ref.read(settingsRevisionProvider.notifier).bump();
    setState(() {});
  }

  /// Same rule for search, with one extra consequence: vectors from different
  /// models share no coordinate space, so switching what embeds also wipes the
  /// stored vectors and re-queues every message for the new model.
  void _useForSearch(String? id) {
    final stores = ref.read(storesProvider);
    final previous = stores.settings.getString(
      WeftSettings.embeddingLocalModel,
    );
    if ((previous ?? '') == (id ?? '')) return;

    stores.settings.setString(WeftSettings.embeddingLocalModel, id ?? '');
    stores.search.reindexEmbeddings();
    ref.read(settingsRevisionProvider.notifier).bump();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final installer = ref.watch(modelInstallerProvider);
    ref.watch(settingsRevisionProvider);

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.modelsTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            Text(
              context.l10n.modelsIntro,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            for (final spec in ModelCatalog.all)
              _ModelCard(
                spec: spec,
                state: installer.stateOf(spec),
                selectedForVoice: _selectedVoiceModel == spec.id,
                selectedForSearch: _selectedSearchModel == spec.id,
                onInstall: () => installer.install(spec),
                onCancel: () => installer.cancel(spec),
                onDelete: () async {
                  if (_selectedVoiceModel == spec.id) _useForVoice(null);
                  if (_selectedSearchModel == spec.id) _useForSearch(null);
                  await installer.delete(spec);
                },
                onUseForVoice: spec.capability == ModelCapability.speechToText
                    ? () => _useForVoice(
                        _selectedVoiceModel == spec.id ? null : spec.id,
                      )
                    : null,
                onUseForSearch: spec.capability == ModelCapability.embedding
                    ? () => _useForSearch(
                        _selectedSearchModel == spec.id ? null : spec.id,
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.state,
    required this.selectedForVoice,
    required this.selectedForSearch,
    required this.onInstall,
    required this.onCancel,
    required this.onDelete,
    this.onUseForVoice,
    this.onUseForSearch,
  });

  final ModelSpec spec;
  final ModelState state;
  final bool selectedForVoice;
  final bool selectedForSearch;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  /// Null for models that are not speech-to-text.
  final VoidCallback? onUseForVoice;

  /// Null for models that are not embedding models.
  final VoidCallback? onUseForSearch;

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  @override
  Widget build(BuildContext context) {
    final progress = spec.totalBytes == 0
        ? 0.0
        : (state.receivedBytes / spec.totalBytes).clamp(0.0, 1.0);

    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // The glyph is the only thing on the card distinguishing a
                // model that does search from one that does speech, and one
                // squiggle is not distinguishable from another by ear.
                Semantics(
                  label: spec.capability == ModelCapability.embedding
                      ? context.l10n.modelsSearchModel
                      : context.l10n.modelsSpeechModel,
                  child: Icon(
                    spec.capability == ModelCapability.embedding
                        ? Icons.psychology_outlined
                        : Icons.graphic_eq_rounded,
                    size: 20,
                  ),
                ),
                const SizedBox(width: WeftSpace.sm),
                Expanded(
                  child: Text(
                    spec.displayName,
                    style: context.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _mb(spec.totalBytes),
                  style: context.text.labelSmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.xs),
            Text(spec.description, style: context.text.bodySmall),
            const SizedBox(height: WeftSpace.md),
            switch (state.phase) {
              ModelPhase.downloading => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A value, not a live region: a download reports progress
                  // many times a second, and a live bar would say all of it.
                  // The user asks "how far along?" by navigating here; the
                  // *end* of the download is what gets announced, below.
                  Semantics(
                    label: context.l10n.modelsDownloading(spec.displayName),
                    value: context.l10n.uploadPercent((progress * 100).round()),
                    child: LinearProgressIndicator(value: progress),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  Row(
                    children: [
                      Text(
                        context.l10n.modelsBytesOf(
                          _mb(state.receivedBytes),
                          _mb(spec.totalBytes),
                        ),
                        style: context.text.labelSmall,
                      ),
                      const Spacer(),
                      NamedButton(
                        label: context.l10n.modelsCancelDownload(
                          spec.displayName,
                        ),
                        onPressed: onCancel,
                        child: TextButton(
                          onPressed: onCancel,
                          child: Text(context.l10n.commonCancel),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              ModelPhase.installed => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      // Live: a download ending is a progress bar disappearing,
                      // which is nothing at all if you were not watching it.
                      Semantics(
                        liveRegion: true,
                        label: context.l10n.modelsInstalledLive(
                          spec.displayName,
                        ),
                        excludeSemantics: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 18,
                              color: context.palette.online,
                            ),
                            const SizedBox(width: WeftSpace.sm),
                            Text(context.l10n.modelsInstalled),
                          ],
                        ),
                      ),
                      const Spacer(),
                      NamedButton(
                        label: context.l10n.modelsDelete(spec.displayName),
                        onPressed: onDelete,
                        child: TextButton(
                          onPressed: onDelete,
                          child: Text(context.l10n.commonDelete),
                        ),
                      ),
                    ],
                  ),
                  if (onUseForVoice != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(context.l10n.modelsUseForVoiceTitle),
                      subtitle: Text(context.l10n.modelsUseForVoiceSubtitle),
                      value: selectedForVoice,
                      onChanged: (_) => onUseForVoice!(),
                    ),
                  if (onUseForSearch != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(context.l10n.modelsUseForSearchTitle),
                      subtitle: Text(context.l10n.modelsUseForSearchSubtitle),
                      value: selectedForSearch,
                      onChanged: (_) => onUseForSearch!(),
                    ),
                ],
              ),
              ModelPhase.failed => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    label: context.l10n.modelsFailedLive(
                      spec.displayName,
                      state.error ?? '',
                    ),
                    excludeSemantics: true,
                    child: Text(
                      state.error ?? context.l10n.modelsDownloadFailed,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  NamedButton(
                    label: context.l10n.modelsRetryDownload(spec.displayName),
                    onPressed: onInstall,
                    child: FilledButton.tonal(
                      onPressed: onInstall,
                      child: Text(context.l10n.modelsRetryResumes),
                    ),
                  ),
                ],
              ),
              // Five cards, five buttons reading "Download", one of which is a
              // 1.5 GB file.
              ModelPhase.notInstalled => Align(
                alignment: AlignmentDirectional.centerEnd,
                child: NamedButton(
                  label: context.l10n.modelsDownloadNamed(
                    spec.displayName,
                    _mb(spec.totalBytes),
                  ),
                  onPressed: onInstall,
                  child: FilledButton.tonalIcon(
                    onPressed: onInstall,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(context.l10n.modelsDownload),
                  ),
                ),
              ),
            },
          ],
        ),
      ),
    );
  }
}
