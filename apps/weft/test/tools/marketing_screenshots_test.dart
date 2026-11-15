import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/data/chat_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/inbox/inbox_shell.dart';

import '../support/attachment_fixtures.dart';
import '../support/golden_harness.dart';

/// Renders the App Store / Play Store screenshots, and the ones in the
/// README, from the demo fixtures.
///
/// The same trick as `brand_assets_test.dart`: a test, because rasterising
/// widgets needs a Flutter binding, writing real files under
/// `tooling/store/screenshots/` and `docs/images/`. The scenes lay out at the device's logical
/// size and are captured at its scale factor, which yields exactly the pixel
/// dimensions the stores demand — 1320×2868 for the 6.9" iPhone, 2064×2752
/// for the 13" iPad — with no simulator involved (the ffmpeg plugin ships no
/// arm64 simulator slice, so iOS 26 simulators cannot run the app at all).
void main() {
  setUpAll(() async {
    await loadGoldenFonts();
    // Marketing images only: the demo fixtures carry emoji, and without a
    // color-emoji face they render as tofu boxes — fine in a layout golden,
    // not in a store screenshot. Registered as an extra Roboto face so the
    // engine consults it for the glyphs Roboto lacks; macOS-only by nature,
    // which is where these images are produced anyway.
    final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emoji.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(emoji.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });

  const storeDir = '../../tooling/store/screenshots';
  const readmeDir = '../../docs/images';

  Future<void> capture(
    WidgetTester tester,
    String name, {
    required Widget child,
    required Size logical,
    required double scale,
    WeftThemeMode mode = WeftThemeMode.light,
    String outDir = storeDir,

    /// The name of a conversation to tap before the capture, for a two-pane
    /// scene with something in its right-hand pane.
    String? chatToOpen,

    /// Stands in for the demo fixtures, for a scene they cannot state — they
    /// carry no pictures, so a conversation with media in it has to bring its
    /// own.
    ChatRepository? repository,
  }) async {
    // Shadows as shadows. The test binding paints every shadow as a solid
    // black box so that goldens do not depend on a blur — which is why the
    // compose button in the published store screenshots wore a thick black
    // frame. Put back before the test body ends, which is when the framework
    // checks that it was.
    debugDisableShadows = false;
    try {
      await pumpWeft(
        tester,
        RepaintBoundary(
          // The harness lays out at one pixel per point and the capture below
          // scales it up, so anything that asks for the density — a photo
          // choosing how large to decode — has to be told the real one or it
          // is drawn at a fraction of the resolution it is captured at.
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(devicePixelRatio: scale),
              child: child,
            ),
          ),
        ),
        size: logical,
        mode: mode,
        repository: repository,
      );
      await tester.pumpAndSettle();
      if (chatToOpen != null) {
        await tester.tap(find.text(chatToOpen).first);
        await tester.pumpAndSettle();
      }
      if (repository != null) {
        // A picture decodes on the engine's own time, which the fake clock
        // never reaches: without real time passing the bubbles are captured as
        // the empty frames they are before their first frame arrives.
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
      }

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$outDir/$name.png')..createSync(recursive: true);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        expect(image.width, (logical.width * scale).round(), reason: name);
        expect(image.height, (logical.height * scale).round(), reason: name);
      });
    } finally {
      debugDisableShadows = true;
    }
  }

  // 6.9" iPhone: 440×956 points at 3× — 1320×2868.
  const iphone = Size(440, 956);
  // 13" iPad, portrait: 1032×1376 points at 2× — 2064×2752.
  const ipad = Size(1032, 1376);

  testWidgets('iphone inbox light', (tester) async {
    await capture(
      tester,
      'iphone_69_01_inbox_light',
      child: const InboxShell(),
      logical: iphone,
      scale: 3,
    );
  });

  testWidgets('iphone chat light', (tester) async {
    await capture(
      tester,
      'iphone_69_02_chat_light',
      child: const ChatView(chatId: 'merged:anna'),
      logical: iphone,
      scale: 3,
    );
  });

  testWidgets('iphone inbox dark', (tester) async {
    await capture(
      tester,
      'iphone_69_03_inbox_dark',
      child: const InboxShell(),
      logical: iphone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('iphone chat dark', (tester) async {
    await capture(
      tester,
      'iphone_69_04_chat_dark',
      child: const ChatView(chatId: 'merged:anna'),
      logical: iphone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('ipad inbox light two-pane', (tester) async {
    await capture(
      tester,
      'ipad_13_01_inbox_light',
      child: const InboxShell(),
      logical: ipad,
      scale: 2,
    );
  });

  testWidgets('ipad inbox dark two-pane', (tester) async {
    await capture(
      tester,
      'ipad_13_02_inbox_dark',
      child: const InboxShell(),
      logical: ipad,
      scale: 2,
      mode: WeftThemeMode.dark,
    );
  });

  // Google Play is strict about aspect ratio: phone shots must be 16:9 or
  // 9:16, and the Apple sets above are 9:19.6 — the shape of a modern iPhone,
  // which Play rejects outright. These are exactly 9:16 and 16:9.
  const playPhone = Size(360, 640);
  const playTablet = Size(960, 540);

  testWidgets('play phone inbox light', (tester) async {
    await capture(
      tester,
      'play_phone_01_inbox_light',
      child: const InboxShell(),
      logical: playPhone,
      scale: 3,
    );
  });

  testWidgets('play phone chat light', (tester) async {
    await capture(
      tester,
      'play_phone_02_chat_light',
      child: const ChatView(chatId: 'merged:anna'),
      logical: playPhone,
      scale: 3,
    );
  });

  testWidgets('play phone inbox dark', (tester) async {
    await capture(
      tester,
      'play_phone_03_inbox_dark',
      child: const InboxShell(),
      logical: playPhone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('play phone chat dark', (tester) async {
    await capture(
      tester,
      'play_phone_04_chat_dark',
      child: const ChatView(chatId: 'merged:anna'),
      logical: playPhone,
      scale: 3,
      mode: WeftThemeMode.dark,
    );
  });

  testWidgets('play tablet inbox light', (tester) async {
    await capture(
      tester,
      'play_tablet_01_inbox_light',
      child: const InboxShell(),
      logical: playTablet,
      scale: 2,
    );
  });

  testWidgets('play tablet inbox dark', (tester) async {
    await capture(
      tester,
      'play_tablet_02_inbox_dark',
      child: const InboxShell(),
      logical: playTablet,
      scale: 2,
      mode: WeftThemeMode.dark,
    );
  });

  // The README's images. Captured at 2× so they stay sharp on a high-density
  // display; GitHub scales them down to the width of their table cell.
  const desktop = Size(1400, 900);
  const phone = Size(430, 900);

  testWidgets('readme desktop light', (tester) async {
    await capture(
      tester,
      'inbox-light',
      child: const InboxShell(),
      logical: desktop,
      scale: 2,
      outDir: readmeDir,
      chatToOpen: 'Anna Maven',
    );
  });

  testWidgets('readme desktop dark', (tester) async {
    await capture(
      tester,
      'inbox-dark',
      child: const InboxShell(),
      logical: desktop,
      scale: 2,
      mode: WeftThemeMode.dark,
      outDir: readmeDir,
      chatToOpen: 'Anna Maven',
    );
  });

  testWidgets('readme phone inbox', (tester) async {
    await capture(
      tester,
      'inbox-mobile',
      child: const InboxShell(),
      logical: phone,
      scale: 2,
      outDir: readmeDir,
    );
  });

  testWidgets('readme phone chat light', (tester) async {
    await capture(
      tester,
      'chat-light',
      child: const ChatView(chatId: 'merged:anna'),
      logical: phone,
      scale: 2,
      outDir: readmeDir,
    );
  });

  testWidgets('readme phone media dark', (tester) async {
    const chatId = '!design_room:example.org';
    final sentAt = DateTime(2026, 8, 15, 14, 20);

    WeftMessage media(
      String eventId,
      MessageKind kind,
      String body, {
      required int minutesAgo,
      bool isOwn = false,
    }) => WeftMessage(
      eventId: eventId,
      roomId: chatId,
      network: ChatNetwork.matrix,
      senderId: isOwn ? '@me:example.org' : '@priya:example.org',
      senderName: isOwn ? 'You' : 'Priya',
      timestamp: sentAt.subtract(Duration(minutes: minutesAgo)),
      kind: kind,
      isOwn: isOwn,
      body: body,
      attachmentUrl: 'mxc://example.org/$eventId',
      mediaWidth: 400,
      mediaHeight: 225,
      deliveryState: isOwn ? DeliveryState.read : null,
    );

    late final Map<String, Uint8List> pictures;
    await tester.runAsync(() async {
      pictures = {
        'harbour': await _paint(_harbour),
        'ridge': await _paint(_ridge),
        'lake': await _paint(_lake),
      };
    });
    final repository = _PictureRepository(
      pictures: pictures,
      history: [
        media(
          'harbour',
          MessageKind.image,
          'from the harbour this morning',
          minutesAgo: 6,
        ),
        // A body that is only a filename is not a caption, so these two are
        // the picture and nothing else.
        media(
          'ridge',
          MessageKind.image,
          'IMG_4021.HEIC',
          minutesAgo: 3,
          isOwn: true,
        ),
        media('lake', MessageKind.video, 'evening-swim.mp4', minutesAgo: 1),
      ],
    );
    addTearDown(repository.dispose);

    await capture(
      tester,
      'chat-media-dark',
      child: const ChatView(chatId: chatId),
      logical: phone,
      scale: 2,
      mode: WeftThemeMode.dark,
      outDir: readmeDir,
      repository: repository,
    );
  });
}

/// [StubChatRepository] with a different picture behind each message.
class _PictureRepository extends StubChatRepository {
  _PictureRepository({required this.pictures, super.history});

  /// The encoded picture for each event id.
  final Map<String, Uint8List> pictures;

  @override
  Future<Uint8List?> attachmentBytes(
    String roomId,
    String eventId, {
    bool thumbnail = true,
  }) async => pictures[eventId];
}

/// Paints a 16:9 picture and encodes it as a PNG.
///
/// Drawn rather than shipped: the repository holds no photographs, and a
/// painted one has no licence to track and no bytes to keep in git. Must run
/// under [WidgetTester.runAsync], because encoding happens on the engine's
/// time.
Future<Uint8List> _paint(void Function(Canvas canvas, Size size) scene) async {
  const size = Size(1200, 675);
  final recorder = ui.PictureRecorder();
  scene(Canvas(recorder, Offset.zero & size), size);
  final image = await recorder.endRecording().toImage(
    size.width.round(),
    size.height.round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Paint _vertical(Rect rect, List<Color> colors, [List<double>? stops]) => Paint()
  ..shader = ui.Gradient.linear(
    rect.topCenter,
    rect.bottomCenter,
    colors,
    stops ?? [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)],
  );

/// A band of hills across the picture, its crest a sum of two sines.
Path _hills(
  Size size, {
  required double base,
  required double height,
  required double waves,
  double phase = 0,
}) {
  final path = Path()..moveTo(0, size.height);
  for (var x = 0.0; x <= size.width; x += 6) {
    final t = x / size.width * math.pi * 2;
    final crest =
        math.sin(t * waves + phase) * 0.6 +
        math.sin(t * waves * 2.3 + phase * 1.7) * 0.4;
    path.lineTo(x, base - height * (0.5 + 0.5 * crest));
  }
  return path
    ..lineTo(size.width, size.height)
    ..close();
}

/// Streaks of light on water under a sun or moon at [centre].
void _glitter(Canvas canvas, Offset centre, double depth, Color color) {
  final random = math.Random(7);
  for (var i = 0; i < 46; i++) {
    final t = random.nextDouble();
    final spread = 30 + t * 190;
    final width = 24 + random.nextDouble() * 70;
    final x = centre.dx + (random.nextDouble() - 0.5) * spread;
    final y = centre.dy + 6 + t * depth;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y), width: width, height: 3 + t * 3),
        const Radius.circular(3),
      ),
      Paint()..color = color.withValues(alpha: 0.75 - t * 0.45),
    );
  }
}

void _sailboat(Canvas canvas, Offset at, double scale, Color color) {
  final paint = Paint()..color = color;
  canvas.drawPath(
    Path()
      ..moveTo(at.dx - 34 * scale, at.dy)
      ..lineTo(at.dx + 34 * scale, at.dy)
      ..lineTo(at.dx + 24 * scale, at.dy + 12 * scale)
      ..lineTo(at.dx - 26 * scale, at.dy + 12 * scale)
      ..close(),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTWH(
      at.dx - 1.5 * scale,
      at.dy - 84 * scale,
      3 * scale,
      84 * scale,
    ),
    paint,
  );
  canvas.drawPath(
    Path()
      ..moveTo(at.dx + 4 * scale, at.dy - 82 * scale)
      ..lineTo(at.dx + 34 * scale, at.dy - 8 * scale)
      ..lineTo(at.dx + 4 * scale, at.dy - 8 * scale)
      ..close(),
    paint,
  );
  canvas.drawPath(
    Path()
      ..moveTo(at.dx - 4 * scale, at.dy - 70 * scale)
      ..lineTo(at.dx - 26 * scale, at.dy - 8 * scale)
      ..lineTo(at.dx - 4 * scale, at.dy - 8 * scale)
      ..close(),
    paint,
  );
}

/// Sunrise over a harbour: a low sun, a headland and two boats at anchor.
void _harbour(Canvas canvas, Size size) {
  final horizon = size.height * 0.6;
  final sky = Rect.fromLTWH(0, 0, size.width, horizon);
  final sea = Rect.fromLTWH(0, horizon, size.width, size.height - horizon);
  canvas.drawRect(
    sky,
    _vertical(sky, const [
      Color(0xFF30477E),
      Color(0xFF8E6FA3),
      Color(0xFFF29B7B),
      Color(0xFFFFD9A0),
    ]),
  );
  final sun = Offset(size.width * 0.64, horizon - 26);
  canvas.drawCircle(
    sun,
    230,
    Paint()
      ..shader = ui.Gradient.radial(sun, 230, const [
        Color(0xB3FFF1C9),
        Color(0x00FFF1C9),
      ]),
  );
  canvas.drawCircle(sun, 44, Paint()..color = const Color(0xFFFFF6DC));
  canvas.save();
  canvas.clipRect(sky);
  canvas.drawPath(
    _hills(size, base: horizon + 40, height: 120, waves: 1.1, phase: 2.4),
    Paint()..color = const Color(0xFF6B5A8C),
  );
  canvas.restore();
  canvas.drawRect(
    sea,
    _vertical(sea, const [
      Color(0xFFE9A77F),
      Color(0xFF7A6A9C),
      Color(0xFF2B3A68),
    ]),
  );
  _glitter(
    canvas,
    Offset(sun.dx, horizon),
    size.height - horizon - 30,
    const Color(0xFFFFE9BE),
  );
  _sailboat(
    canvas,
    Offset(size.width * 0.27, horizon + 96),
    1.5,
    const Color(0xFF1D2547),
  );
  _sailboat(
    canvas,
    Offset(size.width * 0.45, horizon + 38),
    0.8,
    const Color(0xFF2A3059),
  );
  // The quay the picture was taken from.
  canvas.drawRect(
    Rect.fromLTWH(0, size.height - 46, size.width, 46),
    Paint()..color = const Color(0xFF141A36),
  );
  for (final x in [0.12, 0.52, 0.9]) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * x, size.height - 78, 22, 34),
        const Radius.circular(6),
      ),
      Paint()..color = const Color(0xFF141A36),
    );
  }
}

/// Mountain ridges at midday, each one paler than the one in front of it.
void _ridge(Canvas canvas, Size size) {
  final frame = Offset.zero & size;
  canvas.drawRect(
    frame,
    _vertical(frame, const [
      Color(0xFF3F8FD6),
      Color(0xFF9CCBEF),
      Color(0xFFE8F3FA),
    ]),
  );
  final cloud = Paint()..color = const Color(0xE6FFFFFF);
  for (final (x, y, scale) in [
    (0.2, 0.2, 1.0),
    (0.7, 0.13, 1.3),
    (0.9, 0.3, 0.7),
  ]) {
    final at = Offset(size.width * x, size.height * y);
    canvas.drawOval(
      Rect.fromCenter(center: at, width: 190 * scale, height: 44 * scale),
      cloud,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: at.translate(-30 * scale, -20 * scale),
        width: 96 * scale,
        height: 52 * scale,
      ),
      cloud,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: at.translate(34 * scale, -14 * scale),
        width: 80 * scale,
        height: 40 * scale,
      ),
      cloud,
    );
  }
  const ridges = [
    (0.62, 250.0, 1.3, 0.4, Color(0xFFAFC6DE)),
    (0.74, 230.0, 1.7, 2.1, Color(0xFF7F9FC4)),
    (0.86, 210.0, 1.2, 4.0, Color(0xFF4E7396)),
    (1.0, 190.0, 2.1, 5.2, Color(0xFF2F5560)),
    (1.14, 170.0, 1.6, 1.0, Color(0xFF1F3B3C)),
  ];
  for (final (base, height, waves, phase, color) in ridges) {
    canvas.drawPath(
      _hills(
        size,
        base: size.height * base,
        height: height,
        waves: waves,
        phase: phase,
      ),
      Paint()..color = color,
    );
  }
}

