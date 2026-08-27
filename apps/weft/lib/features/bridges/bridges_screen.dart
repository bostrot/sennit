import 'dart:async';

import 'package:flutter/material.dart';
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
import 'bot_login_screen.dart';
import 'bridge_login_flow.dart';

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

  /// Bridges whose bot exists on the homeserver but shares no room yet.
  List<DetectedBridge> _probed = const [];

  @override
  void initState() {
    super.initState();
    _bridges = _loadBridges(ref.read(storesProvider).settings);
    _detect();
    _probeAll();
    _probeBots();
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

  /// Asks the homeserver about the bridge bots no room mentioned.
  ///
  /// Once, on open: the answer is about which accounts exist on the server, and
  /// that does not change while the screen is up. Failures are silent — a
  /// server that will not answer profile lookups for strangers is not an error
  /// to report, it just means this screen knows what the rooms told it.
  Future<void> _probeBots() async {
    if (kDemoMode) return;
    final List<DetectedBridge> probed;
    try {
      final session = ref.read(matrixSessionProvider);
      if (!session.isInitialized) return;
      final client = session.client;
      final homeserver = client.homeserver;
      final ownUserId = client.userID;
      if (homeserver == null || ownUserId == null) return;
      probed = await probeBridgeBots(
        homeserver: homeserver,
        ownUserId: ownUserId,
        httpClient: client.httpClient,
        accessToken: client.accessToken,
        skip: _detected.map((bridge) => bridge.network).toSet(),
      );
    } on Object {
      return;
    }
    if (!mounted || probed.isEmpty) return;
    setState(() {
      _probed = probed;
      _detect();
    });
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

    final network = ChatNetwork.values.firstWhere(
      (n) => n.id == bridge.networkId,
      orElse: () => ChatNetwork.matrix,
    );
    // The management-room fallback needs the bot's id, which discovery finds
    // and a hand-typed provisioning URL does not carry. Null means the cookie
    // step has nowhere to send the user, and it says so rather than offering a
    // button that goes nowhere.
    final botUserId = _detected
        .where((d) => d.network.id == bridge.networkId)
        .map((d) => d.botUserId)
        .firstWhere((id) => id != null, orElse: () => null);

    // One screen for the whole journey — picking a flow included. It used to
    // start with a sheet of untitled list rows and continue on a different
    // screen, which made "sign in to WhatsApp" read as two unrelated tasks.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BridgeLoginFlowScreen(
          client: client,
          network: network,
          flows: flows,
          bridgeLabel: _health[bridge.id]?.networkName,
          onUseAdminRoom: botUserId == null
              ? null
              : () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => BridgeBotLoginScreen(
                      botUserId: botUserId,
                      network: network,
                    ),
                  ),
                ),
        ),
      ),
    );
    await _probe(bridge);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WeftAppBar(
        title: const Text('Bridges'),
        actions: [
          // A desktop has a toolbar, so the page's primary action belongs in
          // it. A floating button hovering over the bottom-right corner of a
          // window is the single most recognisable phone idiom there is.
          if (context.isDesktop)
            TextButton.icon(
              onPressed: _addBridge,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add bridge'),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _probeAll,
          ),
        ],
      ),
      floatingActionButton: context.isDesktop
          ? null
          : FloatingActionButton.extended(
              onPressed: _addBridge,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add bridge'),
            ),
      body: _bridges.isEmpty && _detected.isEmpty
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(WeftSpace.xl),
                  child: Text(
                    'No bridges yet.\n\nBraid connects to bridges you run on '
                    'your own server — mautrix-whatsapp, -signal, -telegram '
                    'and friends. Add one by its provisioning URL.',
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
                    _DetectedGroup(
                      found: [
                        for (final found in _detected)
                          if (!_bridges.any(
                            (b) => b.networkId == found.network.id,
                          ))
                            found,
                      ],
                      onSignIn: (found) => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BridgeBotLoginScreen(
                            botUserId: found.botUserId!,
                            network: found.network,
                          ),
                        ),
                      ),
                      onOpenChat: (found) => _openBotChat(found.botUserId!),
                      onAddUrl: _addBridge,
                    ),
                    // Only when something follows it. A divider under the last
                    // detected bridge with no configured ones after it is a rule
                    // separating a list from nothing.
                    if (_bridges.isNotEmpty)
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
            ),
    );
  }
}

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

