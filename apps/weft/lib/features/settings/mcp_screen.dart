import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_mcp/weft_mcp.dart';

import '../../app/a11y.dart';
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createKey() async {
    final label = TextEditingController();
    var scopes = <McpScope>{McpScope.read};

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New API key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: label,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'e.g. laptop agent',
                ),
              ),
              const SizedBox(height: WeftSpace.lg),
              const Text('Scopes'),
              for (final scope in McpScope.values)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(scope.name),
                  subtitle: Text(switch (scope) {
                    McpScope.read => 'Read chats and search',
                    McpScope.send => 'Send messages as you',
                    McpScope.admin => 'Merge contacts, manage settings',
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: scopes.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Create'),
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
      label: label.text.trim().isEmpty ? 'unnamed' : label.text.trim(),
      scopes: scopes,
    );
    label.dispose();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy this key now'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is the only time the key is shown. Braid stores only a '
              'hash; if it is lost, revoke it and create a new one.',
            ),
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
                label:
                    'API key. Copy it with the Copy button, or write it down: '
                    '${spelledOut(generated.secret)}',
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
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
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
      appBar: AppBar(title: const Text('MCP server')),
      body: ListView(
        padding: const EdgeInsets.all(WeftSpace.lg),
        children: [
          Text(
            'Lets AI agents read and act on your messages over the Model '
            'Context Protocol. Every call needs one of the API keys below, is '
            'scope-checked, rate-limited and logged.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          SwitchListTile(
            title: const Text('Run the MCP server'),
            subtitle: Text(
              running
                  ? 'Listening on 127.0.0.1:${service.boundPort} (loopback only)'
                  : 'Stopped',
            ),
            value: running,
            onChanged: _busy ? null : _toggleServer,
            contentPadding: EdgeInsets.zero,
          ),
          if (running) _TunnelTile(service: service),
          const Divider(height: WeftSpace.xl),

          Row(
            children: [
              Expanded(
                child: Text(
                  'API keys',
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _createKey,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New key'),
              ),
            ],
          ),
          const SizedBox(height: WeftSpace.sm),
          if (keys.isEmpty)
            Text(
              'No keys yet. The server refuses every request until one exists.',
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
                  '${key.id} · ${key.scopes.map((s) => s.name).join(", ")}',
                ),
                trailing: NamedButton(
                  label: 'Revoke the key named ${key.label}',
                  onPressed: () {
                    service.revokeKey(key.id);
                    setState(() {});
                  },
                  child: TextButton(
                    onPressed: () {
                      service.revokeKey(key.id);
                      setState(() {});
                    },
                    child: const Text('Revoke'),
                  ),
                ),
              ),
          const Divider(height: WeftSpace.xl),

          Text(
            'Recent activity',
            style: context.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          if (service.auditLog.entries.isEmpty)
            Text(
              'Nothing yet.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            )
          else
            for (final entry in service.auditLog.entries.reversed.take(30))
              Padding(
                padding: const EdgeInsets.only(bottom: WeftSpace.xs),
                child: Text(
                  '$entry',
                  // Allowed and denied differ by colour and by nothing else, on
                  // the log whose whole job is to show an agent being refused.
                  // The word goes first because that is the one a reader
                  // skimming thirty rows is listening for.
                  semanticsLabel:
                      '${entry.allowed ? 'Allowed' : 'Denied'}: $entry',
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
    );
  }
}

class _TunnelTile extends StatelessWidget {
  const _TunnelTile({required this.service});

  final McpService service;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TunnelState>(
      stream: service.tunnel.states,
      initialData: service.tunnel.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? TunnelState.stopped;
        final url = service.tunnel.publicUrl;

        return ListTile(
          contentPadding: EdgeInsets.zero,
          // The glyph's colour is the state; the subtitle beside it says the
          // state in words, so the glyph has nothing left to contribute.
          leading: ExcludeSemantics(
            child: Icon(
              Icons.cloud_outlined,
              color: state == TunnelState.running
                  ? context.palette.online
                  : context.colors.onSurfaceVariant,
            ),
          ),
          title: const Text('Cloudflare tunnel'),
          subtitle: Text(switch (state) {
            TunnelState.running => url ?? 'Running (named tunnel)',
            TunnelState.starting => 'Starting…',
            TunnelState.failed => service.tunnel.lastError ?? 'Failed to start',
            TunnelState.stopped => 'Off. Requires cloudflared on this machine.',
          }),
          trailing: switch (state) {
            TunnelState.stopped => TextButton(
              onPressed: () =>
                  service.tunnel.start(localPort: service.boundPort ?? 0),
              child: const Text('Start'),
            ),
            _ => TextButton(
              onPressed: service.tunnel.stop,
              child: const Text('Stop'),
            ),
          },
        );
      },
    );
  }
}
