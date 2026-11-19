import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import '../../app/localisation.dart';

import 'login_screen.dart' show kDefaultHomeserver;

/// Where the explainer sends someone who wants to run a server of their own.
abstract final class MatrixServerLinks {
  static final servers = Uri.parse('https://matrix.org/ecosystem/servers/');
  static final synapse = Uri.parse(
    'https://element-hq.github.io/synapse/latest/setup/installation.html',
  );
  static final continuwuity = Uri.parse('https://continuwuity.org/');
  static final ansible = Uri.parse(
    'https://github.com/spantaleev/matrix-docker-ansible-deploy',
  );
  static final bridges = Uri.parse('https://matrix.org/ecosystem/bridges/');
}

/// "What is a Matrix server?" — the small way into [showMatrixServerSheet].
///
/// The server field is the first thing a new install asks for, and the word
/// "server" is where someone who has only ever used WhatsApp stops. The answer
/// sits one tap away rather than on the page, so the form stays a form.
class MatrixServerInfoButton extends StatelessWidget {
  const MatrixServerInfoButton({super.key, this.onUseDefault});

  /// Passed on to the sheet; see [showMatrixServerSheet].
  final VoidCallback? onUseDefault;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: context.text.bodySmall,
      ),
      onPressed: () =>
          showMatrixServerSheet(context, onUseDefault: onUseDefault),
      icon: const Icon(Icons.help_outline_rounded, size: 16),
      label: Text(context.l10n.matrixInfoButton),
    );
  }
}

/// Explains what a homeserver is and the two ways to get one: ours, or one's
/// own.
///
/// [onUseDefault], when given, puts a button under [kDefaultHomeserver] that
/// picks it and closes the sheet. Where there is nothing left to pick — the
/// walkthrough runs after sign-in — it is left out and the sheet only explains.
Future<void> showMatrixServerSheet(
  BuildContext context, {
  VoidCallback? onUseDefault,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => MatrixServerSheet(onUseDefault: onUseDefault),
  );
}

class MatrixServerSheet extends StatelessWidget {
  const MatrixServerSheet({super.key, this.onUseDefault});

  final VoidCallback? onUseDefault;

  Future<void> _open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.chatLinkNoHandler;
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Exception {
      opened = false;
    }
    if (!opened) messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = context.text.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
      height: 1.4,
    );
    final heading = context.text.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );

    Widget link(String label, Uri uri) => ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.open_in_new_rounded, size: 18),
      title: Text(label),
      onTap: () => _open(context, uri),
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.matrixInfoButton,
              style: context.text.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: WeftSpace.md),
            Text(l10n.matrixInfoBody, style: body),

            const SizedBox(height: WeftSpace.xl),
            Text(l10n.matrixInfoPublicTitle, style: heading),
            const SizedBox(height: WeftSpace.xs),
            Text(l10n.matrixInfoPublicBody(kDefaultHomeserver), style: body),
            if (onUseDefault case final use?) ...[
              const SizedBox(height: WeftSpace.md),
              FilledButton.tonal(
                onPressed: () {
                  Navigator.of(context).pop();
                  use();
                },
                child: Text(l10n.matrixInfoUseServer(kDefaultHomeserver)),
              ),
            ],

            const SizedBox(height: WeftSpace.xl),
            Text(l10n.matrixInfoSelfHostTitle, style: heading),
            const SizedBox(height: WeftSpace.xs),
            Text(l10n.matrixInfoSelfHostBody, style: body),
            link(l10n.matrixInfoLinkServers, MatrixServerLinks.servers),
            link(l10n.matrixInfoLinkSynapse, MatrixServerLinks.synapse),
            link(
              l10n.matrixInfoLinkContinuwuity,
              MatrixServerLinks.continuwuity,
            ),
            link(l10n.matrixInfoLinkAnsible, MatrixServerLinks.ansible),

            const SizedBox(height: WeftSpace.lg),
            Text(l10n.matrixInfoBridgesTitle, style: heading),
            const SizedBox(height: WeftSpace.xs),
            Text(l10n.matrixInfoBridgesBody, style: body),
            link(l10n.matrixInfoLinkBridges, MatrixServerLinks.bridges),
          ],
        ),
      ),
    );
  }
}
