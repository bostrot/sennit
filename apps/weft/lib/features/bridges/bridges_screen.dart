import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_bridges/weft_bridges.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/a11y.dart';
import '../../app/l10n_labels.dart';
import '../../app/localisation.dart';
import '../../app/providers.dart';
import '../../app/session_providers.dart';
import '../../app/stores.dart';
import '../chat/chat_view.dart';
import 'bridge_login_flow.dart';
import 'matrix_bot_channel.dart';

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

/// What one network's row knows about its connection.
typedef _NetworkStatus = ({
  BridgeWhoami? whoami,
  BridgeException? error,
  bool checking,
});

/// The messengers this account can connect, and whether each one is.
///
/// Sennit hosts nothing — every bridge here is one the server runs. What a
/// person sees is not bridges, though: it is WhatsApp, Signal and Telegram,
/// each with a sentence saying whether it is connected and one button that
/// does the obvious next thing. Which door the connection goes through — the
/// bridge's provisioning API when the server publishes it, the bot's chat when
/// it does not — is decided here and never shown.
///
/// A bridge can still be added by its provisioning URL, for servers that
/// publish one nowhere Sennit can find it; that lives under the overflow menu
/// because nobody who has never heard of a provisioning URL needs to see it.
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

  /// Bridges whose bot exists on the homeserver but shares no room yet.
  List<DetectedBridge> _probed = const [];

  /// Provisioning APIs the homeserver publishes, by network.
  Map<ChatNetwork, Uri> _endpoints = const {};

  final Map<ChatNetwork, _NetworkStatus> _status = {};

  @override
  void initState() {
    super.initState();
    _bridges = _loadBridges(ref.read(storesProvider).settings);
    _detect();
    _probeAll();
    unawaited(_discover());
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
          final before = _networks.map((found) => found.network).toSet();
          _detect();
          final added = _networks.where(
            (found) => !before.contains(found.network),
          );
          if (added.isEmpty) return;
          setState(() {});
          for (final found in added) {
            unawaited(_check(found));
          }
        });
      }
    } on Object {
      // No heartbeat, no retries — the single detect above already ran.
    }
  }

  /// What the server already runs, from m.bridge state in joined rooms.
  void _detect() {
    final fromRooms = ref.read(detectedBridgesProvider);
    // The room scan is authoritative — it knows the room counts — so anything
    // it found keeps its entry and the probe's guess for that network is
    // dropped.
    final known = fromRooms.map((bridge) => bridge.network).toSet();
    _detected = [
      ...fromRooms,
      ..._probed.where((bridge) => !known.contains(bridge.network)),
    ];
  }

  /// Every network to offer: what detection found, plus what the server
  /// publishes an API for, minus what a hand-added bridge already covers.
  List<DetectedBridge> get _networks {
    final configured = _bridges.map((b) => b.networkId).toSet();
    final found = [
      for (final bridge in _detected)
        if (!configured.contains(bridge.network.id)) bridge,
    ];
    final listed = found.map((bridge) => bridge.network).toSet();
    return [
      ...found,
      for (final network in _endpoints.keys)
        if (!listed.contains(network) && !configured.contains(network.id))
          DetectedBridge(network: network),
    ];
  }

  /// Finds every bridge the server runs, then asks each how it is doing.
  ///
  /// The bot probe and the well-known lookup run once, on open: they are about
  /// which bridges exist, and that does not change while the screen is up.
  /// Failures are silent — a server that will not answer profile lookups for
  /// strangers, or publishes no bridges, is not an error to report.
  Future<void> _discover() async {
    final endpoints = ref.read(bridgeEndpointsProvider.future);
    final probed = _probeBots();
    final (found, bots) = await (endpoints, probed).wait;
    if (!mounted) return;
    setState(() {
      _endpoints = {
        for (final MapEntry(:key, :value) in found.entries)
          ChatNetwork.fromBridgeProtocol(key): value,
      };
      _probed = bots;
      _detect();
    });
    await Future.wait(_networks.map(_check));
  }

  Future<List<DetectedBridge>> _probeBots() async {
    if (kDemoMode) return const [];
    try {
      final session = ref.read(matrixSessionProvider);
      if (!session.isInitialized) return const [];
      final client = session.client;
      final homeserver = client.homeserver;
      final ownUserId = client.userID;
      if (homeserver == null || ownUserId == null) return const [];
      return await probeBridgeBots(
        homeserver: homeserver,
        ownUserId: ownUserId,
        httpClient: client.httpClient,
        accessToken: client.accessToken,
        skip: _detected.map((bridge) => bridge.network).toSet(),
      );
    } on Object {
      return const [];
    }
  }

  /// The way in for [found]: its published API when there is one, its bot's
  /// chat otherwise. Null when there is neither.
  BridgeLoginBackend? _backendFor(DetectedBridge found) {
    try {
      return ref.read(bridgeBackendFactoryProvider)(
        found.network,
        botUserId: found.botUserId,
        provisioningUrl: _endpoints[found.network],
      );
    } on Object {
      return null;
    }
  }

  /// Asks one network whether it is connected, and as whom.
  Future<void> _check(DetectedBridge found) async {
    final backend = _backendFor(found);
    if (backend == null) return;
    final previous = _status[found.network];
    setState(() {
      _status[found.network] = (
        whoami: previous?.whoami,
        error: null,
        checking: true,
      );
    });
    _NetworkStatus result;
    try {
      result = (whoami: await backend.whoami(), error: null, checking: false);
    } on BridgeException catch (e) {
      result = (whoami: null, error: e, checking: false);
    } finally {
      backend.dispose();
    }
    if (!mounted) return;
    setState(() => _status[found.network] = result);
    // A check finishing is a spinner giving way to a sentence, in a row that
    // may be well off screen — and this screen exists to answer "is it
    // working?", so the answer is said out loud.
    announce(
      context,
      '${found.network.label}: ${_statusLine(context.l10n, found, result)}',
    );
  }

  /// Signs in to [found], or back in to [reloginId].
  Future<void> _connect(DetectedBridge found, {String? reloginId}) async {
    final backend = _backendFor(found);
    if (backend == null) return;
    final botUserId =
        found.botUserId ?? _status[found.network]?.whoami?.botUserId;
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (flowContext) => BridgeLoginFlowScreen(
          client: backend,
          network: found.network,
          reloginId: reloginId,
          onUseAdminRoom: botUserId == null
              ? null
              : () {
                  Navigator.of(flowContext).pop(false);
                  unawaited(_openBotChat(botUserId));
                },
        ),
      ),
    );
    backend.dispose();
    if (mounted) await _check(found);
  }

  Future<void> _disconnect(DetectedBridge found, BridgeLogin login) async {
    if (!await _confirmDisconnect(found.network.label, login.label)) return;
    final backend = _backendFor(found);
    if (backend == null) return;
    try {
      await backend.logout(login.id);
    } on BridgeException {
      if (mounted) {
        showWeftMessage(
          context,
          context.l10n.bridgesDisconnectFailed(found.network.label),
        );
      }
    } finally {
      backend.dispose();
    }
    if (mounted) await _check(found);
  }

  Future<bool> _confirmDisconnect(String network, String account) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bridgesDisconnectTitle(network, account)),
        content: Text(context.l10n.bridgesDisconnectBody(network)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.bridgesDisconnect),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  BridgeProvisioningClient _clientFor(_StoredBridge bridge) {
    final client = ref.read(matrixSessionProvider).client;
    return BridgeProvisioningClient(
      baseUrl: Uri.parse(bridge.url),
      accessToken: client.accessToken ?? '',
      userId: client.userID,
    );
  }

  Future<void> _probeAll() async {
    for (final bridge in _bridges) {
      await _probe(bridge);
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_probeAll(), ..._networks.map(_check)]);
  }

  Future<void> _probe(_StoredBridge bridge) async {
    final name = ChatNetwork.fromId(bridge.networkId).label;
    final client = _clientFor(bridge);
    try {
      final whoami = await client.whoami();
      if (!mounted) return;
      setState(() {
        _health[bridge.id] = whoami;
        _errors.remove(bridge.id);
      });
      announce(
        context,
        '${whoami.networkName ?? name}: ${_reachedLabel(whoami)}',
      );
    } on BridgeException catch (e) {
      if (!mounted) return;
      // The bridge's own sentence when it sent one — it is specific and
      // already in whatever language the bridge speaks — and Sennit's
      // translated one for a status code the bridge said nothing about.
      final reason = context.l10n.bridgeFailure(e) ?? e.message;
      setState(() {
        _health[bridge.id] = null;
        _errors[bridge.id] = reason;
      });
      announce(context, context.l10n.bridgesUnreachable(name, reason));
    } finally {
      client.dispose();
    }
  }

  Future<void> _addBridge() async {
    final url = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bridgesAddTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.bridgesAddBody),
            const SizedBox(height: WeftSpace.md),
            WeftLabelledField(
              label: context.l10n.bridgesProvisioningUrlField,
              child: TextField(
                controller: url,
                autofocus: true,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: context.l10n.bridgesProvisioningUrlField,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(url.text.trim()),
            child: Text(context.l10n.commonAdd),
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
      if (mounted) showWeftMessage(context, context.l10n.bridgesNotAUrl);
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
  /// Kept for what the guided flow does not cover — a bridge's settings, its
  /// help, a sign-in that needs a browser — and kept out of the way under
  /// "Advanced", because reading a bot's replies is exactly what the guided
  /// flow exists to spare people.
  Future<void> _openBotChat(String botUserId) async {
    final client = ref.read(matrixSessionProvider).client;
    final repository = ref.read(chatRepositoryProvider);

    final String roomId;
    try {
      roomId = await client.startDirectChat(botUserId);
    } on Exception catch (e) {
      if (mounted) {
        showWeftMessage(context, context.l10n.bridgesOpenChatFailed('$e'));
      }
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

  Future<void> _startLogin(_StoredBridge bridge, {String? reloginId}) async {
    final client = _clientFor(bridge);
    final network = ChatNetwork.fromId(bridge.networkId);
    final botUserId =
        _health[bridge.id]?.botUserId ??
        _detected
            .where((d) => d.network.id == bridge.networkId)
            .map((d) => d.botUserId)
            .firstWhere((id) => id != null, orElse: () => null);

    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (flowContext) => BridgeLoginFlowScreen(
          client: client,
          network: network,
          flows: (_health[bridge.id]?.flows.isEmpty ?? true)
              ? null
              : _health[bridge.id]!.flows,
          bridgeLabel: _health[bridge.id]?.networkName,
          reloginId: reloginId,
          onUseAdminRoom: botUserId == null
              ? null
              : () {
                  Navigator.of(flowContext).pop(false);
                  unawaited(_openBotChat(botUserId));
                },
        ),
      ),
    );
    client.dispose();
    if (mounted) await _probe(bridge);
  }

  Future<void> _logoutStored(_StoredBridge bridge, BridgeLogin login) async {
    final name =
        _health[bridge.id]?.networkName ??
        ChatNetwork.fromId(bridge.networkId).label;
    if (!await _confirmDisconnect(name, login.label)) return;
    final client = _clientFor(bridge);
    try {
      await client.logout(login.id);
    } on BridgeException {
      if (mounted) {
        showWeftMessage(context, context.l10n.bridgesDisconnectFailed(name));
      }
    } finally {
      client.dispose();
    }
    if (mounted) await _probe(bridge);
  }

  @override
  Widget build(BuildContext context) {
    final networks = _networks;
    return Scaffold(
      appBar: WeftAppBar(
        title: Text(context.l10n.commonBridges),
        actions: [
          IconButton(
            tooltip: context.l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
          PopupMenuButton<void>(
            tooltip: context.l10n.bridgesAdvanced,
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: _addBridge,
                child: Text(context.l10n.bridgesAddManually),
              ),
            ],
          ),
        ],
      ),
      body: networks.isEmpty && _bridges.isEmpty
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(WeftSpace.xl),
                  child: Text(
                    context.l10n.bridgesNoneOffered,
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          : WeftReadingPane(
              child: ListView(
                padding: const EdgeInsets.all(WeftSpace.md),
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      WeftSpace.sm,
                      WeftSpace.xs,
                      WeftSpace.sm,
                      WeftSpace.md,
                    ),
                    child: Text(
                      context.l10n.bridgesIntro,
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (networks.isNotEmpty)
                    _NetworkGroup(
                      children: [
                        for (final found in networks)
                          _NetworkRow(
                            found: found,
                            status: _status[found.network],
                            canConnect:
                                found.botUserId != null ||
                                _endpoints.containsKey(found.network),
                            onConnect: () => _connect(found),
                            onReconnect: (login) =>
                                _connect(found, reloginId: login.id),
                            onDisconnect: (login) => _disconnect(found, login),
                            onRetry: () => _check(found),
                            onOpenChat: found.botUserId == null
                                ? null
                                : () => _openBotChat(found.botUserId!),
                            onAddUrl: _addBridge,
                          ),
                      ],
                    ),
                  if (_bridges.isNotEmpty && networks.isNotEmpty)
                    const Divider(height: WeftSpace.xl),
                  for (final bridge in _bridges)
                    _BridgeCard(
                      bridge: bridge,
                      whoami: _health[bridge.id],
                      error: _errors[bridge.id],
                      onLogin: () => _startLogin(bridge),
                      onReconnect: (login) =>
                          _startLogin(bridge, reloginId: login.id),
                      onRemove: () => _removeBridge(bridge),
                      onLogout: (login) => _logoutStored(bridge, login),
                    ),
                ],
              ),
            ),
    );
  }
}

