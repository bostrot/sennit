import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

/// Pulls one frame out of a video about to be sent, as JPEG bytes.
///
/// Null whenever there is no frame to be had — the platform has no decoder for
/// the file, the plugin is not there, the file is not really a video. A video
/// without a poster still sends; it only arrives as an empty box with a play
/// button, which is what every video Sennit sent looked like before this.
typedef VideoPosterLoader =
    Future<Uint8List?> Function(AttachmentSource source);

/// Longest edge asked of the platform. The upload path scales the frame down
/// to the thumbnail's own size afterwards, so this only has to be big enough
/// not to be the limit.
const int kVideoPosterMaxEdge = 1280;

/// [VideoPosterLoader] backed by the platform's own decoder.
///
/// [AttachmentSource.filename] is a real path by the time a source reaches the
/// repository — see `readAttachmentFile` — so the file is handed over by name
/// and never read into Dart just to be given back.
Future<Uint8List?> extractVideoPoster(AttachmentSource source) async {
  try {
    final bytes = await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: source.filename,
      width: kVideoPosterMaxEdge,
      height: kVideoPosterMaxEdge,
      format: 'jpeg',
      quality: 85,
    );
    return bytes == null || bytes.isEmpty ? null : bytes;
  } on Object catch (error) {
    // Deliberately everything: a codec the device cannot open, a missing
    // plugin on a platform that has none. None of them is a reason to fail
    // the send.
    debugPrint('No poster for ${source.basename}: $error');
    return null;
  }
}

/// The picture an attachment's preview is scaled down from, or null when it
/// gets none.
///
/// A photo is its own preview, so [fileBytes] goes straight back. A video is
/// not a picture: what gets scaled down is one frame of it, asked of [poster]
/// — and only when the plan wants a preview at all, so a clip too small to
/// earn a thumbnail never spins up a decoder.
Future<Uint8List?> previewSourceFor(
  UploadPlan plan, {
  required Uint8List fileBytes,
  required VideoPosterLoader poster,
}) async {
  if (plan.kind != MessageKind.video) return fileBytes;
  if (!plan.thumbnail.shouldGenerate) return null;
  return poster(plan.source);
}
