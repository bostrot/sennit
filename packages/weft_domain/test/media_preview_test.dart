import 'package:test/test.dart';
import 'package:weft_domain/weft_domain.dart';

void main() {
  WeftMessage media(
    MessageKind kind, {
    int? size,
    String? mimeType,
    bool gif = false,
  }) => WeftMessage(
    eventId: r'$e',
    roomId: '!r',
    network: ChatNetwork.whatsapp,
    senderId: '@whatsapp_1:example.org',
    senderName: 'Anna',
    timestamp: DateTime(2026, 11, 19),
    kind: kind,
    isOwn: false,
    mediaSizeBytes: size,
    mediaMimeType: mimeType,
    playsAsGif: gif,
  );

  group('previewUsesOriginal', () {
    test('a GIF is fetched whole, a photo by its thumbnail', () {
      expect(
        previewUsesOriginal(media(MessageKind.image, mimeType: 'image/gif')),
        isTrue,
      );
      expect(
        previewUsesOriginal(media(MessageKind.image, mimeType: 'image/jpeg')),
        isFalse,
      );
    });

    test('a huge GIF falls back to its thumbnail', () {
      expect(
        previewUsesOriginal(
          media(
            MessageKind.image,
            mimeType: 'image/gif',
            size: kPreviewAnimatedImageMaxBytes + 1,
          ),
        ),
        isFalse,
      );
    });
  });

  group('previewDownloadsVideo', () {
    test('a small video is fetched for its poster, a big one is not', () {
      expect(
        previewDownloadsVideo(media(MessageKind.video, size: 2000000)),
        isTrue,
      );
      expect(
        previewDownloadsVideo(
          media(MessageKind.video, size: kPreviewVideoMaxBytes + 1),
        ),
        isFalse,
      );
    });

    test('an unknown size is only risked for a GIF', () {
      expect(previewDownloadsVideo(media(MessageKind.video)), isFalse);
      expect(
        previewDownloadsVideo(media(MessageKind.video, gif: true)),
        isTrue,
      );
    });

    test('only videos', () {
      expect(
        previewDownloadsVideo(media(MessageKind.image, size: 1000)),
        isFalse,
      );
    });
  });

  test('only a video loops inline, whatever the flag says', () {
    expect(media(MessageKind.video, gif: true).loopsInline, isTrue);
    expect(media(MessageKind.image, gif: true).loopsInline, isFalse);
  });
}