/// The detected bridges as one grouped list.
///
/// A box with hairlines between its rows rather than five separate cards with
/// gaps: that is how every desktop draws a list of like things — macOS System
/// Settings, GNOME's boxed lists, Windows' settings cards — and five floating
/// panels for five rows of the same shape reads as five unrelated objects.
class _DetectedGroup extends StatelessWidget {
  const _DetectedGroup({
    required this.found,
    required this.onSignIn,
    required this.onOpenChat,
    required this.onAddUrl,
  });

  final List<DetectedBridge> found;
  final ValueChanged<DetectedBridge> onSignIn;
  final ValueChanged<DetectedBridge> onOpenChat;
  final VoidCallback onAddUrl;

  @override
  Widget build(BuildContext context) {
    if (found.isEmpty) return const SizedBox.shrink();
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
          for (final (index, bridge) in found.indexed) ...[
            if (index > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                // Indented past the glyph, so the rule separates the text
                // rather than cutting the row in half.
                indent: 52,
                color: context.palette.divider,
              ),
            _DetectedBridgeCard(
              found: bridge,
              onSignIn: bridge.botUserId == null
                  ? null
                  : () => onSignIn(bridge),
              onOpenChat: bridge.botUserId == null
                  ? null
                  : () => onOpenChat(bridge),
              onAddUrl: onAddUrl,
            ),
          ],
        ],
      ),
    );
  }
}

/// A bridge found on the homeserver that Braid is not configured for yet.
///
/// Was a `ListTile` with two buttons inside its `subtitle`, which is a slot for
/// one line of secondary text. Under the desktop's compact density the tile
/// could not size itself around them, so each row's buttons ended up eleven
/// points from the *next* row's name and read as belonging to it — five
/// bridges as one run of interleaved text and controls.
///
/// It is a card now, the same one a configured bridge gets, with its actions
/// at the trailing edge where a wide window has room for them.
class _DetectedBridgeCard extends StatelessWidget {
  const _DetectedBridgeCard({
    required this.found,
    required this.onSignIn,
    required this.onOpenChat,
    required this.onAddUrl,
  });

  final DetectedBridge found;
  final VoidCallback? onSignIn;
  final VoidCallback? onOpenChat;
  final VoidCallback onAddUrl;

  /// What was actually found, in words.
  ///
  /// A bridge is listed on the strength of its bot alone, which is how one you
  /// have not signed into yet gets here — and for that one the count is zero.
  /// "0 bridged chat(s)" reads as a broken bridge rather than an unused one.
  String get _subtitle {
    final chats = switch (found.roomCount) {
      0 => 'No chats bridged yet',
      1 => '1 bridged chat',
      final count => '$count bridged chats',
    };
    return found.botUserId == null ? chats : '$chats · ${found.botUserId}';
  }

  @override
  Widget build(BuildContext context) {
    // Sign-in first: the guided flow talks to the bot's management room, which
    // every mautrix bridge has and which needs no provisioning URL. The plain
    // chat stays for everything else the bot can do, and the URL flow lives
    // behind "Add bridge" for the richer API.
    final actions = <Widget>[
      if (onSignIn != null) ...[
        FilledButton.tonalIcon(
          onPressed: onSignIn,
          icon: const WeftMirroredIcon(Icons.login_rounded, size: 15),
          label: const Text('Sign in'),
        ),
        const SizedBox(width: WeftSpace.sm),
        OutlinedButton.icon(
          onPressed: onOpenChat,
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
          label: const Text('Open chat'),
        ),
      ] else
        OutlinedButton(
          onPressed: onAddUrl,
          child: const Text('Add provisioning URL'),
        ),
    ];

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(found.network.label, style: context.text.titleSmall),
        const SizedBox(height: 2),
        Text(
          _subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.labelSmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.md,
        vertical: WeftSpace.sm,
      ),
      // Trailing on a desktop, where the row is wide enough to hold them;
      // under the name on a phone, since two buttons and a bot id do not
      // share four hundred points.
      child: context.isDesktop
          ? Row(
              children: [
                NetworkGlyph(
                  network: found.network,
                  size: 28,
                  semanticsLabel: '',
                ),
                const SizedBox(width: WeftSpace.md),
                Expanded(child: name),
                const SizedBox(width: WeftSpace.md),
                Row(mainAxisSize: MainAxisSize.min, children: actions),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    NetworkGlyph(
                      network: found.network,
                      size: 30,
                      semanticsLabel: '',
                    ),
                    const SizedBox(width: WeftSpace.md),
                    Expanded(child: name),
                  ],
                ),
                const SizedBox(height: WeftSpace.sm),
                Wrap(
                  spacing: WeftSpace.sm,
                  runSpacing: WeftSpace.sm,
                  children: actions
                      .where((w) => w is! SizedBox)
                      .toList(growable: false),
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
