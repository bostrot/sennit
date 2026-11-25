/// The attachments this device keeps on disk, measured, capped and cleared.
///
/// Two folders hold them. The Matrix SDK caches what it downloaded under
/// `matrix/files` — photos, thumbnails, voice notes — and forgets each after
/// thirty days on its own. [MediaFileStore] stages what was opened, saved or
/// shared under `media`, and keeps it until a retention sweep purges it. A
/// bridge that relays a busy group's videos fills both faster than thirty
/// days empties them, and nothing said how much space that was.
///
/// Everything here can be fetched again: clearing costs a download the next
/// time the picture is looked at, never the message.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/stores.dart';

/// The size limits offered in settings, in megabytes. Zero is no limit.
const List<int> kMediaLimitChoicesMb = [500, 1024, 2048, 5120, 0];

/// The limit a device starts with: a couple of gigabytes is a lot of photos
/// and still small next to what a phone has free.
const int kDefaultMediaLimitMb = 2048;

/// What [WeftSettings.mediaLimitMb] currently says, in bytes; null is no limit.
int? mediaLimitBytes(SettingsStore settings) {
  final mb = settings.getInt(WeftSettings.mediaLimitMb) ?? kDefaultMediaLimitMb;
  return mb <= 0 ? null : mb * 1024 * 1024;
}

/// Whether the timeline fetches pictures and video posters by itself.
bool mediaAutoDownload(SettingsStore settings) =>
    settings.getBool(WeftSettings.mediaAutoDownload, fallback: true);

class LocalMediaStorage {
  LocalMediaStorage({Future<List<Directory>> Function()? directories})
    : _directories = directories ?? _defaultDirectories;

  final Future<List<Directory>> Function() _directories;

  static Future<List<Directory>> _defaultDirectories() async {
    final support = (await getApplicationSupportDirectory()).path;
    return [
      Directory(p.join(support, 'matrix', 'files')),
      Directory(p.join(support, 'media')),
    ];
  }

  /// Every finished file, oldest first.
  ///
  /// A `.part` is a download still being written, and deleting it under the
  /// writer would turn a slow download into a failed one; it is neither
  /// counted nor removed.
  Future<List<(File, FileStat)>> _files() async {
    final found = <(File, FileStat)>[];
    for (final directory in await _directories()) {
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        try {
          found.add((entity, entity.statSync()));
        } on FileSystemException {
          // Gone between the listing and the stat: the SDK's own sweep, or a
          // retention purge, got there first.
        }
      }
    }
    found.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    return found;
  }

  /// How many bytes the cached attachments take.
  Future<int> usedBytes() async {
    var total = 0;
    for (final (_, stat) in await _files()) {
      total += stat.size;
    }
    return total;
  }

  /// Deletes every cached attachment and returns the bytes freed.
  Future<int> clear() => _deleteUntil((_) => false);

  /// Deletes the oldest attachments until the rest fit in [maxBytes], and
  /// returns the bytes freed. Null is no limit, which deletes nothing.
  Future<int> trimTo(int? maxBytes) async {
    if (maxBytes == null) return 0;
    final used = await usedBytes();
    return _deleteUntil((freed) => used - freed <= maxBytes);
  }

  Future<int> _deleteUntil(bool Function(int freed) done) async {
    var freed = 0;
    final emptied = <Directory>{};
    for (final (file, stat) in await _files()) {
      if (done(freed)) break;
      try {
        await file.delete();
        freed += stat.size;
        emptied.add(file.parent);
      } on FileSystemException {
        // Already gone, or held open on a platform that refuses; either way
        // it is not space this call freed.
      }
    }
    // The staging store keeps one folder per event; an empty one is clutter.
    final roots = (await _directories()).map((d) => p.normalize(d.path));
    for (final folder in emptied) {
      if (roots.contains(p.normalize(folder.path))) continue;
      try {
        if (folder.listSync().isEmpty) await folder.delete();
      } on FileSystemException {
        // Something was written into it meanwhile; leave it.
      }
    }
    return freed;
  }
}

final localMediaStorageProvider = Provider<LocalMediaStorage>(
  (ref) => LocalMediaStorage(),
);

/// [mediaAutoDownload] for the timeline, true until the stores are open.
final mediaAutoDownloadProvider = Provider<bool>((ref) {
  ref.watch(settingsRevisionProvider);
  final stores = storesOrNull(ref);
  return stores == null || mediaAutoDownload(stores.settings);
});

/// Brings the cache under the configured limit; run once a session starts.
Future<void> trimLocalMedia(WidgetRef ref) async {
  final WeftStores stores;
  try {
    stores = ref.read(storesProvider);
  } on Object {
    return;
  }
  await ref
      .read(localMediaStorageProvider)
      .trimTo(mediaLimitBytes(stores.settings));
}
