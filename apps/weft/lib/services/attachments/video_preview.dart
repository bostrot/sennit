/// What the timeline shows for a received video before anyone taps it.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../data/chat_repository.dart';
import 'media_store.dart';
import 'video_poster.dart';

/// A received video staged to disk, with a frame of it to stand in as poster.
@immutable
class VideoPreview {
  const VideoPreview({required this.file, this.poster});

  /// The decrypted video, where the inline player and the viewer both find it.
  final File file;

  /// One frame as JPEG, or null when the platform could not decode the film.
  final Uint8List? poster;
}

/// Downloads [message]'s video and pulls a poster frame out of it.
///
/// A function behind a provider for the same reason as `videoSurfaceProvider`:
/// staging writes under `path_provider`'s directory and the frame comes from a
/// method channel, neither of which a widget test has.
typedef VideoPreviewLoader =
    Future<VideoPreview?> Function(
      WeftMessage message,
      ChatRepository repository,
    );

/// The loader the timeline uses. Stages through the repository — the one path
/// that decrypts an encrypted room's attachment and sends the authenticated
/// media header for a plain one — into the same file the viewer opens, so
/// tapping the bubble afterwards plays without a second download.
final videoPreviewLoaderProvider = Provider<VideoPreviewLoader>((ref) {
  final store = ref.watch(mediaFileStoreProvider);
  return (message, repository) async {
    try {
      final file = await store.stage(
        message,
        repository: repository,
        viaRepository: true,
      );
      return VideoPreview(
        file: file,
        poster: await extractVideoFrame(file.path),
      );
    } on Object catch (error) {
      // A preview is a courtesy: the bubble keeps its plain poster and still
      // opens the viewer, which reports the failure properly.
      debugPrint('weft: video preview ${message.eventId} failed: $error');
      return null;
    }
  };
});