/// The sentence under a network's name.
String _statusLine(AppL10n l10n, DetectedBridge found, _NetworkStatus? status) {
  if (status == null) {
    return found.roomCount > 0
        ? l10n.bridgesStatusChats(found.roomCount)
        : l10n.bridgesStatusNotConnected;
  }
  if (status.error != null) return l10n.bridgesStatusOffline;
  final whoami = status.whoami;
  if (whoami == null) return l10n.bridgeFlowConnecting;
  if (whoami.logins.isEmpty) return l10n.bridgesStatusNotConnected;
  return [
    for (final login in whoami.logins) _loginLine(l10n, login),
  ].join('\n');
}

String _loginLine(AppL10n l10n, BridgeLogin login) => switch (login.state) {
  BridgeLoginState.connected => l10n.bridgesStatusConnectedAs(login.label),
  BridgeLoginState.connecting => l10n.bridgesStatusConnecting(login.label),
  BridgeLoginState.transientDisconnect => l10n.bridgesStatusInterrupted(
    login.label,
  ),
  BridgeLoginState.badCredentials ||
  BridgeLoginState.unknown => l10n.bridgesStatusNeedsLogin(login.label),
};

/// The bridges this homeserver appears to run.
///
/// A provider rather than a call inside the screen, and that is the whole
/// point of it: reading the session directly meant this list was empty in
/// every build that has no session — a demo run, a widget test, a golden — so
/// the only state anyone could ever *look* at was the empty one. The section
/// went unexamined for exactly as long as it stayed unfillable, and a person
/// running five bridges saw a layout nobody had seen.
final detectedBridgesProvider = Provider<List<DetectedBridge>>((ref) {
  if (kDemoMode) return _demoDetected;
  try {
    final session = ref.read(matrixSessionProvider);
    if (!session.isInitialized) return const [];
    return detectBridges(session.client);
  } on Object {
    // No session, or a half-loaded room mid-sync. The screen's heartbeat asks
    // again.
    return const [];
  }
});

