import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/backup/backup_service.dart' show kSennitVersion;
import '../services/web/web_bundle_store.dart';

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
