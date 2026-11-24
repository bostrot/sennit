import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A picture Sennit Web asks the phone for, by its homeserver address.
///
/// Keyed by the address, so the image cache shares one fetch between every
/// avatar of the same person.
class RemoteMediaImage extends ImageProvider<RemoteMediaImage> {
  const RemoteMediaImage(this.url, this.fetch);

  final String url;
  final Future<Uint8List?> Function(String url) fetch;

  @override
  Future<RemoteMediaImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    RemoteMediaImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await fetch(url);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('No picture for $url');
    }
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteMediaImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
