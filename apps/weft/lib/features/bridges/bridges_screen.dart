import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../components/qr_card.dart';

/// One configured bridge, as stored in settings.
typedef _StoredBridge = ({String id, String url, String networkId});

const String _bridgesKey = 'bridges.configured';

List<_StoredBridge> _loadBridges(SettingsStore settings) {
  final json = settings.getJson(_bridgesKey);
  final list = json?['bridges'];
  if (list is! List) return const [];
  return [
    for (final entry in list.whereType<Map>())
      (
        id: entry['id'] as String? ?? '',
        url: entry['url'] as String? ?? '',
        networkId: entry['network'] as String? ?? 'unknown',
      ),
  ];
}

void _saveBridges(SettingsStore settings, List<_StoredBridge> bridges) {
  settings.setJson(_bridgesKey, {
    'bridges': [
      for (final b in bridges)
        {'id': b.id, 'url': b.url, 'network': b.networkId},
    ],
  });
}

/// The user's bridges: health, logins, and the GUI login flow.
///
/// Weft hosts nothing — every bridge here is one the user runs. A bridge is
/// added by its provisioning URL; everything else (which network it serves,
/// which login methods it offers) is asked of the bridge itself.
class BridgesScreen extends ConsumerStatefulWidget {
  const BridgesScreen({super.key});

  @override
  ConsumerState<BridgesScreen> createState() => _BridgesScreenState();
}

class _BridgesScreenState extends ConsumerState<BridgesScreen> {
  List<_StoredBridge> _bridges = const [];
  final Map<String, BridgeWhoami?> _health = {};
  final Map<String, String> _errors = {};
  List<DetectedBridge> _detected = const [];

  @override
  void initState() {
    super.initState();
    _bridges = _loadBridges(ref.read(storesProvider).settings);
    _detect();
    _probeAll();
  }

  /// What the server already runs, from m.bridge state in joined rooms.
  void _detect() {
    try {
      final session = ref.read(matrixSessionProvider);
      if (!session.isInitialized) return;
      _detected = detectBridges(session.client);
    } on StateError {
      // Demo mode has no session; the detected section simply stays empty.
    }
  }

  BridgeProvisioningClient _clientFor(_StoredBridge bridge) {
    final session = ref.read(matrixSessionProvider);
    return BridgeProvisioningClient(
      baseUrl: Uri.parse(bridge.url),
      accessToken: session.client.accessToken ?? '',
    );
  }

  Future<void> _probeAll() async {
    for (final bridge in _bridges) {
      await _probe(bridge);
    }
  }

