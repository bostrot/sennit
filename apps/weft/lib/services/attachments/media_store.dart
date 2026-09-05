/// Materialising a received attachment as a real file on disk.
///
/// The viewer needs this three times over and for three different reasons: a
/// video player wants a path rather than a `Uint8List`, the OS share sheet wants
/// a file it can hand to another app, and Save wants something to copy. Doing it
/// once and caching under app support is what keeps tapping Share after Save
/// from downloading a 200 MB film twice.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../data/chat_repository.dart';
import '../models/background_transport.dart';
import '../models/model_transport.dart';

/// Thrown when an attachment's bytes cannot be produced at all.
///
/// Distinct from a download *failure*: this is the undecryptable photo, the
/// redacted event, the demo fixture that never had bytes. [message] is written
/// for the user, because the only thing the viewer can do with it is say so.
class MediaUnavailableException implements Exception {
  const MediaUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A name to write [message]'s attachment under.
///
/// A sender who wrote [WeftMessage.attachmentName] said what the file is called,
/// and that is the answer — the whole reason MSC2530 splits the key. It is still
/// run through [_sanitise] and [p.basename] rather than trusted onto the disk:
/// the name arrives from whatever client or bridge sent the event, and
/// `../../.bashrc` is a perfectly well-formed `filename`.
///
/// Without one there is no filename field at all — for an attachment the *body*
/// is the filename, which is exactly why `attachmentCaption` exists to hide it
/// under the picture. Here it is wanted rather than hidden, but it cannot be
/// trusted: a bridge writes "Forwarded", a caption-carrying client writes a
/// sentence, and either would become a file called `Forwarded` in the user's
/// Downloads.
///
/// So the body is used only when [looksLikeFilename] says so — the same rule the
/// caption heuristic reads the other way round — and otherwise the event id
/// becomes one, with an extension derived from [mimeType] when there is a known
/// one. Path separators are stripped whatever the source: a body of
/// `../../.bashrc` must not decide where the file lands.
String attachmentFileName(WeftMessage message, {String? mimeType}) {
  final declared = message.attachmentName?.trim();
  if (declared != null && declared.isNotEmpty) {
    final named = _sanitise(p.basename(declared));
    // A declared name that sanitises to nothing usable falls through to the
    // event id rather than becoming the literal word "attachment", which is
    // what `_sanitise` returns for an empty result and which would collide
    // across every such file in one folder.
    if (named != 'attachment') return named;
  }

  final body = message.body.trim();
  final candidate = body.isEmpty ? '' : p.basename(body);
  if (looksLikeFilename(candidate)) return _sanitise(candidate);

  final stem = 'weft-${_sanitise(message.eventId)}';
  final extension = mimeType == null ? null : extensionForMimeType(mimeType);
  return extension == null ? stem : '$stem.$extension';
}

/// Everything a file system might object to, flattened to `_`.
///
/// Matrix event ids start with `$` and contain `:` and `/`, none of which belong
/// in a path component on every platform Braid runs on.
String _sanitise(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty ? 'attachment' : cleaned;
}

/// Copies [message]'s attachment into [directory] and returns the file.
///
/// **The fork is the point.** A plain-room attachment has a fetchable URL, so it
/// goes through [transport] — the background download service on mobile,
/// streaming HTTP elsewhere — and never exists in memory as a whole. An
/// encrypted one has no such URL at all: the bytes behind its mxc URI are
/// ciphertext, so it must come back through [ChatRepository.attachmentBytes],
/// which downloads and decrypts it. That path *does* hold the file in memory,
/// which is the honest cost of end-to-end encryption and not something a
/// transport can be talked into avoiding.
///
/// Downloads land on a `.part` file and are renamed on success, so the presence
/// of the final name means the bytes are all there. Without that a cancelled
/// save would leave a half file that every later Share happily handed on.
Future<File> stageAttachment(
  WeftMessage message, {
  required ChatRepository repository,
  required ModelDownloadTransport transport,
  required Directory directory,
  void Function(int received)? onBytes,
  Future<bool> Function()? shouldContinue,
}) async {
  // Its own folder per event: two photos from different senders are both
  // `image.jpg`, and a flat staging directory would serve the first one for
  // both of them.
  final folder = Directory(p.join(directory.path, _sanitise(message.eventId)));
  final name = attachmentFileName(message);
  final target = File(p.join(folder.path, name));
  if (target.existsSync() && target.lengthSync() > 0) return target;

  await folder.create(recursive: true);
  final part = File('${target.path}.part');

  final location = await repository.attachmentLocation(
    message.roomId,
    message.eventId,
  );

  if (location != null) {
    await transport.download(
      url: location.url,
      target: part,
      // A hint for the progress bar, not a contract — `info.size` is frequently
      // absent, and 0 simply means the transport reports bytes without a total.
      expectedBytes: message.mediaSizeBytes ?? 0,
      displayName: name,
      headers: location.headers,
      onBytes: onBytes,
      shouldContinue: shouldContinue,
    );
  } else {
    final bytes = await repository.attachmentBytes(
      message.roomId,
      message.eventId,
      // The full-size original: the thumbnail is what the bubble already shows,
      // and saving a 96-pixel crop of the photo the user asked for would be a
      // silent substitution.
      thumbnail: false,
    );
    if (bytes == null) {
      throw const MediaUnavailableException(
        'This attachment could not be downloaded.',
      );
    }
    await part.writeAsBytes(bytes, flush: true);
    onBytes?.call(bytes.length);
  }

  await part.rename(target.path);
  return target;
}

/// [stageAttachment] with the transport and the staging directory already
/// resolved.
///
/// A class rather than a function because both of those are things a widget test
/// cannot have: `path_provider` is a method channel, and the background download
/// service is a foreground service on Android. Overriding
/// [mediaFileStoreProvider] replaces the pair in one move.
class MediaFileStore {
  MediaFileStore({
    ModelDownloadTransport? transport,
    Future<Directory> Function()? directory,
  }) : _transport = transport ?? BackgroundModelDownloadTransport(),
       _directory = directory ?? _defaultDirectory;

  final ModelDownloadTransport _transport;
  final Future<Directory> Function() _directory;

  /// Under application support rather than a temp directory, and not by taste:
  /// `background_downloader` silently falls back to plain HTTP for any target
  /// outside it, which on mobile is the difference between a download that
  /// survives the app being backgrounded and one that dies with it.
  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'media'));
  }

  Future<File> stage(
    WeftMessage message, {
    required ChatRepository repository,
    void Function(int received)? onBytes,
    Future<bool> Function()? shouldContinue,
  }) async {
    return stageAttachment(
      message,
      repository: repository,
      transport: _transport,
      directory: await _directory(),
      onBytes: onBytes,
      shouldContinue: shouldContinue,
    );
  }

  void dispose() => _transport.dispose();
}

/// The staging store the media viewer fetches through.
final mediaFileStoreProvider = Provider<MediaFileStore>((ref) {
  final store = MediaFileStore();
  ref.onDispose(store.dispose);
  return store;
});
