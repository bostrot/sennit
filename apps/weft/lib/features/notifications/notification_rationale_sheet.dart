import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

/// Asks whether the user wants notifications, *before* the OS asks.
///
/// The reason this exists rather than the permission dialog being shown
/// straight away: Android and iOS each grant an app exactly one prompt. A second
/// `requestPermission` returns the first answer without showing anything, so a
/// refusal is permanent from the app's side — recoverable only by the user
/// finding the right page of system settings. A sheet first turns the one
/// irreversible question into a reversible one: "Not now" costs nothing and can
/// be asked again next launch, and by the time the system dialog does appear the
/// user has been told what it is for.
///
/// Returns true when the user wants to be asked. The caller spends the prompt.
Future<bool> showNotificationRationale(BuildContext context) async {
  final wanted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _NotificationRationaleSheet(),
  );
  return wanted ?? false;
}

class _NotificationRationaleSheet extends StatelessWidget {
  const _NotificationRationaleSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.notifications_active_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: WeftSpace.lg),
            Text(
              'Get told when someone writes',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WeftSpace.md),
            Text(
              'Braid can notify you when a message arrives on any of your '
              'networks. A merged contact is one notification, not one per '
              'network, and anything you have already read elsewhere stays '
              'quiet.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WeftSpace.md),
            Text(
              // The one thing worth saying about the mechanism, because it is
              // the thing a self-hoster actually wants to know before granting.
              'Message text is never sent to a push service — Braid is told only '
              'that something happened, then fetches and decrypts it on this '
              'device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WeftSpace.xl),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Turn on notifications'),
            ),
            const SizedBox(height: WeftSpace.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