  Future<void> _probe(_StoredBridge bridge) async {
    try {
      final whoami = await _clientFor(bridge).whoami();
      if (!mounted) return;
      setState(() {
        _health[bridge.id] = whoami;
        _errors.remove(bridge.id);
      });
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _health[bridge.id] = null;
        _errors[bridge.id] = e.message;
      });
    }
  }

  Future<void> _addBridge() async {
    final url = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a bridge'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The provisioning URL of a mautrix bridge you run, e.g. '
              'https://bridge.example.org/_matrix/provision',
            ),
            const SizedBox(height: WeftSpace.md),
            TextField(
              controller: url,
              autofocus: true,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'Provisioning URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(url.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    // Disposed after the dialog's exit animation completes — tearing the
    // controller down while the closing TextField still listens to it is a
    // teardown-order crash.
    Future<void>.delayed(const Duration(seconds: 1), url.dispose);

    if (added == null || added.isEmpty) return;
    final parsed = Uri.tryParse(added);
    if (parsed == null || parsed.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('That is not a URL.')));
      }
      return;
    }

    final bridge = (
      id: 'bridge_${DateTime.now().millisecondsSinceEpoch}',
      url: added,
      networkId: 'unknown',
    );
    setState(() => _bridges = [..._bridges, bridge]);
    _saveBridges(ref.read(storesProvider).settings, _bridges);

    // The bridge itself reports which network it serves.
    await _probe(bridge);
    final whoami = _health[bridge.id];
    if (whoami?.networkId != null) {
      final updated = (
        id: bridge.id,
        url: bridge.url,
        networkId: ChatNetwork.fromBridgeProtocol(whoami!.networkId).id,
      );
      setState(() {
        _bridges = [
          for (final b in _bridges)
            if (b.id == bridge.id) updated else b,
        ];
      });
      _saveBridges(ref.read(storesProvider).settings, _bridges);
    }
  }

  void _removeBridge(_StoredBridge bridge) {
    setState(() {
      _bridges = _bridges.where((b) => b.id != bridge.id).toList();
      _health.remove(bridge.id);
    });
    _saveBridges(ref.read(storesProvider).settings, _bridges);
  }

  Future<void> _startLogin(_StoredBridge bridge) async {
    final client = _clientFor(bridge);

    final List<BridgeLoginFlow> flows;
    try {
      flows = await client.loginFlows();
    } on BridgeException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!mounted || flows.isEmpty) return;

    final flow = flows.length == 1
        ? flows.single
        : await showModalBottomSheet<BridgeLoginFlow>(
            context: context,
            showDragHandle: true,
            builder: (context) => ListView(
              shrinkWrap: true,
              children: [
                for (final f in flows)
                  ListTile(
                    title: Text(f.name),
                    subtitle: f.description == null
                        ? null
                        : Text(f.description!),
                    onTap: () => Navigator.of(context).pop(f),
                  ),
              ],
            ),
          );
    if (flow == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BridgeLoginScreen(client: client, flow: flow),
      ),
    );
    await _probe(bridge);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bridges'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _probeAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBridge,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add bridge'),
      ),
      body: _bridges.isEmpty && _detected.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(WeftSpace.xl),
                child: Text(
                  'No bridges yet.\n\nWeft connects to bridges you run on your '
                  'own server — mautrix-whatsapp, -signal, -telegram and '
                  'friends. Add one by its provisioning URL.',
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(WeftSpace.md),
              children: [
                if (_detected.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.all(WeftSpace.sm),
                    child: Text(
                      'Detected on your server',
                      style: context.text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final found in _detected)
                    if (!_bridges.any((b) => b.networkId == found.network.id))
                      ListTile(
                        leading: NetworkGlyph(network: found.network, size: 30),
                        title: Text(found.network.label),
                        subtitle: Text(
                          '${found.roomCount} bridged chat(s)'
                          '${found.botUserId == null ? '' : ' · ${found.botUserId}'}',
                        ),
                        trailing: FilledButton.tonal(
                          onPressed: _addBridge,
                          child: const Text('Set up'),
                        ),
                      ),
                  const Divider(height: WeftSpace.xl),
                ],
                for (final bridge in _bridges)
                  _BridgeCard(
                    bridge: bridge,
                    whoami: _health[bridge.id],
                    error: _errors[bridge.id],
                    onLogin: () => _startLogin(bridge),
                    onRemove: () => _removeBridge(bridge),
                    onLogout: (loginId) async {
                      await _clientFor(bridge).logout(loginId);
                      await _probe(bridge);
                    },
                  ),
              ],
            ),
    );
  }
}

class _BridgeCard extends StatelessWidget {
  const _BridgeCard({
    required this.bridge,
    required this.whoami,
    required this.error,
    required this.onLogin,
    required this.onRemove,
    required this.onLogout,
  });

  final _StoredBridge bridge;
  final BridgeWhoami? whoami;
  final String? error;
  final VoidCallback onLogin;
  final VoidCallback onRemove;
  final ValueChanged<String> onLogout;

