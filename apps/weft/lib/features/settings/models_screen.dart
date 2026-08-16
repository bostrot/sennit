import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_store/weft_store.dart';

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

  @override
  Widget build(BuildContext context) {
    final installer = ref.watch(modelInstallerProvider);
    ref.watch(settingsRevisionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Local models')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          Text(
            'Run search embeddings and voice transcription on this device '
            'instead of an endpoint — nothing leaves the phone. Downloads are '
            'large; they continue in the background with a notification, '
            'resume if interrupted, and it is safe to leave the app.',
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
              onInstall: () => installer.install(spec),
              onCancel: () => installer.cancel(spec),
              onDelete: () async {
                if (_selectedVoiceModel == spec.id) _useForVoice(null);
                await installer.delete(spec);
              },
              onUseForVoice: spec.capability == ModelCapability.speechToText
                  ? () => _useForVoice(
                      _selectedVoiceModel == spec.id ? null : spec.id,
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.state,
    required this.selectedForVoice,
    required this.onInstall,
    required this.onCancel,
    required this.onDelete,
    this.onUseForVoice,
  });

  final ModelSpec spec;
  final ModelState state;
  final bool selectedForVoice;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  /// Null for models that are not speech-to-text.
  final VoidCallback? onUseForVoice;

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
                Icon(
                  spec.capability == ModelCapability.embedding
                      ? Icons.psychology_outlined
                      : Icons.graphic_eq_rounded,
                  size: 20,
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
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: WeftSpace.sm),
                  Row(
                    children: [
                      Text(
                        '${_mb(state.receivedBytes)} of ${_mb(spec.totalBytes)}',
                        style: context.text.labelSmall,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onCancel,
                        child: const Text('Cancel'),
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
                      Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: context.palette.online,
                      ),
                      const SizedBox(width: WeftSpace.sm),
                      const Text('Installed'),
                      const Spacer(),
                      TextButton(
                        onPressed: onDelete,
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                  if (onUseForVoice != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Use for voice messages'),
                      subtitle: const Text(
                        'Transcribes on this device instead of your endpoint.',
                      ),
                      value: selectedForVoice,
                      onChanged: (_) => onUseForVoice!(),
                    ),
                ],
              ),
              ModelPhase.failed => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.error ?? 'Download failed',
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.error,
                    ),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  FilledButton.tonal(
                    onPressed: onInstall,
                    child: const Text('Retry (resumes)'),
                  ),
                ],
              ),
              ModelPhase.notInstalled => Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onInstall,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download'),
                ),
              ),
            },
          ],
        ),
      ),
    );
  }
}
