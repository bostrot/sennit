import 'dart:convert';
import 'dart:math';

import 'package:weft_store/weft_store.dart';

/// A browser this device serves Sennit Web to.
class PairedBrowser {
  const PairedBrowser({
    required this.key,
    required this.name,
    required this.pairedAt,
    this.lastSeen,
  });

  /// Its static public key, base64url — what the handshake authenticates.
  final String key;
  final String name;
  final DateTime pairedAt;
  final DateTime? lastSeen;

  PairedBrowser seen(DateTime at) =>
      PairedBrowser(key: key, name: name, pairedAt: pairedAt, lastSeen: at);

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'paired': pairedAt.millisecondsSinceEpoch,
    'seen': ?lastSeen?.millisecondsSinceEpoch,
  };

  static PairedBrowser? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final paired = raw['paired'];
    if (key is! String || paired is! int) return null;
    return PairedBrowser(
      key: key,
      name: (raw['name'] as String?) ?? '',
      pairedAt: DateTime.fromMillisecondsSinceEpoch(paired),
      lastSeen: raw['seen'] is int
          ? DateTime.fromMillisecondsSinceEpoch(raw['seen']! as int)
          : null,
    );
  }
}

/// The paired browsers and the one pairing token that may add another.
///
/// The list is public keys and names — nothing secret — so it lives in the
/// settings table, under a `web.` key that device sync never shares: a browser
/// is paired to the device serving it. The token lives only in memory, is
/// good once, and only for [tokenLifetime] after the QR code was shown.
class PairingRegistry {
  PairingRegistry(this._settings, {DateTime Function()? now, Random? random})
    : _now = now ?? DateTime.now,
      _random = random ?? Random.secure();

  static const String settingsKey = 'web.paired';
  static const Duration tokenLifetime = Duration(minutes: 5);

  final SettingsStore _settings;
  final DateTime Function() _now;
  final Random _random;
  String? _token;
  DateTime? _tokenIssued;

  List<PairedBrowser> get browsers {
    final raw = _settings.getJson(settingsKey)?['browsers'];
    if (raw is! List) return const [];
    return [for (final b in raw) ?PairedBrowser.fromJson(b)];
  }

  void _save(List<PairedBrowser> list) => _settings.setJson(settingsKey, {
    'browsers': [for (final b in list) b.toJson()],
  });

  bool isPaired(String key) => browsers.any((b) => b.key == key);

  /// A fresh one-time token for the next QR code; the previous one dies.
  String issueToken() {
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    _tokenIssued = _now();
    return _token = base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Whether [token] is the live one — compared in constant time.
  bool tokenMatches(String? token) {
    final live = _token;
    final issued = _tokenIssued;
    if (token == null || live == null || issued == null) return false;
    if (_now().difference(issued) > tokenLifetime) return false;
    if (token.length != live.length) return false;
    var diff = 0;
    for (var i = 0; i < live.length; i++) {
      diff |= live.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Adds the browser and spends the token. Called once the browser has
  /// proven its key, not when it merely named one.
  void pair(String key, String name) {
    _token = null;
    _tokenIssued = null;
    _save([
      for (final b in browsers)
        if (b.key != key) b,
      PairedBrowser(key: key, name: name, pairedAt: _now(), lastSeen: _now()),
    ]);
  }

  void touch(String key) =>
      _save([for (final b in browsers) b.key == key ? b.seen(_now()) : b]);

  void revoke(String key) => _save([
    for (final b in browsers)
      if (b.key != key) b,
  ]);

  void cancelToken() {
    _token = null;
    _tokenIssued = null;
  }
}
