import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:weft_design/weft_design.dart';

import 'package:weft_richtext/weft_richtext.dart' show LinkPreviewFetch;

import 'package:weft/app/providers.dart';
import 'package:weft/app/settings.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/matrix_chat_repository.dart'
    show AttachmentBytesLoader;
import 'package:weft/services/links/link_preview_service.dart';

bool _fontsLoaded = false;

/// Loads real text and icon fonts so golden images show actual glyphs.
///
/// `flutter_test` otherwise substitutes a placeholder that draws every glyph as
/// a filled box, which makes a golden useless for judging layout or catching a
/// text overflow. Both fonts ship inside the Flutter SDK, so this works on any
/// machine that can run the tests — no vendored font files, no network.
///
/// **Call this from `setUpAll`, never from inside `testWidgets`.** A test body
/// runs in a `FakeAsync` zone, and awaiting real file I/O there never completes
/// — the read finishes on a real timer that fake async will not advance, and
/// the test hangs until its timeout.
Future<void> loadGoldenFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;

  final root = _flutterRoot();
  if (root == null) return;

  final fonts = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!fonts.existsSync()) return;

  await _load('Roboto', [
    '${fonts.path}/Roboto-Regular.ttf',
    '${fonts.path}/Roboto-Medium.ttf',
    '${fonts.path}/Roboto-Bold.ttf',
  ]);
  await _load('MaterialIcons', ['${fonts.path}/MaterialIcons-Regular.otf']);
  // The SDK cache ships no monospace face, and `monospace` is the first family
  // of the stack `rich_text_view.dart` asks for — so without this every inline
  // code run and every code block in a golden is a row of placeholder boxes,
  // which is the failure this whole function exists to prevent. Roboto
  // Condensed stands in: the glyphs are not the ones a device draws, but the
  // ink, the padding and the wrapping around them are the app's own, and those
  // are what the image is for.
  await _load('monospace', ['${fonts.path}/RobotoCondensed-Regular.ttf']);
  // Registered under the package-qualified family: an IconData carrying
  // `fontPackage` resolves to `packages/<pkg>/<family>`, so registering the
  // bare family name loads the font but never matches the glyphs.
  await _loadPackageFont(
    'packages/simple_icons/SimpleIcons',
    'simple_icons',
    'fonts/SimpleIcons.ttf',
  );
}

/// Loads a font shipped inside a pub package, read from its resolved location
/// on disk.
///
/// Network brand glyphs come from `simple_icons`; without this every logo in a
/// golden is an empty box, which hides exactly the layout problems goldens
/// exist to catch. The asset bundle is not used because package assets are not
/// resolvable from the `flutter test` runner — reading the file the way the
/// SDK fonts are read is both simpler and actually works.
Future<void> _loadPackageFont(
  String family,
  String package,
  String assetPath,
) async {
  final root = _packageRoot(package);
  if (root == null) return;

  final file = File(p.join(root, assetPath));
  if (!file.existsSync()) return;

  final bytes = await file.readAsBytes();
  await (FontLoader(
    family,
  )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

/// Resolves a package's root directory from the workspace package config.
String? _packageRoot(String package) {
  var dir = Directory.current;
  for (var depth = 0; depth < 5; depth++) {
    final config = File(p.join(dir.path, '.dart_tool', 'package_config.json'));
    if (config.existsSync()) {
      final decoded =
          jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
      for (final entry in (decoded['packages'] as List? ?? const [])) {
        if (entry is! Map || entry['name'] != package) continue;
        final uri = Uri.parse(entry['rootUri'] as String);
        return uri.scheme == 'file'
            ? uri.toFilePath()
            : p.normalize(p.join(config.parent.path, uri.path));
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    any = true;
    loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  if (any) await loader.load();
}

/// `flutter test` exports FLUTTER_ROOT; the executable path is the fallback for
/// a bare `dart test` run.
String? _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  final exe = File(Platform.resolvedExecutable).parent.parent.parent.path;
  return Directory('$exe/bin/cache/artifacts/material_fonts').existsSync()
      ? exe
      : null;
}

/// Pumps [child] inside a themed [ProviderScope] at a fixed logical size.
///
/// [repository] and [fileReader] are named rather than a general overrides list
/// because Riverpod's `Override` is not exported from either barrel, so a typed
/// `List<Override>` parameter cannot be written at all — the scope's own list
/// only type-checks by inference. Four named seams now cover everything the
/// golden suites need to state: what is in the rooms, what a picked file's
/// bytes are, what the settings say, and what the homeserver answers when it is
/// asked about a link.
///
/// [stores] and [linkPreviewFetch] are what make a link-preview card drawable
/// at all: the card is off until a setting says otherwise and silent until a
/// homeserver answers, so a golden of one has to state both. They are applied
/// only when non-null — a scene that passes neither is a scene where the
/// preview path is off, which is the app's default and the right background for
/// every other image here.
Future<void> pumpWeft(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1400, 900),
  WeftThemeMode mode = WeftThemeMode.dark,
  Color seed = WeftTheme.defaultSeed,
  ChatRepository? repository,
  AttachmentBytesLoader? fileReader,
  WeftStores? stores,
  LinkPreviewFetch? linkPreviewFetch,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      // Goldens always run on fixtures. Without this the widget tree would
      // reach for a live Matrix session and throw. Note the overrides list is
      // never given an explicit type: Riverpod's `Override` is not exported
      // from either barrel, so it can only be produced by inference.
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          repository ?? DemoChatRepository(),
        ),
        if (fileReader != null)
          attachmentFileReaderProvider.overrideWithValue(fileReader),
        if (stores != null)
          storesBootstrapProvider.overrideWith((ref) async => stores),
        // The provider this replaces reaches for a live Matrix session, so a
        // scene that wants a card has to bring its own answers rather than let
        // the real one be read.
        if (linkPreviewFetch != null)
          linkPreviewFetchProvider.overrideWithValue(linkPreviewFetch),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: WeftAppearance(mode: mode, seed: seed).themeFor(Brightness.dark),
        home: child,
      ),
    ),
  );

  // Settle the entry animations rather than capturing them mid-flight, which
  // would make every golden non-deterministic.
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}

/// Decodes [provider] into the shared image cache before a golden is pumped.
///
/// `Image.memory` resolves its frame through the engine's codec, which is real
/// asynchronous work — and a widget test's `FakeAsync` zone never advances it.
/// Pumped the ordinary way, a golden of a photo therefore captures an *empty*
/// box where the picture should be, which looks enough like a deliberate layout
/// to be accepted by whoever reviews the image. Resolving under
/// [WidgetTester.runAsync] first puts the decoded frame in the cache, so the
/// widget's own resolve is a hit and completes synchronously.
///
/// Takes an [ImageProvider] rather than bytes because the cache key must match
/// the one the widget builds: `Image.memory(bytes, cacheWidth: n)` is a
/// `ResizeImage` wrapping a `MemoryImage`, and priming the bare `MemoryImage`
/// would leave the thumbnail as unresolved as before.
Future<void> primeImage(WidgetTester tester, ImageProvider provider) async {
  await tester.runAsync(() async {
    final done = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void finish() {
      stream.removeListener(listener);
      if (!done.isCompleted) done.complete();
    }

    listener = ImageStreamListener(
      (_, _) => finish(),
      // A fixture that fails to decode must not hang the suite until its
      // timeout: the golden then fails on the picture being missing, which
      // says what actually went wrong.
      onError: (_, _) => finish(),
    );
    stream.addListener(listener);
    await done.future;
  });
}
