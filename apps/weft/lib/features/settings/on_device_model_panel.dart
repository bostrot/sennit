import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/on_device_llm_providers.dart';
import '../../services/ai/on_device/device_memory.dart';
import '../../services/ai/on_device/on_device_llm.dart';
import '../../services/ai/on_device/on_device_models.dart';
import '../../services/ai/on_device/qwen_chat_template.dart';
import '../../services/models/model_installer.dart';
import 'models_screen.dart' show modelInstallerProvider;

/// The "On this device" half of the AI settings: which model, its download,
/// the memory check, the context window and a speed test.
///
/// Holds no settings of its own — the endpoints screen saves them with
/// everything else — but the downloads are real the moment they are tapped:
/// a gigabyte is not something to start only on Save.
class OnDeviceModelPanel extends ConsumerStatefulWidget {
  const OnDeviceModelPanel({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.mobileData,
    required this.onMobileData,
    required this.contextField,
    this.ramBytes,
  });

  /// The model picked, saved with the screen.
  final OnDeviceLlmSpec selected;
  final ValueChanged<OnDeviceLlmSpec> onSelect;

  /// Whether downloads may use mobile data.
  final bool mobileData;
  final ValueChanged<bool> onMobileData;

  /// The context window field's controller; empty for the default.
  final TextEditingController contextField;

  /// The device's memory; read from the device when null.
  final int? ramBytes;

  @override
  ConsumerState<OnDeviceModelPanel> createState() => _OnDeviceModelPanelState();
}

class _OnDeviceModelPanelState extends ConsumerState<OnDeviceModelPanel> {
  StreamSubscription<String>? _updates;
  late final int? _ram = widget.ramBytes ?? deviceMemoryBytes();
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final installer = ref.read(modelInstallerProvider);
    _updates = installer.updates.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(installer.refresh());
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  static String _size(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 1000
        ? '${(mb / 1024).toStringAsFixed(2)} GB'
        : '${mb.round()} MB';
  }

  String _description(BuildContext context, OnDeviceLlmSpec spec) {
    final l10n = context.l10n;
    return spec.id == OnDeviceLlmSpec.ternaryBonsai2b.id
        ? l10n.endpointsOnDeviceSmallModel
        : l10n.endpointsOnDeviceLargeModel;
  }

  Future<void> _delete(OnDeviceLlmSpec spec) async {
    // The file goes; the memory it is mapped into must go first.
    await ref.read(onDeviceLlmProvider)?.unload();
    await ref.read(modelInstallerProvider).delete(spec.model);
  }

