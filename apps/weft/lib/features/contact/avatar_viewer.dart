/// A contact's picture, full screen.
///
/// The profile draws the avatar as a 96-point circle, which is small enough
/// that a new contact's face is a guess. This is the same picture, square and
/// as large as the screen allows, with pinch to zoom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_matrix/weft_matrix.dart' show largerThumbnailUrl;

import '../../app/localisation.dart';
import '../../app/providers.dart';

/// Opens [imageUrl], the avatar of [name], full screen.
///
/// Faded in over black like the media viewer, so the two read as the same
/// kind of screen.
Future<void> openAvatarViewer(
  BuildContext context, {
  required String name,
  required String imageUrl,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: WeftMotion.normal,
      reverseTransitionDuration: WeftMotion.normal,
      pageBuilder: (_, _, _) => AvatarViewer(name: name, imageUrl: imageUrl),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// [imageUrl] at full size, with the small one standing in until it loads.
class AvatarViewer extends ConsumerWidget {
  const AvatarViewer({super.key, required this.name, required this.imageUrl});

  final String name;

  /// The avatar as the lists hold it: a small square crop.
  final String imageUrl;

  ImageProvider _image(String url, Map<String, String>? headers) =>
      weftAvatarImageOverride?.call(url) ?? NetworkImage(url, headers: headers);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final headers = ref.watch(mediaHeadersProvider);
    final large = largerThumbnailUrl(imageUrl);
    // The small picture is already in the image cache from the profile, so it
    // is on screen the moment the route is: blurry for a beat beats black.
    final small = Image(
      image: _image(imageUrl, headers),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: WeftAppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.titleSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Semantics(
        image: true,
        container: true,
        label: context.l10n.contactPhotoLabel(name),
        child: ExcludeSemantics(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: SizedBox.expand(
              child: large == imageUrl
                  ? small
                  : Image(
                      image: _image(large, headers),
                      fit: BoxFit.contain,
                      // Until the larger one has a frame, and for good if the
                      // server will not make one, the small one is the picture.
                      frameBuilder: (_, child, frame, _) =>
                          frame == null ? small : child,
                      errorBuilder: (_, _, _) => small,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