/// What a homeserver with bridges on it looks like, for the demo build.
///
/// Several, because that is the case worth drawing: one is a row and a handful
/// is a list with rhythm to get wrong. The three states a row can be in are all
/// present — busy, found-but-unused, and no bot to sign in through.
const List<DetectedBridge> _demoDetected = [
  DetectedBridge(
    network: ChatNetwork.whatsapp,
    botUserId: '@whatsappbot:example.org',
    roomCount: 64,
  ),
  DetectedBridge(
    network: ChatNetwork.signal,
    botUserId: '@signalbot:example.org',
    roomCount: 31,
  ),
  DetectedBridge(
    network: ChatNetwork.telegram,
    botUserId: '@telegrambot:example.org',
    roomCount: 39,
  ),
  DetectedBridge(
    network: ChatNetwork.instagram,
    botUserId: '@instagrambot:example.org',
    roomCount: 12,
  ),
  // Not signed into yet: found by its bot alone, with no portal rooms behind
  // it. This is what every bridge looks like before its first login, and the
  // shape that used to be missing from the screen entirely.
  DetectedBridge(
    network: ChatNetwork.discord,
    botUserId: '@discordbot:example.org',
  ),
  // No bot id: the case that offers a provisioning URL instead of a sign-in.
  DetectedBridge(network: ChatNetwork.slack, roomCount: 7),
];