  @override
  Widget build(BuildContext context) {
    final network = ChatNetwork.fromId(bridge.networkId);
    final palette = context.palette;

    return Card(
      margin: const EdgeInsets.only(bottom: WeftSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(WeftSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                NetworkGlyph(network: network, size: 32),
                const SizedBox(width: WeftSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        whoami?.networkName ?? network.label,
                        style: context.text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        Uri.parse(bridge.url).host,
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (choice) {
                    if (choice == 'remove') onRemove();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove bridge'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.md),
            if (error != null)
              Row(
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 16,
                    color: context.colors.error,
                  ),
                  const SizedBox(width: WeftSpace.sm),
                  Expanded(
                    child: Text(
                      error!,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ),
                ],
              )
            else if (whoami == null)
              const LinearProgressIndicator(minHeight: 2)
            else if (whoami!.logins.isEmpty)
              Text(
                'Not signed in to ${whoami!.networkName ?? network.label} yet.',
                style: context.text.bodySmall,
              )
            else
              for (final login in whoami!.logins)
                Padding(
                  padding: const EdgeInsets.only(bottom: WeftSpace.xs),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: login.isActive
                              ? palette.online
                              : context.colors.error,
                        ),
                      ),
                      const SizedBox(width: WeftSpace.sm),
                      Expanded(
                        child: Text(
                          '${login.label} — ${login.state.name}'
                          '${login.errorMessage == null ? '' : ' (${login.errorMessage})'}',
                          style: context.text.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () => onLogout(login.id),
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: WeftSpace.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: error != null ? null : onLogin,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: Text(
                  (whoami?.logins.isEmpty ?? true)
                      ? 'Sign in'
                      : 'Add another account',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a bridge's declarative login flow, step by step.
class BridgeLoginScreen extends StatefulWidget {
  const BridgeLoginScreen({
    super.key,
    required this.client,
    required this.flow,
  });

  final BridgeProvisioningClient client;
  final BridgeLoginFlow flow;

  @override
  State<BridgeLoginScreen> createState() => _BridgeLoginScreenState();
}

class _BridgeLoginScreenState extends State<BridgeLoginScreen> {
  late final BridgeLoginSession _session = BridgeLoginSession(
    client: widget.client,
    flowId: widget.flow.id,
  );
  final Map<String, TextEditingController> _inputs = {};
  StreamSubscription<BridgeLoginSession>? _updates;

  @override
  void initState() {
    super.initState();
    _updates = _session.updates.listen((_) {
      if (mounted) setState(() {});
    });
    _session.start();
  }

  @override
  void dispose() {
    _updates?.cancel();
    _session.dispose();
    for (final c in _inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = _session.currentStep;

    return Scaffold(
      appBar: AppBar(title: Text(widget.flow.name)),
      body: Padding(
        padding: const EdgeInsets.all(WeftSpace.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: switch (_session.status) {
              BridgeLoginStatus.idle ||
              BridgeLoginStatus.running => const CircularProgressIndicator(),
              BridgeLoginStatus.complete => _done(context),
              BridgeLoginStatus.failed => _failed(context),
              BridgeLoginStatus.waitingForUser when step != null => _inputStep(
                context,
                step,
              ),
              BridgeLoginStatus.waitingForRemote when step != null => _waitStep(
                context,
                step,
              ),
              _ => const CircularProgressIndicator(),
            },
          ),
        ),
      ),
    );
  }

  Widget _inputStep(BuildContext context, LoginStep step) {
    return ListView(
      shrinkWrap: true,
      children: [
        if (step.instructions != null) ...[
          Text(step.instructions!, style: context.text.bodyMedium),
          const SizedBox(height: WeftSpace.lg),
        ],
        for (final field in step.fields) ...[
          TextField(
            controller: _inputs.putIfAbsent(
              field.id,
              TextEditingController.new,
            ),
            obscureText: field.isSecret,
            autocorrect: false,
            keyboardType: switch (field.keyboardHint) {
              'phone' => TextInputType.phone,
              'email' => TextInputType.emailAddress,
              'number' => TextInputType.number,
              _ => TextInputType.text,
            },
            decoration: InputDecoration(
              labelText: field.name,
              helperText: field.description,
            ),
          ),
          const SizedBox(height: WeftSpace.md),
        ],
        if (_session.error != null) ...[
          Text(
            _session.error!,
            style: context.text.bodySmall?.copyWith(
              color: context.colors.error,
            ),
          ),
          const SizedBox(height: WeftSpace.md),
        ],
        FilledButton(
          onPressed: () => _session.submitInput({
            for (final entry in _inputs.entries) entry.key: entry.value.text,
          }),
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _waitStep(BuildContext context, LoginStep step) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (step.instructions != null) ...[
          Text(step.instructions!, textAlign: TextAlign.center),
          const SizedBox(height: WeftSpace.lg),
        ],
        if (step.displayData != null) ...[
          if (step.displayType == 'qr') ...[
            QrCard.data(step.displayData!),
            const SizedBox(height: WeftSpace.md),
          ],
          // The raw payload stays available under the image: some networks
          // accept pasting the code, and it is the fallback if a camera has
          // trouble with a screen.
          Container(
            padding: const EdgeInsets.all(WeftSpace.md),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHigh,
              borderRadius: WeftRadius.allMd,
            ),
            child: SelectableText(
              step.displayData!,
              style: context.text.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: step.displayData!)),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy code'),
          ),
          const SizedBox(height: WeftSpace.lg),
        ],
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: WeftSpace.md),
        Text(
          'Waiting for the other side…',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        TextButton(
          onPressed: () {
            _session.cancel();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.check_circle_rounded,
          size: 48,
          color: context.palette.online,
        ),
        const SizedBox(height: WeftSpace.lg),
        const Text(
          'Signed in. The bridge is syncing your chats now — '
          'they will appear in the inbox as they arrive.',
        ),
        const SizedBox(height: WeftSpace.lg),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_rounded, size: 48, color: context.colors.error),
        const SizedBox(height: WeftSpace.lg),
        Text(_session.error ?? 'Sign-in failed.', textAlign: TextAlign.center),
        const SizedBox(height: WeftSpace.lg),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