  Future<void> _test() async {
    final llm = ref.read(onDeviceLlmProvider);
    if (llm == null) return;
    final l10n = context.l10n;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    String result;
    try {
      final answer = await llm.complete(
        modelId: widget.selected.id,
        messages: const [
          ChatTurn('user', 'Write one short, friendly sentence about rain.'),
        ],
        maxTokens: 48,
      );
      result = l10n.endpointsOnDeviceTestResult(
        answer.tokensPerSecond.toStringAsFixed(1),
        (answer.firstTokenTime.inMilliseconds / 1000).toStringAsFixed(1),
      );
    } on OnDeviceLlmException catch (error) {
      result = error.failure == OnDeviceFailure.notInstalled
          ? l10n.endpointsOnDeviceNotDownloaded
          : l10n.endpointsOnDeviceTestFailed(
              error.detail ?? error.failure.name,
            );
    } on Object catch (error) {
      result = l10n.endpointsOnDeviceTestFailed('$error');
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final installer = ref.watch(modelInstallerProvider);
    final ram = _ram;
    final cap = onDeviceContextCap(widget.selected, ram);
    final selectedState = installer.stateOf(widget.selected.model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.endpointsOnDeviceIntro, style: context.text.bodySmall),
        if (ram != null) ...[
          const SizedBox(height: WeftSpace.xs),
          Text(
            l10n.endpointsOnDeviceMemory(
              (ram / (1024 * 1024 * 1024)).toStringAsFixed(1),
            ),
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: WeftSpace.md),
        RadioGroup<String>(
          groupValue: widget.selected.id,
          onChanged: (id) {
            final spec = OnDeviceLlmSpec.byId(id);
            if (spec != null) widget.onSelect(spec);
          },
          child: Column(
            children: [
              for (final spec in OnDeviceLlmSpec.all)
                _ModelTile(
                  spec: spec,
                  state: installer.stateOf(spec.model),
                  size: _size(spec.weightBytes),
                  description: _description(context, spec),
                  fit: ramFitFor(spec, ram),
                  waitsForWifi: !widget.mobileData,
                  onInstall: () => installer.install(
                    spec.model,
                    wifiOnly: !widget.mobileData,
                  ),
                  onCancel: () => installer.cancel(spec.model),
                  onDelete: () => _delete(spec),
                ),
            ],
          ),
        ),
        SwitchListTile(
          key: const ValueKey('on-device-mobile-data'),
          title: Text(l10n.endpointsOnDeviceMobileDataTitle),
          subtitle: Text(l10n.endpointsOnDeviceMobileDataSubtitle),
          value: widget.mobileData,
          onChanged: widget.onMobileData,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: WeftSpace.sm),
        TextField(
          key: const ValueKey('on-device-context'),
          controller: widget.contextField,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.endpointsContextField,
            hintText: math.min(kOnDeviceDefaultContextTokens, cap).toString(),
            helperText: l10n.endpointsOnDeviceContextHelper(cap),
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: WeftSpace.md),
        Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('on-device-test'),
              onPressed: _testing || selectedState.phase != ModelPhase.installed
                  ? null
                  : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.speed_rounded, size: 16),
              label: Text(l10n.endpointsOnDeviceTest),
            ),
            const SizedBox(width: WeftSpace.md),
            if (_testResult != null)
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _testResult!,
                    style: context.text.bodySmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.spec,
    required this.state,
    required this.size,
    required this.description,
    required this.fit,
    required this.waitsForWifi,
    required this.onInstall,
    required this.onCancel,
    required this.onDelete,
  });

  final OnDeviceLlmSpec spec;
  final ModelState state;
  final String size;
  final String description;
  final OnDeviceRamFit fit;
  final bool waitsForWifi;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = spec.model.displayName;
    final total = spec.weightBytes;
    final progress = total == 0
        ? 0.0
        : (state.receivedBytes / total).clamp(0.0, 1.0);
    String mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';
    final warning = switch (fit) {
      OnDeviceRamFit.tooLittle => l10n.endpointsOnDeviceRamTooLittle,
      OnDeviceRamFit.tight => l10n.endpointsOnDeviceRamTight,
      _ => null,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.sm,
          WeftSpace.sm,
          WeftSpace.lg,
          WeftSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioListTile<String>(
              value: spec.id,
              contentPadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: context.text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    size,
                    style: context.text.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              subtitle: Text(description, style: context.text.bodySmall),
            ),
            if (warning != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: WeftSpace.sm,
                  bottom: WeftSpace.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.memory_rounded,
                      size: 16,
                      color: fit == OnDeviceRamFit.tooLittle
                          ? context.colors.error
                          : context.colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: WeftSpace.sm),
                    Expanded(
                      child: Text(
                        warning,
                        style: context.text.bodySmall?.copyWith(
                          color: fit == OnDeviceRamFit.tooLittle
                              ? context.colors.error
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: WeftSpace.sm),
              child: switch (state.phase) {
                ModelPhase.downloading => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      label: l10n.modelsDownloading(name),
                      value: l10n.uploadPercent((progress * 100).round()),
                      child: LinearProgressIndicator(value: progress),
                    ),
                    const SizedBox(height: WeftSpace.sm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            state.receivedBytes == 0 && waitsForWifi
                                ? l10n.endpointsOnDeviceWaitsForWifi
                                : l10n.modelsBytesOf(
                                    mb(state.receivedBytes),
                                    mb(total),
                                  ),
                            style: context.text.labelSmall,
                          ),
                        ),
                        NamedButton(
                          label: l10n.modelsCancelDownload(name),
                          onPressed: onCancel,
                          child: TextButton(
                            onPressed: onCancel,
                            child: Text(l10n.commonCancel),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                ModelPhase.installed => Row(
                  children: [
                    Semantics(
                      liveRegion: true,
                      label: l10n.modelsInstalledLive(name),
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
                          Text(l10n.modelsInstalled),
                        ],
                      ),
                    ),
                    const Spacer(),
                    NamedButton(
                      label: l10n.modelsDelete(name),
                      onPressed: onDelete,
                      child: TextButton(
                        onPressed: onDelete,
                        child: Text(l10n.commonDelete),
                      ),
                    ),
                  ],
                ),
                ModelPhase.failed => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      label: l10n.modelsFailedLive(name, state.error ?? ''),
                      excludeSemantics: true,
                      child: Text(
                        state.error ?? l10n.modelsDownloadFailed,
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: WeftSpace.sm),
                    NamedButton(
                      label: l10n.modelsRetryDownload(name),
                      onPressed: onInstall,
                      child: FilledButton.tonal(
                        onPressed: onInstall,
                        child: Text(l10n.modelsRetryResumes),
                      ),
                    ),
                  ],
                ),
                ModelPhase.notInstalled => Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: NamedButton(
                    label: l10n.modelsDownloadNamed(name, mb(total)),
                    onPressed: onInstall,
                    child: FilledButton.tonalIcon(
                      onPressed: onInstall,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(l10n.modelsDownload),
                    ),
                  ),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