/// Provisioning APIs the homeserver publishes in its well-known, keyed by the
/// network id it names them under.
///
/// Empty on a server that publishes none, which is every server today but the
/// ones set up for Sennit — and then every network goes through its bot's
/// chat instead, which works everywhere.
final bridgeEndpointsProvider = FutureProvider<Map<String, Uri>>((ref) async {
  if (kDemoMode) return const {};
  try {
    final session = ref.read(matrixSessionProvider);
    if (!session.isInitialized) return const {};
    final client = session.client;
    final homeserver = client.homeserver;
    if (homeserver == null) return const {};
    final wellKnown = await client.getWellknown();
    return parseBridgeWellKnown(wellKnown.toJson(), homeserver: homeserver);
  } on Object {
    return const {};
  }
});

/// Builds the way in to one network's bridge.
typedef BridgeBackendFactory =
    BridgeLoginBackend? Function(
      ChatNetwork network, {
      String? botUserId,
      Uri? provisioningUrl,
    });

/// The bridge's own API when its address is known, its bot's chat when only
/// the bot is. A provider so tests can hand the screen a scripted bridge.
final bridgeBackendFactoryProvider = Provider<BridgeBackendFactory>((ref) {
  return (network, {botUserId, provisioningUrl}) {
    if (kDemoMode) return null;
    final session = ref.read(matrixSessionProvider);
    if (!session.isInitialized) return null;
    final client = session.client;
    if (provisioningUrl != null) {
      return BridgeProvisioningClient(
        baseUrl: provisioningUrl,
        accessToken: client.accessToken ?? '',
        userId: client.userID,
      );
    }
    if (botUserId != null) {
      return BridgeCommandClient(
        channel: MatrixBotChannel(client: client, botUserId: botUserId),
      );
    }
    return null;
  };
});

