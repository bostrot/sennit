import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:weft_remote/weft_remote.dart';
import 'package:weft_store/weft_store.dart';

import '../services/backup/backup_service.dart' show kSennitVersion;
import '../services/background/background_work.dart';
import '../services/remote/remote_protocol.dart';
import '../services/web/pairing_registry.dart';
import '../services/web/relay_connection.dart';
import '../services/web/sennit_web_server.dart';
import '../services/web/web_bundle_store.dart';
import 'localisation.dart';
import 'providers.dart';
import 'session_providers.dart';
import 'stores.dart';

/// Where Sennit Web's files come from and go to. Overridden by tests.
final webBundleStoreProvider = Provider<WebBundleStore>(
  (ref) => WebBundleStore(version: kSennitVersion),
);

/// The installed browser bundle, and the download in progress, if any.
class WebBundleController extends Notifier<WebBundleState> {
  StreamSubscription<WebBundleState>? _download;

  @override
  WebBundleState build() {
    ref.onDispose(() => _download?.cancel());
    unawaited(_load());
    return const WebBundleAbsent();
  }

  Future<void> _load() async {
    final current = await ref.read(webBundleStoreProvider).current();
    if (_download == null) state = current;
  }

  void download() {
    if (_download != null) return;
    _download = ref
        .read(webBundleStoreProvider)
        .download()
        .listen((next) => state = next, onDone: () => _download = null);
  }

  Future<void> remove() async {
    await _download?.cancel();
    _download = null;
    await ref.read(webBundleStoreProvider).remove();
    state = const WebBundleAbsent();
  }
}

final webBundleProvider = NotifierProvider<WebBundleController, WebBundleState>(
  WebBundleController.new,
);

/// Whether Sennit Web is being served, and to whom.
class SennitWebServing {
  const SennitWebServing({
    this.running = false,
    this.port,
    this.addresses = const [],
    this.connected = 0,
    this.phoneKey,
    this.failed = false,
    this.relay = RelayStatus.off,
    this.relayAddress,
  });

  /// The LAN listener is open.
  final bool running;
  final int? port;

  /// This device's LAN addresses, for the address shown and the QR code.
  final List<String> addresses;

  /// Browsers connected right now, on either path.
  final int connected;

  /// The static public key a pairing URL carries, base64url.
  final String? phoneKey;

  /// The last start failed — the port is taken, usually.
  final bool failed;

  /// The line out to the relay, when one is set up.
  final RelayStatus relay;

  /// Where a browser opens this device through the relay.
  final Uri? relayAddress;

  /// Where a browser on the same network opens Sennit Web.
  List<Uri> get urls => [
    for (final a in addresses) Uri(scheme: 'http', host: a, port: port),
  ];

  SennitWebServing copyWith({
    bool? running,
    int? port,
    List<String>? addresses,
    int? connected,
    String? phoneKey,
    bool? failed,
    RelayStatus? relay,
    Uri? relayAddress,
  }) => SennitWebServing(
    running: running ?? this.running,
    port: port ?? this.port,
    addresses: addresses ?? this.addresses,
    connected: connected ?? this.connected,
    phoneKey: phoneKey ?? this.phoneKey,
    failed: failed ?? this.failed,
    relay: relay ?? this.relay,
    relayAddress: relayAddress ?? this.relayAddress,
  );
}

/// The port Sennit Web listens on — fixed rather than random, so a bookmark
/// keeps working from one session to the next.
const int kSennitWebPort = 8787;

/// The relay this device dials out to, as typed in. Local to the device: a
/// relay is reached by the device serving, like the pairing it carries.
const String kSennitWebRelayUrl = 'web.relay_url';

/// Starts and stops the server and the relay line, and keeps their hosts
/// current.
///
/// Off unless switched on, and off again when the app closes: serving is a
/// decision made for a moment, not a standing setting.
class SennitWebController extends Notifier<SennitWebServing> {
  SennitWebServer? _server;
  RelayConnection? _relay;
  StreamSubscription<void>? _changes;
  StreamSubscription<RelayStatus>? _relayStatus;

  /// The foreground job that keeps an Android phone serving with the app in
  /// the background; its ongoing notification is the system-wide sign that
  /// Sennit Web is on. A no-op on platforms without one.
  BackgroundWorkHandle? _keepAlive;

  PairingRegistry? _registry;

  PairingRegistry get registry =>
      _registry ?? PairingRegistry(ref.read(storesProvider).settings);

  /// The relay address typed in, if any.
  String? get relayUrl =>
      ref.read(storesProvider).settings.getString(kSennitWebRelayUrl);

  @override
  SennitWebServing build() {
    // Settings changed on the phone reach the connected browsers.
    ref.listen(settingsRevisionProvider, (_, _) {
      for (final s in _server?.sessions ?? const <WebSession>[]) {
        s.host.refresh();
      }
    });
    ref.onDispose(() {
      _keepAlive?.end();
      unawaited(_changes?.cancel());
      unawaited(_relayStatus?.cancel());
      unawaited(_relay?.stop());
      unawaited(_server?.stop());
    });
    return const SennitWebServing();
  }

  /// The server object both paths share, made on first use.
  Future<SennitWebServer?> _ensureServer() async {
    if (_server case final server?) return server;
    final bundle = ref.read(webBundleProvider);
    if (bundle is! WebBundleReady) return null;
    final stores = ref.read(storesProvider);
    final key = await _staticKey(stores);
    final pairing = _registry = PairingRegistry(stores.settings);
    final server = _server = SennitWebServer(
      bundle: bundle.directory,
      key: key,
      registry: pairing,
      repository: () => ref.read(chatRepositoryProvider),
      deviceName: Platform.localHostname,
      port: kSennitWebPort,
      extraHandlers: {RemoteMethods.mediaFetch: _fetchMedia},
      settings: () => _shareableSettings(stores),
    );
    _changes = server.changes.listen((_) => _publish());
    state = state.copyWith(phoneKey: key.publicId);
    return server;
  }

