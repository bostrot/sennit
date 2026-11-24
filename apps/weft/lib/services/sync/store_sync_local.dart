import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';
import 'package:weft_sync/weft_sync.dart';

import '../../app/stores.dart';

/// Device sync's view of this device: the settings table, the merge verdicts,
/// the per-chat send network and — while their switch is on — the keychain.
///
/// Reads everything and lets `reconcile` find what changed by comparison, so
/// no screen that writes a setting has to know sync exists.
class StoreSyncLocal implements SyncLocal {
  StoreSyncLocal(
    this._stores, {
    required this.onSettingsChanged,
    required this.onMergesChanged,
  });

  final WeftStores _stores;

  /// Tells settings-derived providers to re-read.
  final void Function() onSettingsChanged;

  /// Tells the repository to rebuild its identity graph from the store.
  final void Function() onMergesChanged;

  /// The keychain values that travel with [WeftSettings.syncSecrets] on. The
  /// MCP tunnel token is missing on purpose: it opens this one device.
  static const List<String> secretNames = [
    SecretStore.llmApiKey,
    SecretStore.embeddingApiKey,
    SecretStore.transcriptionApiKey,
    SecretStore.homeAssistantToken,
    SecretStore.paperlessToken,
    SecretStore.calendarIcsUrl,
    SecretStore.personMemory,
  ];

  String? _secret(String name) => switch (name) {
    SecretStore.llmApiKey => _stores.llmApiKey,
    SecretStore.embeddingApiKey => _stores.embeddingApiKey,
    SecretStore.transcriptionApiKey => _stores.transcriptionApiKey,
    SecretStore.homeAssistantToken => _stores.homeAssistantToken,
    SecretStore.paperlessToken => _stores.paperlessToken,
    SecretStore.calendarIcsUrl => _stores.calendarIcsUrl,
    SecretStore.personMemory => _stores.personMemory,
    _ => null,
  };

  Future<void> _writeSecret(String name, String? value) => switch (name) {
    SecretStore.llmApiKey => _stores.setLlmApiKey(value),
    SecretStore.embeddingApiKey => _stores.setEmbeddingApiKey(value),
    SecretStore.transcriptionApiKey => _stores.setTranscriptionApiKey(value),
    SecretStore.homeAssistantToken => _stores.setHomeAssistantToken(value),
    SecretStore.paperlessToken => _stores.setPaperlessToken(value),
    SecretStore.calendarIcsUrl => _stores.setCalendarIcsUrl(value),
    SecretStore.personMemory => _stores.setPersonMemory(value),
    _ => Future<void>.value(),
  };

  @override
  Map<String, String> collect() {
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in _stores.settings.all().entries) {
      if (SyncPolicy.syncsSetting(key)) out[SyncKeys.setting + key] = value;
    }
    for (final d in _stores.identity.loadDecisions()) {
      out[SyncKeys.merge + d.pair] = '${d.verdict}|${d.source}';
    }
    for (final MapEntry(:key, :value)
        in _stores.identity.loadSendNetworks().entries) {
      out[SyncKeys.chatNetwork + key] = value.id;
    }
    if (_stores.settings.getBool(WeftSettings.syncSecrets)) {
      for (final name in secretNames) {
        final value = _secret(name);
        if (value != null && value.isNotEmpty) {
          out[SyncKeys.secret + name] = value;
        }
      }
    }
    return out;
  }

  @override
  Map<String, SyncRecord> loadState() {
    final out = <String, SyncRecord>{};
    for (final row in _stores.syncState.load()) {
      try {
        out[row.key] = SyncRecord(
          value: row.value,
          hlc: Hlc.parse(row.hlc),
          observed: row.observed,
          tracked: row.tracked,
        );
      } on FormatException {
        // A row this build cannot read is forgotten; the next round treats
        // the key as one it has never shared and takes the shared value.
        continue;
      }
    }
    return out;
  }

  @override
  void saveState(Map<String, SyncRecord> state) {
    _stores.syncState.replaceAll([
      for (final MapEntry(:key, :value) in state.entries)
        (
          key: key,
          value: value.value,
          hlc: value.hlc.toString(),
          observed: value.observed,
          tracked: value.tracked,
        ),
    ]);
  }

  @override
  Future<void> apply(Map<String, String?> changes) async {
    var settings = false;
    var merges = false;
    for (final MapEntry(:key, :value) in changes.entries) {
      if (key.startsWith(SyncKeys.setting)) {
        final name = key.substring(SyncKeys.setting.length);
        if (value == null) {
          _stores.settings.remove(name);
        } else {
          _stores.settings.setString(name, value);
        }
        settings = true;
      } else if (key.startsWith(SyncKeys.merge)) {
        // Verdicts are never deleted, only overruled; a null is ignored.
        final parts = value?.split('|');
        if (parts == null || parts.length != 2) continue;
        _stores.identity.saveDecision((
          pair: key.substring(SyncKeys.merge.length),
          verdict: parts[0],
          source: parts[1],
          decidedAt: DateTime.now().toUtc(),
        ));
        merges = true;
      } else if (key.startsWith(SyncKeys.chatNetwork)) {
        _stores.identity.setSendNetwork(
          key.substring(SyncKeys.chatNetwork.length),
          value == null ? null : ChatNetwork.fromId(value),
        );
        merges = true;
      } else if (key.startsWith(SyncKeys.secret)) {
        final name = key.substring(SyncKeys.secret.length);
        if (secretNames.contains(name)) await _writeSecret(name, value);
        settings = true;
      }
    }
    if (settings) onSettingsChanged();
    if (merges) onMergesChanged();
  }
}
