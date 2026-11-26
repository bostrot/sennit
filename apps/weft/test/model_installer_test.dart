/// The download state machine behind every on-device model: not installed →
/// downloading → installed, or failed, or back to not installed on a cancel;
/// resuming what is on disk; deleting; and the Wi-Fi-only switch reaching the
/// transport.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/models/model_catalog.dart';
import 'package:weft/services/models/model_installer.dart';
import 'package:weft/services/models/model_transport.dart';

/// Writes [chunks] bytes in [chunks] steps, unless told to fail or until
/// cancelled; holds before the last step while [hold] is pending.
class _ScriptedTransport implements ModelDownloadTransport {
  _ScriptedTransport({this.fail = false});

  final int chunks = 4;
  final bool fail;
  Completer<void>? hold;
  final requests = <({Uri url, bool wifiOnly})>[];

  @override
  Future<void> download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required String displayName,
    Map<String, String> headers = const {},
    void Function(int totalOnDisk)? onBytes,
    Future<bool> Function()? shouldContinue,
    bool requiresWiFi = false,
  }) async {
    requests.add((url: url, wifiOnly: requiresWiFi));
    await target.parent.create(recursive: true);
    for (var i = 1; i <= chunks; i++) {
      if (i == chunks) await hold?.future;
      if (shouldContinue != null && !await shouldContinue()) {
        throw const DownloadCancelled();
      }
      if (fail && i == chunks) throw const DownloadFailure('server said 500');
      await target.writeAsBytes(List.filled(10, i), mode: FileMode.append);
      onBytes?.call(expectedBytes * i ~/ chunks);
    }
  }

  @override
  void dispose() {}
}

const _spec = ModelCatalog.ternaryBonsai2b;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('weft-models-'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<(ModelInstaller, List<ModelPhase>)> installer(
    ModelDownloadTransport transport,
  ) async {
    final installer = ModelInstaller(transport: transport, rootOverride: root);
    final phases = <ModelPhase>[];
    installer.updates.listen((id) {
      if (id != _spec.id) return;
      final phase = installer.stateOf(_spec).phase;
      if (phases.isEmpty || phases.last != phase) phases.add(phase);
    });
    return (installer, phases);
  }

  test('downloads, reports progress, and ends installed', () async {
    final transport = _ScriptedTransport();
    final (models, phases) = await installer(transport);
    final progress = <int>[];
    models.updates.listen(
      (_) => progress.add(models.stateOf(_spec).receivedBytes),
    );

    expect(models.stateOf(_spec).phase, ModelPhase.notInstalled);
    await models.install(_spec);
    await pumpEventQueue();

    expect(phases, [ModelPhase.downloading, ModelPhase.installed]);
    expect(await models.isInstalled(_spec), isTrue);
    expect(progress.where((b) => b > 0), isNotEmpty);
    expect(progress.reduce((a, b) => a > b ? a : b), _spec.totalBytes);
    expect(transport.requests.single.url.toString(), _spec.files.single.url);
  });

  test('Wi-Fi only reaches the transport, and is off unless asked', () async {
    final transport = _ScriptedTransport();
    final (models, _) = await installer(transport);
    await models.install(_spec, wifiOnly: true);
    await models.delete(_spec);
    await models.install(_spec);
    expect(transport.requests.map((r) => r.wifiOnly), [true, false]);
  });

  test(
    'a cancel goes back to not installed and keeps the partial file',
    () async {
      final transport = _ScriptedTransport()..hold = Completer<void>();
      final (models, phases) = await installer(transport);
      final running = models.install(_spec);
      await pumpEventQueue();
      expect(models.stateOf(_spec).phase, ModelPhase.downloading);

      models.cancel(_spec);
      transport.hold!.complete();
      await running;
      await pumpEventQueue();

      expect(phases, [ModelPhase.downloading, ModelPhase.notInstalled]);
      expect(await models.isInstalled(_spec), isFalse);
      final partial = await models.fileFor(_spec, _spec.files.single.name);
      expect(partial.existsSync(), isTrue, reason: 'installing again resumes');
    },
  );

  test('a failure is reported and a retry finishes the download', () async {
    final (models, phases) = await installer(_ScriptedTransport(fail: true));
    await models.install(_spec);
    await pumpEventQueue();
    expect(models.stateOf(_spec).phase, ModelPhase.failed);
    expect(models.stateOf(_spec).error, 'server said 500');

    final (retry, _) = await installer(_ScriptedTransport());
    await retry.install(_spec);
    expect(retry.stateOf(_spec).phase, ModelPhase.installed);
    expect(phases.first, ModelPhase.downloading);
  });

  test('a second install while one runs is ignored', () async {
    final transport = _ScriptedTransport()..hold = Completer<void>();
    final (models, _) = await installer(transport);
    final first = models.install(_spec);
    await pumpEventQueue();
    await models.install(_spec);
    transport.hold!.complete();
    await first;
    expect(transport.requests, hasLength(1));
  });

  test('delete removes the files and the installed state', () async {
    final (models, _) = await installer(_ScriptedTransport());
    await models.install(_spec);
    await models.delete(_spec);
    expect(models.stateOf(_spec).phase, ModelPhase.notInstalled);
    expect(await models.isInstalled(_spec), isFalse);
    expect((await models.directoryFor(_spec)).existsSync(), isFalse);
  });

  test('refresh finds a model installed in an earlier run', () async {
    final (first, _) = await installer(_ScriptedTransport());
    await first.install(_spec);
    final (later, _) = await installer(_ScriptedTransport());
    expect(later.stateOf(_spec).phase, ModelPhase.notInstalled);
    await later.refresh();
    expect(later.stateOf(_spec).phase, ModelPhase.installed);
  });

  test('the device models are pinned, sized and offered separately', () {
    for (final spec in ModelCatalog.chat) {
      expect(spec.capability, ModelCapability.chat);
      expect(spec.licence, 'Apache-2.0');
      final url = spec.files.single.url;
      expect(url, matches(RegExp(r'/resolve/[0-9a-f]{40}/')));
      expect(url, endsWith('.gguf'));
      expect(ModelCatalog.byId(spec.id), same(spec));
      expect(ModelCatalog.all, isNot(contains(spec)));
    }
    expect(ModelCatalog.bonsai8b.totalBytes, 1158654496);
  });
}
