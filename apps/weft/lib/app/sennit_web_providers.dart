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
  });

  final bool running;
  final int? port;

  /// This device's LAN addresses, for the address shown and the QR code.
  final List<String> addresses;

  /// Browsers connected right now.
  final int connected;

  /// The static public key a pairing URL carries, base64url.
  final String? phoneKey;

  /// The last start failed — the port is taken, usually.
  final bool failed;

  /// Where a browser on the same network opens Sennit Web.
  List<Uri> get urls => [
    for (final a in addresses) Uri(scheme: 'http', host: a, port: port),
  ];
}

/// The port Sennit Web listens on — fixed rather than random, so a bookmark
/// keeps working from one session to the next.
const int kSennitWebPort = 8787;

/// Starts and stops the server, and keeps its hosts current.
///
/// Off unless switched on, and off again when the app closes: serving is a
/// decision made for a moment, not a standing setting.
class SennitWebController extends Notifier<SennitWebServing> {
  SennitWebServer? _server;
  StreamSubscription<void>? _changes;

  /// The foreground job that keeps an Android phone serving with the app in
  /// the background; its ongoing notification is the system-wide sign that
  /// Sennit Web is on. A no-op on platforms without one.
  BackgroundWorkHandle? _keepAlive;

  PairingRegistry get registry =>
      PairingRegistry(ref.read(storesProvider).settings);

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
      unawaited(_server?.stop());
    });
    return const SennitWebServing();
  }

  Future<void> start() async {
    if (_server != null) return;
    final bundle = ref.read(webBundleProvider);
    if (bundle is! WebBundleReady) return;
    final stores = ref.read(storesProvider);
    final key = await _staticKey(stores);
    final pairing = registry;
    final server = SennitWebServer(
      bundle: bundle.directory,
      key: key,
      registry: pairing,
      repository: () => ref.read(chatRepositoryProvider),
      deviceName: Platform.localHostname,
      port: kSennitWebPort,
      extraHandlers: {RemoteMethods.mediaFetch: _fetchMedia},
      settings: () => _shareableSettings(stores),
    );
    try {
      await server.start();
    } on SocketException {
      state = const SennitWebServing(failed: true);
      return;
    }
    _server = server;
    _registry = pairing;
    _changes = server.changes.listen((_) => _publish());
    state = SennitWebServing(
      running: true,
      port: server.boundPort,
      addresses: await SennitWebServer.lanAddresses(),
      phoneKey: key.publicId,
    );
    _keepAlive = ref
        .read(backgroundWorkProvider)
        .begin(
          weftPlatformL10n().sennitWebServingBanner,
          detail: state.urls.firstOrNull?.toString(),
        );
  }

  PairingRegistry? _registry;

  Future<void> stop() async {
    _keepAlive?.end();
    _keepAlive = null;
    await _changes?.cancel();
    _changes = null;
    await _server?.stop();
    _server = null;
    _registry?.cancelToken();
    state = const SennitWebServing();
  }

  /// A pairing address with a fresh one-time token, for the QR code.
  Uri? pairingUrl() {
    final s = state;
    final pairing = _registry;
    if (!s.running || s.urls.isEmpty || pairing == null) return null;
    final token = pairing.issueToken();
    return s.urls.first.replace(
      path: '/',
      fragment: 'p=${s.phoneKey}&t=$token',
    );
  }

  void revoke(String browserKey) {
    (_registry ?? registry).revoke(browserKey);
    _server?.disconnect(browserKey);
    _publish();
  }

  void _publish() {
    final server = _server;
    if (server == null) return;
    state = SennitWebServing(
      running: true,
      port: state.port,
      addresses: state.addresses,
      phoneKey: state.phoneKey,
      connected: server.sessions.length,
    );
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
