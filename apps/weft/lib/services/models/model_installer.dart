import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'background_transport.dart';
import 'model_catalog.dart';
import 'model_transport.dart';

/// Where a model currently stands.
enum ModelPhase { notInstalled, downloading, installed, failed }

class ModelState {
  const ModelState({required this.phase, this.receivedBytes = 0, this.error});

  final ModelPhase phase;
  final int receivedBytes;
  final String? error;
}

/// Downloads, tracks and removes on-device models.
///
/// Installed-ness is derived from the files themselves — right name, right
/// size, on disk — rather than a registry that can drift from reality. A
/// half-finished download therefore shows as not installed, and installing
/// again resumes from the bytes already present.
class ModelInstaller {
  ModelInstaller({ModelDownloadTransport? transport, Directory? rootOverride})
    : _transport = transport ?? BackgroundModelDownloadTransport(),
      _rootOverride = rootOverride;

  final ModelDownloadTransport _transport;
  final Directory? _rootOverride;

  final Map<String, ModelState> _states = {};
  final Set<String> _cancelRequested = {};
  final _controller = StreamController<String>.broadcast();

  /// Emits a model id whenever its state changes.
  Stream<String> get updates => _controller.stream;

  Future<Directory> _root() async {
    if (_rootOverride != null) return _rootOverride;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'models'));
  }

  Future<Directory> directoryFor(ModelSpec spec) async =>
      Directory(p.join((await _root()).path, spec.id));

  /// Absolute path of one of the model's files, for whatever runtime loads it.
  Future<File> fileFor(ModelSpec spec, String name) async =>
      File(p.join((await directoryFor(spec)).path, name));

  ModelState stateOf(ModelSpec spec) =>
      _states[spec.id] ?? const ModelState(phase: ModelPhase.notInstalled);

  /// Checks the disk and settles each model's state. Call once at screen open.
  Future<void> refresh() async {
    for (final spec in ModelCatalog.all) {
      if (stateOf(spec).phase == ModelPhase.downloading) continue;
      _set(
        spec.id,
        ModelState(
          phase: await isInstalled(spec)
              ? ModelPhase.installed
              : ModelPhase.notInstalled,
        ),
      );
    }
  }

  /// Marker written once every file has landed.
  ///
  /// Installed-ness cannot be "file size equals the catalog number": those
  /// numbers are published metadata that drifts, and a single byte of
  /// disagreement would make a perfectly good model look permanently missing.
  /// The transport already knows when a transfer completed, so that verdict is
  /// recorded here instead.
  Future<File> _marker(ModelSpec spec) async =>
      File(p.join((await directoryFor(spec)).path, '.installed'));

  Future<bool> isInstalled(ModelSpec spec) async {
    if (!(await _marker(spec)).existsSync()) return false;
    for (final file in spec.files) {
      final target = await fileFor(spec, file.name);
      // Non-empty rather than exactly-sized: the marker is the authority.
      if (!target.existsSync() || target.lengthSync() == 0) return false;
    }
    return true;
  }

  Future<void> install(ModelSpec spec) async {
    if (stateOf(spec).phase == ModelPhase.downloading) return;
    _cancelRequested.remove(spec.id);
    _set(spec.id, const ModelState(phase: ModelPhase.downloading));

    // Bytes already on disk from earlier files count toward progress, so a
    // resumed install does not appear to start from zero.
    var completedBytes = 0;

    try {
      for (final file in spec.files) {
        final target = await fileFor(spec, file.name);
        if (target.existsSync() && target.lengthSync() >= file.sizeBytes) {
          completedBytes += file.sizeBytes;
          _set(
            spec.id,
            ModelState(
              phase: ModelPhase.downloading,
              receivedBytes: completedBytes,
            ),
          );
          continue;
        }

        final base = completedBytes;
        await _transport.download(
          url: Uri.parse(file.url),
          target: target,
          expectedBytes: file.sizeBytes,
          displayName: spec.displayName,
          onBytes: (received) => _set(
            spec.id,
            ModelState(
              phase: ModelPhase.downloading,
              receivedBytes: base + received,
            ),
          ),
          shouldContinue: () async => !_cancelRequested.contains(spec.id),
        );
        completedBytes = base + file.sizeBytes;
      }

      await (await _marker(
        spec,
      )).writeAsString(DateTime.now().toIso8601String());
      _set(spec.id, const ModelState(phase: ModelPhase.installed));
    } on DownloadCancelled {
      // Partial files stay on disk deliberately: installing again resumes.
      _set(spec.id, const ModelState(phase: ModelPhase.notInstalled));
    } on DownloadFailure catch (e) {
      _set(spec.id, ModelState(phase: ModelPhase.failed, error: e.message));
    } on Exception catch (e) {
      _set(spec.id, ModelState(phase: ModelPhase.failed, error: '$e'));
    }
  }

  void cancel(ModelSpec spec) => _cancelRequested.add(spec.id);

  Future<void> delete(ModelSpec spec) async {
    final dir = await directoryFor(spec);
    if (dir.existsSync()) await dir.delete(recursive: true);
    _set(spec.id, const ModelState(phase: ModelPhase.notInstalled));
  }

  void _set(String id, ModelState state) {
    _states[id] = state;
    if (!_controller.isClosed) _controller.add(id);
  }

  Future<void> dispose() async {
    _transport.dispose();
    await _controller.close();
  }
}
