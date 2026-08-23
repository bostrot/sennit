import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../chat/chat_view.dart';
import '../components/qr_card.dart';
import 'bot_login_screen.dart';

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
/// Braid hosts nothing — every bridge here is one the user runs. A bridge is
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
    // Detection walks the *local* room list, and right after a cold start
    // that list is still loading. One early call used to be the only call —
    // open Bridges in the first seconds of a fresh install and every bridge
    // read as absent until the screen was reopened. The inbox heartbeat
    // re-runs it until the rooms are there. Only with a live session: a
    // widget test (and demo mode) pumps this screen without one, and the
    // heartbeat provider cannot even be built then.
    try {
      if (ref.read(matrixSessionProvider).isInitialized) {
        ref.listenManual(chatsProvider, (_, _) {
          if (!mounted) return;
          final before = _detected.length;
          _detect();
          if (_detected.length != before) setState(() {});
        });
      }
    } on Object {
      // No heartbeat, no retries — the single detect above already ran.
    }
  }

  /// What the server already runs, from m.bridge state in joined rooms.
  void _detect() {
    try {
      final session = ref.read(matrixSessionProvider);
      if (!session.isInitialized) return;
      _detected = detectBridges(session.client);
    } on StateError {
      // Demo mode has no session; the detected section simply stays empty.
    } on Object {
      // A half-loaded room mid-sync; the next heartbeat retries.
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
    final name = ChatNetwork.fromId(bridge.networkId).label;
    try {
      final whoami = await _clientFor(bridge).whoami();
      if (!mounted) return;
      setState(() {
        _health[bridge.id] = whoami;
        _errors.remove(bridge.id);
      });
      // A probe finishing is a progress bar vanishing and a sentence taking its
      // place, in a card that may be well off screen — and this screen exists
      // to answer "is it working?", so the answer is the one thing that has to
      // be said out loud.
      announce(
        context,
        '${whoami.networkName ?? name}: ${_reachedLabel(whoami)}',
      );
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _health[bridge.id] = null;
        _errors[bridge.id] = e.message;
      });
      announce(context, '$name bridge could not be reached. ${e.message}');
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
              'The provisioning URL of a mautrix bridge you run — where the '
              'bridge\'s own web API is reachable, e.g. '
              'https://bridge.example.org/_matrix/provision. It enables the '
              'guided sign-in flow here.\n\n'
              'No URL handy? Opening the bridge\'s chat from the list works '
              'without one: send "login" to the bot there.',
            ),
            const SizedBox(height: WeftSpace.md),
            WeftLabelledField(
              label: 'Provisioning URL',
              child: TextField(
                controller: url,
                autofocus: true,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: 'Provisioning URL'),
              ),
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
      if (mounted) showWeftMessage(context, 'That is not a URL.');
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

  /// Opens (creating if needed) the DM with the bridge's bot.
  ///
  /// This is the path that needs no provisioning URL at all: every mautrix
  /// bridge accepts `login`, `help` and friends as chat commands in its
  /// management room, so the bot chat is a complete fallback for anyone whose
  /// bridge does not expose the provisioning API to the network Weft is on.
  Future<void> _openBotChat(String botUserId) async {
    final client = ref.read(matrixSessionProvider).client;
    final repository = ref.read(chatRepositoryProvider);

    final String roomId;
    try {
      roomId = await client.startDirectChat(botUserId);
    } on Exception catch (e) {
      if (mounted) showWeftMessage(context, 'Could not open the chat: $e');
      return;
    }

    // A just-created room reaches the inbox with the next sync; opening the
    // view before then would render "unknown chat". Give it a moment, then
    // open regardless — the view copes.
    for (var i = 0; i < 20 && repository.chatForRoom(roomId) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatView(chatId: repository.chatForRoom(roomId)?.id ?? roomId),
      ),
    );
  }

  Future<void> _startLogin(_StoredBridge bridge) async {
    final client = _clientFor(bridge);

    final List<BridgeLoginFlow> flows;
    try {
      flows = await client.loginFlows();
    } on BridgeException catch (e) {
      if (mounted) showWeftMessage(context, e.message);
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
                        // The tile's title is the network's name — same
                        // duplication the chat bubble had.
                        leading: NetworkGlyph(
                          network: found.network,
                          size: 30,
                          semanticsLabel: '',
                        ),
                        title: Text(found.network.label),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${found.roomCount} bridged chat(s)'
                              '${found.botUserId == null ? '' : ' · ${found.botUserId}'}',
                            ),
                            const SizedBox(height: WeftSpace.xs),
                            // Sign-in first: the guided flow talks to the
                            // bot's management room, which every mautrix
                            // bridge has, no provisioning URL required. The
                            // plain chat stays for everything else the bot
                            // can do, and the URL flow lives behind the
                            // "Add bridge" button for the richer API.
                            Wrap(
                              spacing: WeftSpace.sm,
                              children: [
                                if (found.botUserId != null) ...[
                                  FilledButton.tonalIcon(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => BridgeBotLoginScreen(
                                          botUserId: found.botUserId!,
                                          network: found.network,
                                        ),
                                      ),
                                    ),
                                    icon: const WeftMirroredIcon(
                                      Icons.login_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Sign in'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _openBotChat(found.botUserId!),
                                    icon: const Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Open chat'),
                                  ),
                                ] else
                                  OutlinedButton(
                                    onPressed: _addBridge,
                                    child: const Text('Add provisioning URL'),
                                  ),
                              ],
                            ),
                          ],
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

