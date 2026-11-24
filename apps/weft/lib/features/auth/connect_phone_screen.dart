import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
import '../../services/web/phone_connection_errors.dart';

/// Sennit Web's front door: shown until this browser reaches its phone.
class ConnectPhoneScreen extends StatelessWidget {
  const ConnectPhoneScreen({
    super.key,
    required this.problem,
    required this.onRetry,
  });

  final PhoneConnectionProblem problem;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = switch (problem) {
      PhoneConnectionProblem.notPaired => l10n.sennitWebConnectNotPaired,
      PhoneConnectionProblem.unreachable => l10n.sennitWebConnectUnreachable,
      PhoneConnectionProblem.versionMismatch => l10n.sennitWebConnectVersion,
    };
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(WeftSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  problem == PhoneConnectionProblem.notPaired
                      ? Icons.qr_code_scanner_rounded
                      : Icons.phonelink_off_rounded,
                  size: 48,
                  color: context.colors.primary,
                ),
                const SizedBox(height: WeftSpace.lg),
                Text(
                  l10n.sennitWebConnectTitle,
                  style: context.text.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WeftSpace.sm),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: WeftSpace.xl),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(l10n.settingsTryAgain),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