/// A lake at dusk under a moon, with pines along the near shore.
void _lake(Canvas canvas, Size size) {
  final horizon = size.height * 0.56;
  final sky = Rect.fromLTWH(0, 0, size.width, horizon);
  final water = Rect.fromLTWH(0, horizon, size.width, size.height - horizon);
  canvas.drawRect(
    sky,
    _vertical(sky, const [
      Color(0xFF141B4D),
      Color(0xFF4B3F8F),
      Color(0xFFC0648F),
      Color(0xFFF4A27A),
    ]),
  );
  final random = math.Random(3);
  for (var i = 0; i < 60; i++) {
    canvas.drawCircle(
      Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * horizon * 0.55,
      ),
      0.8 + random.nextDouble() * 1.6,
      Paint()
        ..color = Colors.white.withValues(
          alpha: 0.4 + random.nextDouble() * 0.5,
        ),
    );
  }
  final moon = Offset(size.width * 0.3, size.height * 0.2);
  canvas.drawCircle(
    moon,
    120,
    Paint()
      ..shader = ui.Gradient.radial(moon, 120, const [
        Color(0x66FFF4DA),
        Color(0x00FFF4DA),
      ]),
  );
  canvas.drawCircle(moon, 30, Paint()..color = const Color(0xFFFFF4DA));
  canvas.save();
  canvas.clipRect(sky);
  canvas.drawPath(
    _hills(size, base: horizon + 30, height: 150, waves: 1.4, phase: 0.8),
    Paint()..color = const Color(0xFF3A2F6B),
  );
  canvas.drawPath(
    _hills(size, base: horizon + 50, height: 110, waves: 2.2, phase: 3.3),
    Paint()..color = const Color(0xFF251F4D),
  );
  canvas.restore();
  canvas.drawRect(
    water,
    _vertical(water, const [
      Color(0xFFB8648C),
      Color(0xFF3E3478),
      Color(0xFF12163A),
    ]),
  );
  _glitter(
    canvas,
    Offset(moon.dx, horizon),
    size.height - horizon - 60,
    const Color(0xFFFFE6D0),
  );
  // Pines, tallest at the edges so the middle of the frame stays open for the
  // play badge the bubble draws there.
  final pine = Paint()..color = const Color(0xFF0B0E24);
  canvas.drawRect(Rect.fromLTWH(0, size.height - 30, size.width, 30), pine);
  for (var i = 0; i < 26; i++) {
    final t = i / 25;
    final x = t * size.width + (random.nextDouble() - 0.5) * 24;
    final edge = (t - 0.5).abs() * 2;
    final height = 60 + edge * edge * 250 + random.nextDouble() * 40;
    final half = height * 0.2;
    final foot = size.height - 24;
    for (var tier = 0; tier < 4; tier++) {
      final top = foot - height + tier * height * 0.2;
      final spread = half * (0.45 + tier * 0.2);
      canvas.drawPath(
        Path()
          ..moveTo(x, top)
          ..lineTo(x + spread, top + height * 0.42)
          ..lineTo(x - spread, top + height * 0.42)
          ..close(),
        pine,
      );
    }
  }
}