/// What a completed health probe found, in one clause.
///
/// The card draws this as a progress bar giving way to a row of dots and
/// sentences. Neither of those is an answer to "did it work?", which is the
/// only question this screen is ever open for.
String _reachedLabel(BridgeWhoami whoami) {
  if (whoami.logins.isEmpty) return 'reachable, but not signed in yet';
  final active = whoami.logins.where((l) => l.isActive).length;
  final total = whoami.logins.length;
  if (active == total) {
    return total == 1
        ? 'connected as ${whoami.logins.single.label}'
        : 'connected, $total accounts';
  }
  return '$active of $total accounts connected';
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
                NetworkGlyph(network: network, size: 32, semanticsLabel: ''),
                const SizedBox(width: WeftSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // Names the network in words, which is why the glyph
                        // beside it is silent.
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
                  // Material's default is "Show menu", which on a screen with
                  // four bridge cards is four identical buttons for four
                  // different bridges — and the one action behind it deletes.
                  tooltip:
                      'Actions for the '
                      '${whoami?.networkName ?? network.label} bridge',
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
              // One node, and the glyph is decoration: a red cloud says
              // "unreachable" to someone who can see it and nothing at all
              // otherwise, so the state is named in the sentence.
              MergeSemantics(
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.cloud_off_rounded,
                        size: 16,
                        color: context.colors.error,
                      ),
                    ),
                    const SizedBox(width: WeftSpace.sm),
                    Expanded(
                      child: Semantics(
                        label: 'Not reachable. ${error!}',
                        excludeSemantics: true,
                        child: Text(
                          error!,
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.error,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (whoami == null)
              Semantics(
                label: 'Checking the ${network.label} bridge',
                child: const LinearProgressIndicator(minHeight: 2),
              )
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
                      // The dot is the colour-only half of a state the sentence
                      // beside it already spells out; it says nothing a reader
                      // has not already been told.
                      ExcludeSemantics(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: login.isActive
                                ? palette.online
                                : context.colors.error,
                          ),
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
                      // Three accounts on one bridge is three buttons reading
                      // "Sign out", and signing out of the wrong one costs a
                      // full re-pairing.
                      NamedButton(
                        label: 'Sign out of ${login.label}',
                        onPressed: () => onLogout(login.id),
                        child: TextButton(
                          onPressed: () => onLogout(login.id),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: WeftSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                onPressed: error != null ? null : onLogin,
                // `login_rounded` is one of the two arrows in this app that
                // Material does not mirror for itself — see [WeftMirroredIcon].
                icon: const WeftMirroredIcon(Icons.login_rounded, size: 18),
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
            // The code and its text form are two nodes with nothing joining
            // them: a reader who finds the square is told it is a square, and
            // has no reason to think the answer is one node further on.
            QrCard.data(
              step.displayData!,
              semanticsLabel:
                  'QR code for ${widget.flow.name}. Scan it with the other '
                  'device, or use the pairing code just below, which can be '
                  'copied.',
            ),
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
        // One live node over the spinner and its caption. This step ends when
        // the *other* device does something, so the user is waiting on an
        // event they cannot see coming — and every transition out of here
        // replaces the whole body.
        Semantics(
          liveRegion: true,
          container: true,
          label: 'Waiting for the other side to confirm',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
            ],
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
    // Live, because the step before it was "waiting for something you cannot
    // see", and this is that something having happened.
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.check_circle_rounded,
              size: 48,
              color: context.palette.online,
            ),
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
      ),
    );
  }

  Widget _failed(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.error_rounded,
              size: 48,
              color: context.colors.error,
            ),
          ),
          const SizedBox(height: WeftSpace.lg),
          Text(
            _session.error ?? 'Sign-in failed.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WeftSpace.lg),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
