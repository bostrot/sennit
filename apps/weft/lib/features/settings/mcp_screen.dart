import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_mcp/weft_mcp.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/mcp_service.dart';

/// The MCP server: on/off, API keys, tunnel, audit log.
class McpScreen extends ConsumerStatefulWidget {
  const McpScreen({super.key});

  @override
  ConsumerState<McpScreen> createState() => _McpScreenState();
}

class _McpScreenState extends ConsumerState<McpScreen> {
  bool _busy = false;

  McpService get _service => ref.read(mcpServiceProvider);

  Future<void> _toggleServer(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        await _service.start();
      } else {
        await _service.stop();
      }
    } on Object catch (error) {
      // Said out loud, because the ways this fails are all invisible: a
      // sandboxed build without `com.apple.security.network.server` cannot
      // open a listening socket at all, and a port already in use is the same
      // shape. The switch used to snap back with no explanation, which reads
      // as a button that does nothing rather than as a refusal.
      debugPrint('weft: MCP server ${on ? 'start' : 'stop'} failed: $error');
      if (mounted) {
        showWeftMessage(
          context,
          on
              ? context.l10n.mcpStartFailed(_reason(context.l10n, error))
              : context.l10n.mcpStopFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The failure in a phrase, where the phrase is worth having.
  ///
  /// A `SocketException` stringifies to two lines of address and errno, which
  /// is the wrong thing to put in a snack bar; the two cases anyone actually
  /// hits are worth naming.
  String _reason(AppL10n l10n, Object error) {
    if (error is! SocketException) return l10n.mcpReasonSeeLog;
    final code = error.osError?.errorCode;
    return switch (code) {
      1 => l10n.mcpReasonSandbox,
      48 || 98 => l10n.mcpReasonPortInUse,
      _ => error.osError?.message ?? l10n.mcpReasonSocketFailed,
    };
  }

  Future<void> _createKey() async {
    final label = TextEditingController();
    var scopes = <McpScope>{McpScope.read};

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.mcpNewKeyTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: label,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.mcpKeyLabelField,
                  hintText: context.l10n.mcpKeyLabelHint,
                ),
              ),
              const SizedBox(height: WeftSpace.lg),
              Text(context.l10n.mcpScopesTitle),
              for (final scope in McpScope.values)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(scope.name),
                  subtitle: Text(switch (scope) {
                    McpScope.read => context.l10n.mcpScopeRead,
                    McpScope.send => context.l10n.mcpScopeSend,
                    McpScope.admin => context.l10n.mcpScopeAdmin,
                  }),
                  value: scopes.contains(scope),
                  onChanged: (v) => setDialogState(() {
                    if (v ?? false) {
                      scopes = {...scopes, scope};
                    } else {
                      scopes = scopes.where((s) => s != scope).toSet();
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: scopes.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: Text(context.l10n.commonCreate),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) {
      label.dispose();
      return;
    }

    final generated = _service.createKey(
      label: label.text.trim().isEmpty
          ? context.l10n.mcpUnnamedKey
          : label.text.trim(),
      scopes: scopes,
    );
    label.dispose();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.mcpCopyKeyTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.mcpCopyKeyBody),
            const SizedBox(height: WeftSpace.md),
            Container(
              padding: const EdgeInsets.all(WeftSpace.md),
              decoration: BoxDecoration(
                color: context.colors.surfaceContainerHigh,
                borderRadius: WeftRadius.allMd,
              ),
              // "This is the only time the key is shown" is a promise the
              // screen could not keep for a reader: 43 characters of base64 in
              // one run is announced as one word nobody can transcribe. Spelled
              // out, and with Copy named as the shorter road.
              child: Semantics(
                label: context.l10n.mcpKeySpelledOut(
                  spelledOut(generated.secret),
                ),
                excludeSemantics: true,
                child: SelectableText(
                  generated.secret,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: generated.secret)),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(context.l10n.commonCopy),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonDone),
          ),
        ],
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(mcpServiceProvider);
    final running = service.boundPort != null;
    final keys = service.loadKeys().where((k) => !k.revoked).toList();

    return Scaffold(
      appBar: WeftAppBar(title: Text(context.l10n.mcpTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            Text(
              context.l10n.mcpIntro,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: WeftSpace.lg),
            SwitchListTile(
              title: Text(context.l10n.mcpRunServerTitle),
              subtitle: Text(
                running
                    ? context.l10n.mcpListeningOn(service.boundPort!)
                    : context.l10n.mcpStopped,
              ),
              value: running,
              onChanged: _busy ? null : _toggleServer,
              contentPadding: EdgeInsets.zero,
            ),
            if (running)
              McpTunnelTile(
                tunnel: service.tunnel,
                localPort: service.boundPort ?? 0,
              ),
            const Divider(height: WeftSpace.xl),

            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.mcpApiKeysTitle,
                    style: context.text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _createKey,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(context.l10n.mcpNewKeyButton),
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.sm),
            if (keys.isEmpty)
              Text(
                context.l10n.mcpNoKeys,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else
              for (final key in keys)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.key_rounded),
                  title: Text(key.label),
                  subtitle: Text(
                    context.l10n.mcpKeySubtitle(
                      key.id,
                      key.scopes.map((s) => s.name).join(', '),
                    ),
                  ),
                  trailing: NamedButton(
                    label: context.l10n.mcpRevokeNamed(key.label),
                    onPressed: () {
                      service.revokeKey(key.id);
                      setState(() {});
                    },
                    child: TextButton(
                      onPressed: () {
                        service.revokeKey(key.id);
                        setState(() {});
                      },
                      child: Text(context.l10n.mcpRevoke),
                    ),
                  ),
                ),
            const Divider(height: WeftSpace.xl),

            Text(
              context.l10n.mcpRecentActivity,
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: WeftSpace.sm),
            if (service.auditLog.entries.isEmpty)
              Text(
                context.l10n.mcpNothingYet,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              )
            else
              for (final entry in service.auditLog.entries.reversed.take(30))
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.xs),
                  child: Text(
                    // l10n-ignore: a machine-readable audit line; its screen-reader label is translated.
                    '$entry',
                    // Allowed and denied differ by colour and by nothing else, on
                    // the log whose whole job is to show an agent being refused.
                    // The word goes first because that is the one a reader
                    // skimming thirty rows is listening for.
                    semanticsLabel: entry.allowed
                        ? context.l10n.mcpAuditAllowed('$entry')
                        : context.l10n.mcpAuditDenied('$entry'),
                    style: context.text.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: entry.allowed
                          ? context.colors.onSurfaceVariant
                          : context.colors.error,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The Cloudflare tunnel row: what the tunnel is doing, and how to change it.
///
/// On Android and iOS it is a row with no button. A tunnel is a long-lived
/// child process, neither platform lets an app run one, and the row used to
/// offer Start anyway — which produced a failure whose text was the package's
/// own English: *"Could not start cloudflared. Install it and make sure it is
/// on PATH."* There is no PATH on a phone to put it on. Saying so before the
/// tap, and saying what to do instead, is the whole of the fix.
class McpTunnelTile extends StatelessWidget {
  const McpTunnelTile({
    required this.tunnel,
    required this.localPort,
    super.key,
  });

  /// The supervisor, rather than the whole [McpService], so the row can be
  /// pumped on its own. Which is the only way the state that matters here is
  /// reachable from a test: the mobile branch needs a platform override and no
  /// bound socket, and building an `McpService` to get at it would drag in the
  /// store, the registry and a listening port.
  final CloudflaredSupervisor tunnel;

  /// The port the MCP server is listening on, which the tunnel is pointed at.
  final int localPort;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TunnelState>(
      stream: tunnel.states,
      initialData: tunnel.state,
      builder: (context, snapshot) {
        final supported = tunnel.isSupportedPlatform;
        final state = snapshot.data ?? TunnelState.stopped;
        final url = tunnel.publicUrl;

        return ListTile(
          contentPadding: EdgeInsets.zero,
          // Dimmed on a platform that cannot run one, the same way a disabled
          // control reads everywhere else: the row is information, not an
          // offer, and it should not look like one that failed.
          enabled: supported,
          // The glyph's colour is the state; the subtitle beside it says the
          // state in words, so the glyph has nothing left to contribute.
          leading: ExcludeSemantics(
            child: Icon(
              supported ? Icons.cloud_outlined : Icons.cloud_off_outlined,
              color: state == TunnelState.running && supported
                  ? context.palette.online
                  : context.colors.onSurfaceVariant,
            ),
          ),
          title: Text(context.l10n.mcpTunnelTitle),
          subtitle: Text(
            !supported
                ? context.l10n.mcpTunnelUnsupported
                : switch (state) {
                    TunnelState.running =>
                      url ?? context.l10n.mcpTunnelRunningNamed,
                    TunnelState.starting => context.l10n.mcpTunnelStarting,
                    TunnelState.failed => _failureText(context),
                    TunnelState.stopped => context.l10n.mcpTunnelStopped,
                  },
          ),
          // No control at all rather than a disabled one. A greyed-out Start
          // invites a tap that will never be allowed, and the sentence beside
          // it already says the tunnel belongs on another machine.
          trailing: !supported
              ? null
              : switch (state) {
                  TunnelState.stopped => TextButton(
                    onPressed: () => tunnel.start(localPort: localPort),
                    child: Text(context.l10n.commonStart),
                  ),
                  _ => TextButton(
                    onPressed: tunnel.stop,
                    child: Text(context.l10n.commonStop),
                  ),
                },
        );
      },
    );
  }

  /// A failure as a sentence in the reader's language.
  ///
  /// The supervisor reports a [TunnelFailure] and an exit code, and the words
  /// are assembled here — `weft_mcp` has no ARB files, so a package that
  /// carried the sentence could only ever carry it in English. See
  /// `docs/architecture/l10n-pipeline.md`, "Packages and their words".
  String _failureText(BuildContext context) {
    final l10n = context.l10n;
    final code = tunnel.lastExitCode;
    return switch (tunnel.failure) {
      TunnelFailure.unsupportedPlatform => l10n.mcpTunnelUnsupported,
      TunnelFailure.notInstalled => l10n.mcpTunnelNotInstalled,
      TunnelFailure.exited when code != null => l10n.mcpTunnelExited(code),
      TunnelFailure.gaveUp when code != null => l10n.mcpTunnelGaveUp(code),
      // Failed with nothing to say about why, which the supervisor should not
      // produce — but a subtitle is not the place to find that out.
      _ => l10n.mcpTunnelFailed,
    };
  }
}
