import 'dart:typed_data';

import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';

/// A 1x1 PNG. Small enough to be a literal, real enough that `Image.memory`
/// decodes it instead of raising, which is what makes the hero, the zoom and
/// the picture-rather-than-placeholder assertions reachable at all.
final Uint8List kPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// The demo repository with real pixels and a controllable location.
///
/// Extends rather than reimplements: [ChatRepository] is twenty members wide
/// and only two of them decide which way an attachment is fetched, so a
/// subclass keeps a test about that fork rather than about the other eighteen.
/// Shared between the bubble and the viewer suites because both need the same
/// two answers — demo mode's own `attachmentBytes` returns null, which renders
/// every photo as the broken-image placeholder.
class StubChatRepository extends DemoChatRepository {
  StubChatRepository({this.location, this.bytes})
    : super(uploadTick: Duration.zero);

  /// Non-null stands for an unencrypted room, which is the branch that goes
  /// through the download transport.
  final AttachmentLocation? location;

  /// What `downloadAndDecryptAttachment` would hand back. Null is an
  /// undecryptable or missing attachment.
  final Uint8List? bytes;

  int locationCalls = 0;
  int byteCalls = 0;

  /// The last value [attachmentBytes] was called with, so a test can assert a
  /// full-size fetch was asked for rather than a 96-pixel crop.
  bool? lastThumbnail;

  @override
  Future<AttachmentLocation?> attachmentLocation(
    String roomId,
    String eventId,
  ) async {
    locationCalls++;
    return location;
  }

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async {
    byteCalls++;
    lastThumbnail = thumbnail;
    return bytes;
  }
}
