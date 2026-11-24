import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../app/sync_providers.dart';
import 'settings_section.dart';

/// Device sync: the switch for this device, the shared switch for secrets,
/// how the last round went, and in plain words what travels and what stays.
class DeviceSyncScreen extends ConsumerWidget {
  const DeviceSyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final enabled = ref.watch(deviceSyncEnabledProvider);
    ref.watch(settingsRevisionProvider);
    final settings = ref.watch(storesProvider).settings;
    final secrets = settings.getBool(WeftSettings.syncSecrets);
    final status = ref.watch(deviceSyncStatusProvider);
    final runner = ref.watch(deviceSyncRunnerProvider);

    void write(String key, {required bool value}) {
      settings.setBool(key, value: value);
      ref.read(settingsRevisionProvider.notifier).bump();
    }

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.settingsDeviceSyncTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            PrivacyNotice(message: l10n.deviceSyncNotice),
            const SizedBox(height: WeftSpace.lg),
            SwitchListTile(
              title: Text(l10n.deviceSyncEnableTitle),
              subtitle: Text(l10n.deviceSyncEnableSubtitle),
              value: enabled,
              onChanged: (v) => write(WeftSettings.syncEnabled, value: v),
              contentPadding: EdgeInsets.zero,
            ),
            if (enabled) ...[
              SwitchListTile(
                title: PrivacyGatedTitle(
                  title: l10n.deviceSyncSecretsTitle,
                  warning: l10n.deviceSyncSecretsWarning,
                ),
                subtitle: Text(l10n.deviceSyncSecretsSubtitle),
                value: secrets,
                onChanged: (v) => write(WeftSettings.syncSecrets, value: v),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: WeftSpace.md),
              _StatusLine(status: status),
              const SizedBox(height: WeftSpace.sm),
              Wrap(
                spacing: WeftSpace.sm,
                runSpacing: WeftSpace.sm,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: Text(l10n.deviceSyncNow),
                    onPressed: runner == null
                        ? null
                        : () => unawaited(runner.now()),
                  ),
                  if (status?.outcome == SyncOutcome.otherKey ||
                      status?.outcome == SyncOutcome.corrupt)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.restore_page_outlined, size: 18),
                      label: Text(l10n.deviceSyncReplace),
                      onPressed: runner == null
                          ? null
                          : () => unawaited(runner.now(replace: true)),
                    ),
                ],
              ),
            ],
            const Divider(height: WeftSpace.xl),
            SettingsSectionHeader(
              title: l10n.deviceSyncSharedTitle,
              subtitle: l10n.deviceSyncSharedBody,
            ),
            const SizedBox(height: WeftSpace.sm),
            Text(
              l10n.deviceSyncLocalBody,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final DeviceSyncStatus? status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = this.status;
    final text = switch (status?.outcome) {
      null => l10n.deviceSyncStatusNever,
      SyncOutcome.synced => l10n.deviceSyncStatusSynced(
        MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay.fromDateTime(status!.at),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        ),
      ),
      SyncOutcome.noKey => l10n.deviceSyncStatusNoKey,
      SyncOutcome.otherKey => l10n.deviceSyncStatusOtherKey,
      SyncOutcome.corrupt => l10n.deviceSyncStatusCorrupt,
      SyncOutcome.waiting => l10n.deviceSyncStatusWaiting,
      SyncOutcome.failed => l10n.deviceSyncStatusFailed,
    };
    final problem =
        status != null &&
        status.outcome != SyncOutcome.synced &&
        status.outcome != SyncOutcome.waiting;
    return Row(
      children: [
        Icon(
          problem ? Icons.error_outline_rounded : Icons.cloud_done_outlined,
          size: 18,
          color: problem ? context.colors.error : context.colors.primary,
        ),
        const SizedBox(width: WeftSpace.sm),
        Expanded(child: Text(text, style: context.text.bodyMedium)),
      ],
    );
  }
}