  /// Opens Sennit Web to browsers on this network.
  Future<void> start() async {
    if (state.running) return;
    final server = await _ensureServer();
    if (server == null) return;
    try {
      await server.start();
    } on SocketException {
      state = state.copyWith(failed: true);
      await _shutDownIfIdle();
      return;
    }
    state = state.copyWith(
      running: true,
      failed: false,
      port: server.boundPort,
      addresses: await SennitWebServer.lanAddresses(),
    );
    _holdKeepAlive();
  }

  Future<void> stop() async {
    await _server?.stopListening();
    state = SennitWebServing(
      phoneKey: state.phoneKey,
      relay: state.relay,
      relayAddress: state.relayAddress,
      connected: state.connected,
    );
    await _shutDownIfIdle();
  }

  /// Dials out to the relay at [url], remembering it for next time.
  Future<void> startRelay(Uri url) async {
    if (_relay != null) return;
    final server = await _ensureServer();
    if (server == null) return;
    final stores = ref.read(storesProvider);
    stores.settings.setString(kSennitWebRelayUrl, url.toString());
    var secret = await stores.secrets.read(SecretStore.sennitWebRelaySecret);
    if (secret == null) {
      secret = RelayConnection.newSecret();
      await stores.secrets.write(SecretStore.sennitWebRelaySecret, secret);
    }
    final relay = _relay = RelayConnection(
      relay: url,
      secret: secret,
      server: server,
    );
    _relayStatus = relay.statuses.listen(
      (status) => state = state.copyWith(relay: status),
    );
    state = state.copyWith(relayAddress: relay.address);
    relay.start();
    _holdKeepAlive();
  }

  Future<void> stopRelay() async {
    await _relayStatus?.cancel();
    _relayStatus = null;
    await _relay?.stop();
    _relay = null;
    for (final s in [...?_server?.sessions]) {
      if (s.relayed) s.host.dispose();
    }
    state = SennitWebServing(
      running: state.running,
      port: state.port,
      addresses: state.addresses,
      phoneKey: state.phoneKey,
      connected: state.connected,
      failed: state.failed,
    );
    await _shutDownIfIdle();
  }

  void _holdKeepAlive() {
    _keepAlive ??= ref
        .read(backgroundWorkProvider)
        .begin(
          weftPlatformL10n().sennitWebServingBanner,
          detail: (state.urls.firstOrNull ?? state.relayAddress)?.toString(),
        );
  }

  /// Once neither path is open, nothing is served and nothing is kept awake.
  Future<void> _shutDownIfIdle() async {
    if (state.running || _relay != null) return;
    _keepAlive?.end();
    _keepAlive = null;
    await _changes?.cancel();
    _changes = null;
    await _server?.stop();
    _server = null;
    _registry?.cancelToken();
    _registry = null;
  }

  /// A pairing address with a fresh one-time token, for the QR code: through
  /// the relay when [relayed], on this network otherwise. A browser keeps its
  /// pairing per address, so each path is paired on its own.
  Uri? pairingUrl({bool relayed = false}) {
    final s = state;
    final pairing = _registry;
    if (pairing == null || s.phoneKey == null) return null;
    final Uri base;
    if (relayed) {
      if (s.relay != RelayStatus.connected || s.relayAddress == null) {
        return null;
      }
      base = s.relayAddress!;
    } else {
      if (!s.running || s.urls.isEmpty) return null;
      base = s.urls.first.replace(path: '/');
    }
    final token = pairing.issueToken();
    return base.replace(fragment: 'p=${s.phoneKey}&t=$token');
  }

  void revoke(String browserKey) {
    registry.revoke(browserKey);
    _server?.disconnect(browserKey);
    _publish();
  }

  void _publish() {
    final server = _server;
    if (server == null) return;
    state = state.copyWith(connected: server.sessions.length);
  }

  Future<StaticKey> _staticKey(WeftStores stores) async {
    final seed = await stores.secrets.read(SecretStore.sennitWebKey);
    if (seed != null) return StaticKey.fromSeed(base64.decode(seed));
    final key = await StaticKey.generate();
    await stores.secrets.write(
      SecretStore.sennitWebKey,
      await key.exportSeed(),
    );
    return key;
  }

  /// Every preference except this device's own pairing and sync state.
  static Map<String, String> _shareableSettings(WeftStores stores) => {
    for (final row in stores.db.raw.select('SELECT key, value FROM settings'))
      if (!(row['key'] as String).startsWith('web.') &&
          !(row['key'] as String).startsWith('sync.'))
        row['key'] as String: row['value'] as String,
  };

  /// Fetches a homeserver media address with this device's credentials.
  ///
  /// Only the homeserver's own media API: a browser that could make the phone
  /// fetch any address would turn it into a proxy into its home network.
  Future<Object?> _fetchMedia(Map<String, Object?> params) async {
    final raw = params['url'];
    if (raw is! String || kNoMatrix) return null;
    final url = Uri.tryParse(raw);
    final homeserver = ref.read(matrixSessionProvider).client.homeserver;
    if (url == null ||
        homeserver == null ||
        url.origin != homeserver.origin ||
        !url.path.startsWith('/_matrix/')) {
      throw const RemoteException('forbidden');
    }
    final response = await http.get(
      url,
      headers: ref.read(mediaHeadersProvider) ?? const {},
    );
    if (response.statusCode != 200) return null;
    return base64.encode(response.bodyBytes);
  }
}

final sennitWebServerProvider =
    NotifierProvider<SennitWebController, SennitWebServing>(
      SennitWebController.new,
    );