/// The networks as one grouped list.
///
/// A box with hairlines between its rows rather than separate cards with
/// gaps: that is how every desktop draws a list of like things — macOS System
/// Settings, GNOME's boxed lists, Windows' settings cards — and five floating
/// panels for five rows of the same shape reads as five unrelated objects.
class _NetworkGroup extends StatelessWidget {
  const _NetworkGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: WeftSpace.sm),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(
          context.isDesktop ? 10 : WeftRadius.md.x,
        ),
        border: Border.all(color: context.palette.border, width: 0.5),
      ),
      child: Column(
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                // Indented past the glyph, so the rule separates the text
                // rather than cutting the row in half.
                indent: 52,
                color: context.palette.divider,
              ),
            child,
          ],
        ],
      ),
    );
  }
}

/// One messenger: whether it is connected, and the one obvious next step.
///
/// The button is whatever the state calls for — Connect when nothing is,
/// Reconnect when an account was signed out, nothing when all is well — and
/// the rarer things (a second account, disconnecting, the bridge's own chat)
/// wait in the row's menu.
class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.found,
    required this.status,
    required this.canConnect,
    required this.onConnect,
    required this.onReconnect,
    required this.onDisconnect,
    required this.onRetry,
    required this.onAddUrl,
    this.onOpenChat,
  });

  final DetectedBridge found;
  final _NetworkStatus? status;

  /// Whether there is any way in at all: a bot to talk to or an API.
  final bool canConnect;
  final VoidCallback onConnect;
  final ValueChanged<BridgeLogin> onReconnect;
  final ValueChanged<BridgeLogin> onDisconnect;
  final VoidCallback onRetry;
  final VoidCallback onAddUrl;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = found.network.label;
    final logins = status?.whoami?.logins ?? const <BridgeLogin>[];
    final broken = logins.where((l) => l.state.needsAttention).firstOrNull;
    final checking = status?.checking ?? false;
    final failed = status?.error != null;

    final Widget? primary;
    if (!canConnect) {
      primary = OutlinedButton(
        onPressed: onAddUrl,
        child: Text(l10n.bridgesAddManually),
      );
    } else if (checking && status?.whoami == null) {
      primary = null;
    } else if (failed) {
      primary = OutlinedButton(
        onPressed: onRetry,
        child: Text(l10n.settingsTryAgain),
      );
    } else if (broken != null) {
      primary = FilledButton(
        onPressed: () => onReconnect(broken),
        child: Text(l10n.bridgesReconnect),
      );
    } else if (logins.isEmpty) {
      primary = FilledButton.tonal(
        onPressed: onConnect,
        child: Text(l10n.bridgesConnect),
      );
    } else {
      primary = null;
    }

    final menu = <PopupMenuEntry<void>>[
      if (canConnect && logins.isNotEmpty)
        PopupMenuItem(
          onTap: onConnect,
          child: Text(l10n.bridgesAddAnotherAccount),
        ),
      for (final login in logins)
        PopupMenuItem(
          onTap: () => onDisconnect(login),
          child: Text(
            logins.length == 1
                ? l10n.bridgesDisconnect
                : l10n.bridgesDisconnectAccount(login.label),
          ),
        ),
      if (onOpenChat != null) ...[
        if (logins.isNotEmpty || canConnect) const PopupMenuDivider(),
        PopupMenuItem(
          onTap: onOpenChat,
          child: Text(l10n.bridgesAdvancedOpenChat(name)),
        ),
      ],
    ];

    final dotColor = failed || broken != null
        ? context.colors.error
        : logins.isEmpty
        ? null
        // Green only when everything is: a hiccup the bridge is retrying on
        // its own is neither fine nor the person's to fix.
        : logins.every((l) => l.state == BridgeLoginState.connected)
        ? context.palette.online
        : context.colors.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.md,
        vertical: WeftSpace.sm,
      ),
      child: Row(
        children: [
          NetworkGlyph(network: found.network, size: 28, semanticsLabel: ''),
          const SizedBox(width: WeftSpace.md),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: context.text.titleSmall),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (dotColor != null) ...[
                        // The colour half of what the sentence already says.
                        ExcludeSemantics(
                          child: Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(top: 5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: dotColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: WeftSpace.xs),
                      ],
                      Flexible(
                        child: Text(
                          _statusLine(l10n, found, status),
                          style: context.text.bodySmall?.copyWith(
                            color: failed || broken != null
                                ? context.colors.error
                                : context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: WeftSpace.sm),
          if (checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: WeftSpace.sm),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ?primary,
          if (menu.isNotEmpty)
            PopupMenuButton<void>(
              tooltip: l10n.bridgesMoreActions(name),
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              itemBuilder: (_) => menu,
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
    required this.onReconnect,
    required this.onRemove,
    required this.onLogout,
  });

  final _StoredBridge bridge;
  final BridgeWhoami? whoami;
  final String? error;
  final VoidCallback onLogin;
  final ValueChanged<BridgeLogin> onReconnect;
  final VoidCallback onRemove;
  final ValueChanged<BridgeLogin> onLogout;

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
                  tooltip: context.l10n.bridgesActionsFor(
                    whoami?.networkName ?? network.label,
                  ),
                  onSelected: (choice) {
                    if (choice == 'remove') onRemove();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(context.l10n.bridgesRemove),
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
                        label: context.l10n.bridgesNotReachable(error!),
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
                label: context.l10n.bridgesChecking(network.label),
                child: const LinearProgressIndicator(minHeight: 2),
              )
            else if (whoami!.logins.isEmpty)
              Text(
                context.l10n.bridgesNotSignedIn(
                  whoami!.networkName ?? network.label,
                ),
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
                          context.l10n.bridgesLoginState(
                            login.label,
                            login.state.name,
                            login.errorMessage == null
                                ? ''
                                : ' (${login.errorMessage})',
                          ),
                          style: context.text.bodySmall,
                        ),
                      ),
                      // Three accounts on one bridge is three buttons reading
                      // "Sign out", and signing out of the wrong one costs a
                      // full re-pairing.
                      if (login.state.needsAttention)
                        TextButton(
                          onPressed: () => onReconnect(login),
                          child: Text(context.l10n.bridgesReconnect),
                        ),
                      NamedButton(
                        label: context.l10n.bridgesSignOutOf(login.label),
                        onPressed: () => onLogout(login),
                        child: TextButton(
                          onPressed: () => onLogout(login),
                          child: Text(context.l10n.bridgesDisconnect),
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
                      ? context.l10n.loginSignIn
                      : context.l10n.bridgesAddAnotherAccount,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
