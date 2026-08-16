import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// What an API key is allowed to do.
///
/// Separate scopes exist because the interesting use of the MCP server is
/// read-mostly — "what did Anna say about the trial?" — and a key that can only
/// read is a far smaller thing to expose through a tunnel than one that can
/// send messages as you.
enum McpScope {
  /// Read chats, messages and search.
  read,

  /// Send messages and mark things read.
  send,

  /// Merge contacts, manage bridges, change settings.
  admin;

  static McpScope? fromName(String name) {
    for (final scope in McpScope.values) {
      if (scope.name == name) return scope;
    }
    return null;
  }
}

/// A stored key: its hash, never the key itself.
@immutable
class McpApiKey {
  const McpApiKey({
    required this.id,
    required this.label,
    required this.salt,
    required this.hash,
    required this.scopes,
    required this.createdAt,
    this.lastUsedAt,
    this.revoked = false,
  });

  /// Public identifier, safe to log and to show in settings.
  final String id;

  /// What the user called it — "laptop agent", "home automation".
  final String label;

  final String salt;

  /// Hex SHA-256 of `salt:secret`.
  final String hash;

  final Set<McpScope> scopes;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final bool revoked;

  bool allows(McpScope scope) => !revoked && scopes.contains(scope);

  McpApiKey copyWith({DateTime? lastUsedAt, bool? revoked}) => McpApiKey(
    id: id,
    label: label,
    salt: salt,
    hash: hash,
    scopes: scopes,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    revoked: revoked ?? this.revoked,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'salt': salt,
    'hash': hash,
    'scopes': scopes.map((s) => s.name).toList(),
    'created_at': createdAt.toIso8601String(),
    'last_used_at': lastUsedAt?.toIso8601String(),
    'revoked': revoked,
  };

  static McpApiKey fromJson(Map<String, Object?> json) => McpApiKey(
    id: json['id'] as String,
    label: json['label'] as String? ?? '',
    salt: json['salt'] as String,
    hash: json['hash'] as String,
    scopes: {
      for (final name in (json['scopes'] as List? ?? const []))
        ?McpScope.fromName(name as String),
    },
    createdAt: DateTime.parse(json['created_at'] as String),
    lastUsedAt: json['last_used_at'] == null
        ? null
        : DateTime.parse(json['last_used_at'] as String),
    revoked: json['revoked'] as bool? ?? false,
  );
}

/// A freshly minted key. The secret exists only here, once.
@immutable
class GeneratedApiKey {
  const GeneratedApiKey({required this.record, required this.secret});

  final McpApiKey record;

  /// The full token to hand the client. Never stored, never recoverable —
  /// losing it means issuing a new key.
  final String secret;
}

/// Issues and verifies MCP API keys.
///
/// ## On the hash choice
///
/// Keys are hashed with a single salted SHA-256, not a password KDF like
/// Argon2. That is deliberate and safe *here*: these are 256-bit
/// cryptographically-random tokens, not human-chosen passwords. A KDF's work
/// factor exists to make guessing a low-entropy secret expensive; against a
/// uniformly random 256-bit value, guessing is already infeasible and the work
/// factor would only slow down legitimate request verification.
///
/// If keys ever become user-chosen, this must change to a real password KDF.
class ApiKeyManager {
  ApiKeyManager({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  static const String keyPrefix = 'weft_';

  /// Mints a key. The returned [GeneratedApiKey.secret] is the only copy.
  GeneratedApiKey generate({
    required String label,
    required Set<McpScope> scopes,
    DateTime? now,
  }) {
    if (scopes.isEmpty) {
      throw ArgumentError('A key with no scopes could not do anything');
    }

    final id = _randomHex(8);
    final salt = _randomHex(16);
    final secretBody = _randomBase64Url(32);
    final secret = '$keyPrefix${id}_$secretBody';

    return GeneratedApiKey(
      record: McpApiKey(
        id: id,
        label: label,
        salt: salt,
        hash: hashSecret(salt: salt, secret: secret),
        scopes: scopes,
        createdAt: now ?? DateTime.now(),
      ),
      secret: secret,
    );
  }

  /// Finds the key [presented] belongs to, or null.
  ///
  /// The id is parsed out of the token so only one candidate is hashed, and the
  /// comparison is constant-time so a timing side channel cannot be used to
  /// recover a hash byte by byte.
  McpApiKey? verify(String presented, Iterable<McpApiKey> known) {
    final id = idFromSecret(presented);
    if (id == null) return null;

    for (final candidate in known) {
      if (candidate.id != id || candidate.revoked) continue;
      final computed = hashSecret(salt: candidate.salt, secret: presented);
      if (constantTimeEquals(computed, candidate.hash)) return candidate;
    }
    return null;
  }

  /// Extracts the public id embedded in a token.
  static String? idFromSecret(String secret) {
    if (!secret.startsWith(keyPrefix)) return null;
    final rest = secret.substring(keyPrefix.length);
    final underscore = rest.indexOf('_');
    if (underscore <= 0) return null;
    return rest.substring(0, underscore);
  }

  static String hashSecret({required String salt, required String secret}) =>
      sha256.convert(utf8.encode('$salt:$secret')).toString();

  String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  String _randomBase64Url(int bytes) {
    final data = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      data[i] = _random.nextInt(256);
    }
    return base64Url.encode(data).replaceAll('=', '');
  }
}

/// Compares two strings without leaking where they first differ.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

/// Per-key sliding-window rate limiter.
///
/// A tunnel is reachable from the internet, so a leaked key should be
/// expensive to abuse and noisy rather than silent.
class RateLimiter {
  RateLimiter({
    this.maxRequests = 120,
    this.window = const Duration(minutes: 1),
  });

  final int maxRequests;
  final Duration window;

  final Map<String, List<DateTime>> _hits = {};

  /// Records a request and reports whether it is allowed.
  bool allow(String keyId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final cutoff = at.subtract(window);

    final hits = _hits.putIfAbsent(keyId, () => [])
      ..removeWhere((t) => t.isBefore(cutoff));

    if (hits.length >= maxRequests) return false;
    hits.add(at);
    return true;
  }

  void reset(String keyId) => _hits.remove(keyId);
}

/// One line of the audit log.
@immutable
class McpAuditEntry {
  const McpAuditEntry({
    required this.at,
    required this.keyId,
    required this.tool,
    required this.allowed,
    this.detail,
  });

  final DateTime at;
  final String keyId;
  final String tool;
  final bool allowed;
  final String? detail;

  @override
  String toString() =>
      '[${at.toIso8601String()}] $keyId ${allowed ? "ok" : "DENIED"} $tool'
      '${detail == null ? "" : " — $detail"}';
}

/// Bounded in-memory audit log.
///
/// Every call through the tunnel is recorded, including denials, so the user
/// can see what an agent actually did with their messages.
class McpAuditLog {
  McpAuditLog({this.capacity = 500});

  final int capacity;
  final List<McpAuditEntry> _entries = [];

  List<McpAuditEntry> get entries => List.unmodifiable(_entries);

  void record(McpAuditEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  /// Denials only — what a user checks after a key leaks.
  List<McpAuditEntry> get denials =>
      _entries.where((e) => !e.allowed).toList(growable: false);
}
