import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft_store/weft_store.dart';

/// What a cold start spends before the auth gate will draw anything.
///
/// [WeftStores.open] is the future the gate holds its splash on, so every
/// millisecond in here is a millisecond of blank screen. The keys it collects
/// are for transcription, embeddings and the optional integrations — nothing
/// the inbox draws with — which is what makes *how* they are fetched the only
/// interesting thing about them.
void main() {
  /// A [SecretStore] that answers from a map after a beat, and remembers how
  /// many reads were in flight at the busiest moment.
  ///
  /// The delay is the whole instrument: with the reads issued one after
  /// another the peak can never exceed one, however long each takes.
  late _RecordingSecrets secrets;

  const values = {
    SecretStore.embeddingApiKey: 'embedding',
    SecretStore.transcriptionApiKey: 'transcription',
    SecretStore.homeAssistantToken: 'home-assistant',
    SecretStore.paperlessToken: 'paperless',
    SecretStore.llmApiKey: 'llm',
  };

  setUp(() => secrets = _RecordingSecrets(values));

  test('asks the keychain for every secret at once', () async {
    final stores = await WeftStores.open(
      directoryOverride: ':memory:',
      secretStore: secrets,
    );
    addTearDown(stores.dispose);

    expect(secrets.reads.toSet(), values.keys.toSet());
    // Five, not one. One means they went back to being read in a row, which is
    // five keychain round trips laid end to end in front of the first frame.
    expect(secrets.peakInFlight, values.length);
  });

  test('gives each answer to the field that asked for it', () async {
    // The regression a concurrent read invites and a sequential one cannot
    // have: `Future.wait` returns a list in call order, and a list read back
    // in the wrong order hands the user's Home Assistant token to the
    // transcription endpoint. Every value here is distinct so a swap shows.
    final stores = await WeftStores.open(
      directoryOverride: ':memory:',
      secretStore: secrets,
    );
    addTearDown(stores.dispose);

    expect(stores.embeddingApiKey, 'embedding');
    expect(stores.transcriptionApiKey, 'transcription');
    expect(stores.homeAssistantToken, 'home-assistant');
    expect(stores.paperlessToken, 'paperless');
    expect(stores.llmApiKey, 'llm');
  });

  test('a keychain with nothing in it opens the stores anyway', () async {
    final stores = await WeftStores.open(
      directoryOverride: ':memory:',
      secretStore: _RecordingSecrets(const {}),
    );
    addTearDown(stores.dispose);

    expect(stores.embeddingApiKey, isNull);
    expect(stores.llmApiKey, isNull);
    // A fresh install still has a database, and the gate still opens on it.
    expect(stores.settings.getBool('never.set'), isFalse);
  });

  test('a keychain that refuses fails the bootstrap, once', () async {
    // The startup-error screen is driven by this future rejecting. Reading the
    // five together must not turn one refusal into four unhandled errors
    // alongside it — `Future.wait` listens to all five, so it does not.
    final failing = _RecordingSecrets(
      values,
      failOn: SecretStore.paperlessToken,
    );

    await expectLater(
      WeftStores.open(directoryOverride: ':memory:', secretStore: failing),
      throwsA(isA<StateError>()),
    );
    // The refusal did not stop the others being asked, which is what makes it
    // one failed bootstrap rather than a partially-read one on the next tick.
    expect(failing.reads.toSet(), values.keys.toSet());
  });
}

class _RecordingSecrets extends SecretStore {
  _RecordingSecrets(this._values, {this.failOn});

  final Map<String, String> _values;

  /// The key whose read throws, standing in for a locked or broken keychain.
  final String? failOn;

  final List<String> reads = [];

  int _inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _inFlight--;
    if (key == failOn) throw StateError('keychain unavailable');
    return _values[key];
  }
}
